// SPDX-License-Identifier: GPL-3.0-or-later
//
// Real jump. See RealJump.h and docs/spikes/real-lift.md.
//
// Client MSFalling (0x58 bytes, vtable rva 0x564F770):
//   +0x08 machine  +0x10 transaction  +0x18 extra height  +0x1C Start
//   +0x28 Velocity  +0x34 current vel  +0x41 flag  +0x44 velocity preset
//   +0x48 t  +0x54 state (0 init, 1 airborne, 2 landed, 3 done)
// Update: t += dt; pos = Start + Vel*t - (0, 20 t^2, 0); lands when pos.y
// is at or under the ground probe. dt = *(float*)(gameTime + 8).
// Movement machine (ecl::Character + 0x78, pointer): +0x38 layer 0
// (MoveTo / Idle), +0x40 layer 1 (Falling / Climbing).
// State vtable: [1] GetType, [2] Enter, [3] Continue, [4] Update,
// [5] CanExit, [6] Exit.
//
// Collision (2026-10-10): the engine's falling has no sideways or ceiling
// check. Its ground probe (0x141196c70, called from the falling Update at
// 0x141bd7480) sweeps a sphere through the physics scene:
//   scene->vt[0x50](scene, float radius, vec3* from, vec3* to, Result* r,
//                   5, 0x20, mask 0x8100080, 1, -1, -1)
//   Result (0x40 bytes): +0x18 float distance, FLT_MAX = no hit.
// We patch that call to learn the scene, then sweep sideways (knee, head)
// and upward (while rising) with the same call.

#include "RealJump.h"

#include <windows.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "../Log.h"
#include "../PatternScan.h"
#include "../SafeMem.h"

namespace dag::realjump {

namespace {

constexpr uintptr_t kCharVtRva    = 0x56576A0;   // ecl::Character
constexpr uintptr_t kFallVtRva    = 0x564F770;   // client MSFalling
constexpr uintptr_t kCounterRva   = 0x5ED576C;   // movement transaction counter
constexpr const char* kGetStatePattern =
    "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 48 8B F9 33 F6 4C 8D 0D ?? ?? ?? ?? 83 FA 07 77 3D 48 63 C2 45 8B 84 81 08 6C BD 01";
constexpr const char* kFallUpdatePattern = "48 8B C4 48 89 70 20 55 57 41 54 41 56";

using GetStateFn   = uint8_t*(__fastcall*)(uint8_t* machine, int type);
using StateFn      = bool(__fastcall*)(uint8_t* state);
using VoidStateFn  = void(__fastcall*)(uint8_t* state);
using UpdateFn     = uint64_t(__fastcall*)(uint8_t* state, uint8_t* gameTime);
using GetXformFn   = uint8_t*(__fastcall*)(void* character);

uintptr_t  g_base = 0;
GetStateFn g_getState = nullptr;
UpdateFn   g_origUpdate = nullptr;
int*       g_counter = nullptr;
bool       g_hooked = false;
VoidStateFn g_origExit = nullptr;
bool       g_inFallUpdate = false;

// The client's reset for "the server changed character flag 0x20"
// (0x141FE20D0, called from the character sync handler 0x141FDCC60 at
// 0x141FDE059 when that flag changes on a character with a character light,
// 0x2000): it clears the character light's data, exits the action layer,
// StopMovement(machine, force) and stops steering. The server changes the
// flag about 60 ms after every take-off (the jump clip, Osi.PlayAnimation):
// playtest 5 logged it ending every real jump (RJUMP exit, callers
// 0x1FE2224 <- 0x1FDE05E), and the light reset is the likely take-off
// flicker. While our jump runs, and 0.6 s after its planned end, it is
// skipped for our character (jump.sync_guard, !dag_jump_sync_guard).
// Entry: push r14; sub rsp, 40h (6 bytes, no RIP-relative operand).
constexpr const char* kSyncResetPattern =
    "41 56 48 83 EC 40 48 8B 82 A8 00 00 00 4C 8B F2 48 89 5C 24 50 B9 03 00 00 00";
constexpr uint8_t kSyncResetEntry[] = { 0x41, 0x56, 0x48, 0x83, 0xEC, 0x40 };
using SyncResetFn = void(__fastcall*)(void* sys, void* character, uint8_t flag);
SyncResetFn volatile g_origSyncReset = nullptr;
std::atomic<bool> g_syncGuard{ true };
long g_syncSeen = 0, g_syncSkipped = 0;
bool g_refusedAirborne = false;   // Start's last refusal: already in the air
int  g_refusedLogSeq = 0;         // Pov retries a refused jump every frame: log it once
char       g_why[128] = "not installed";

std::atomic<void*> g_char{ nullptr };
float g_camFwd[2] = { 0.f, 1.f };
float g_strafeSign = 1.f;
float g_landSpeed = 3.f;
// BG3's landing animation holds the fall in its landed state (+0x54 = 2)
// through +0x40 (set and released by animation events, vtable slot 8
// 0x141bd7dc0): the "recover" after a jump, 150-230 ms in playtest 8, with
// WASD and the next hop blocked. false = clear the hold after our jumps
// (data jump.land_hold, 2026-10-13).
std::atomic<bool> g_landHold{ false };
float g_wallH = 1.3f;
// Uphill (2026-10-15): tan of the steepest ground rise the curve's floor
// follows (data jump.slope_max_deg); 0 = off.
float g_slopeTan = 1.19f;

// Physics scene from the falling Update's ground probe call.
using ProbeFn = void*(__fastcall*)(void* out, void* grid, void* scene, float* pos, float radius, float extraUp);
using SweepFn = void(__fastcall*)(void* scene, float radius, const float* from, const float* to, uint8_t* result,
                                  int a6, int a7, uint32_t mask, int a9, int a10, int a11);
ProbeFn g_origProbe = nullptr;
std::atomic<void*> g_scene{ nullptr };
constexpr const char* kProbeCallPattern =
    "4C 8B 42 30 4C 8D 4D 60 48 8B 92 80 00 00 00 48 8D 4D 70 F3 0F 11 74 24 28 F3 0F 11 44 24 20 E8";

void FollowSlope(uint8_t* out, const float* pos);

void* __fastcall HookProbe(void* out, void* grid, void* scene, float* pos, float radius, float extraUp)
{
    if (scene) g_scene.store(scene, std::memory_order_relaxed);
    void* r = g_origProbe(out, grid, scene, pos, radius, extraUp);
    // Only inside our jump's own falling Update (g_inFallUpdate).
    if (g_inFallUpdate && out && pos) FollowSlope(static_cast<uint8_t*>(out), pos);
    return r;
}

// Sphere sweep from -> to; true + distance on a hit.
bool Sweep(const float from[3], const float to[3], float radius, float& dist)
{
    void* scene = g_scene.load(std::memory_order_relaxed);
    if (!scene) return false;
    __try {
        auto fn = reinterpret_cast<SweepFn>(*reinterpret_cast<uintptr_t*>(*reinterpret_cast<uintptr_t*>(scene) + 0x50));
        alignas(16) uint8_t res[0x40] = {};
        *reinterpret_cast<float*>(res + 0x18) = 3.402823466e38f;
        fn(scene, radius, from, to, res, 5, 0x20, 0x8100080u, 1, -1, -1);
        dist = *reinterpret_cast<float*>(res + 0x18);
        return dist < 3.0e38f && std::fabs(dist) > 1e-4f;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

struct Jump {
    bool     active = false;     // we steer
    int      seq = 0;
    uint8_t* state = nullptr;
    uint8_t* character = nullptr;
    uint8_t* machine = nullptr;
    LARGE_INTEGER t0 = {};
    float    durMs = 0, h = 0, k = 3;
    float    start[3] = {};      // take-off position
    float    pos[3] = {};        // our XZ (integrated), last Y
    float    vel[2] = {};        // horizontal velocity
    float    lastY = 0;
    int      frames = 0, reseeds = 0;
    float    wrote[3] = {};      // Start we wrote (re-seed detection)
    int      walls = 0;          // frames the sideways move was blocked
    bool     bonked = false;
    bool     holdSkipped = false; // BG3's landing hold cleared after this jump
    bool     offLogged = false;   // "fall state off the machine" logged
    // Uphill: the curve is drawn from `base`, which starts at the take-off
    // height and rises with a slope under the jump (FollowSlope).
    float    base = 0;
    float    u = 0;               // this frame's curve position (FollowSlope)
    float    gLast = 0, gx = 0, gz = 0;   // last ground probe answer and where
    int      probes = 0, slopeFrames = 0, saves = 0, steps = 0;
} g_j;

// Horizontal velocity of the character, measured per frame (for inertia).
float g_lastPos[3] = {};
LARGE_INTEGER g_lastPosT = {};
float g_measVel[2] = {};
double g_qpcFreq = 0;

double Seconds(const LARGE_INTEGER& a, const LARGE_INTEGER& b)
{
    if (g_qpcFreq == 0) { LARGE_INTEGER f; QueryPerformanceFrequency(&f); g_qpcFreq = static_cast<double>(f.QuadPart); }
    return static_cast<double>(b.QuadPart - a.QuadPart) / g_qpcFreq;
}

bool VtIs(const void* obj, uintptr_t rva)
{
    void* vt = nullptr;
    return dag::safemem::ReadPtr(obj, 0, vt) && reinterpret_cast<uintptr_t>(vt) == g_base + rva;
}

uintptr_t VtSlot(const void* obj, int i)
{
    void* vt = nullptr;
    if (!dag::safemem::ReadPtr(obj, 0, vt) || !vt) return 0;
    uintptr_t f = 0;
    dag::safemem::ReadBytes(reinterpret_cast<uint8_t*>(vt) + i * 8, &f, 8);
    return f;
}

bool ReadPos(void* character, float out[3])
{
    __try {
        auto get = reinterpret_cast<GetXformFn>(VtSlot(character, 0xD0 / 8));
        if (!get) return false;
        uint8_t* xf = get(character);
        if (!xf) return false;
        std::memcpy(out, xf + 0x10, 12);
        return std::isfinite(out[0]) && std::isfinite(out[1]) && std::isfinite(out[2]);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

// WASD (physical keys) -> world XZ direction from the camera forward.
bool InputDir(float out[2])
{
    HWND fg = GetForegroundWindow();
    DWORD pid = 0;
    if (fg) GetWindowThreadProcessId(fg, &pid);
    if (pid != GetCurrentProcessId()) return false;
    float f = 0, r = 0;
    if (GetAsyncKeyState('W') & 0x8000) f += 1;
    if (GetAsyncKeyState('S') & 0x8000) f -= 1;
    if (GetAsyncKeyState('D') & 0x8000) r += 1;
    if (GetAsyncKeyState('A') & 0x8000) r -= 1;
    if (f == 0 && r == 0) return false;
    // right = forward turned 90 degrees about Y: (-fz, fx) * sign. The
    // sign depends on the engine's handedness; !dag_jump_strafe_flip.
    const float fx = g_camFwd[0], fz = g_camFwd[1];
    const float rs = r * g_strafeSign;
    const float x = fx * f - fz * rs, z = fz * f + fx * rs;
    const float l = std::sqrt(x * x + z * z);
    if (l < 1e-4f) return false;
    out[0] = x / l; out[1] = z / l;
    return true;
}

// Push `st` into machine layer at `layerOff` the engine's way.
bool PushLayer(uint8_t* machine, size_t layerOff, uint8_t* st, const char* what)
{
    __try {
        uint8_t* cur = *reinterpret_cast<uint8_t**>(machine + layerOff);
        if (cur == st) return true;
        if (cur) {
            auto canExit = reinterpret_cast<StateFn>(VtSlot(cur, 5));
            auto exitFn  = reinterpret_cast<VoidStateFn>(VtSlot(cur, 6));
            if (!canExit || !exitFn) return false;
            if (!canExit(cur)) {
                dag::log::Writef("RJUMP: %s layer busy (state vt rva 0x%llX can't exit)", what,
                                 static_cast<unsigned long long>(VtSlot(cur, 0) ? (*reinterpret_cast<uintptr_t*>(cur) - g_base) : 0));
                return false;
            }
            exitFn(cur);
        }
        *reinterpret_cast<uint8_t**>(machine + layerOff) = st;
        *reinterpret_cast<int*>(st + 0x10) = (*g_counter)++;
        *reinterpret_cast<uint8_t**>(st + 0x08) = machine;
        auto enter = reinterpret_cast<StateFn>(VtSlot(st, 2));
        if (!enter || !enter(st)) {
            *reinterpret_cast<uint8_t**>(machine + layerOff) = nullptr;
            dag::log::Writef("RJUMP: %s Enter returned false", what);
            return false;
        }
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        dag::log::Writef("RJUMP: %s push faulted", what);
        return false;
    }
}

float Curve(float u)
{
    if (u <= 0.f || u >= 1.f) return 0.f;
    return g_j.h * (1.f - std::pow(std::fabs(2.f * u - 1.f), g_j.k));
}

// Uphill (developer 2026-10-15: "jumps are terrible going up slopes; they
// work on the way down"). The curve rose from the take-off height, so
// running up a slope the ground ahead caught up with it and the engine's
// landing test (pos.y at or under its ground probe) ended the jump a third
// of the way in, a little hop. The falling Update's own ground probe
// (docs/spikes/ground-support.md: out = { x, groundY, z, byte +0xC = no grid
// cell }) tells us the ground under the jump every frame:
//   - a rise a slope can explain (no steeper than slope_max_deg over the
//     step since the last probe) lifts the curve's floor to it, and this
//     frame's landing test is told the ground is just under us;
//   - a steeper rise (a rock's edge, a crate) is left alone: the jump lands
//     on it as before;
//   - ground going down never lowers the floor (downhill already worked:
//     the curve hands back at its floor and the engine falls the rest).
void FollowSlope(uint8_t* out, const float* pos)
{
    if (!g_j.active || g_slopeTan <= 0.f) return;
    __try {
        if (out[0xC] != 0) return;
        float& gy = *reinterpret_cast<float*>(out + 4);
        if (!std::isfinite(gy) || !std::isfinite(pos[1])) return;
        const float dx = pos[0] - g_j.gx, dz = pos[2] - g_j.gz;
        const float d = std::sqrt(dx * dx + dz * dz);
        const float rise = gy - g_j.gLast;
        // The first probe is measured from the feet at take-off, which can
        // sit a few cm into an uphill.
        const float slack = g_j.probes == 0 ? 0.10f : 0.03f;
        const bool slope = rise <= g_slopeTan * d + slack;
        ++g_j.probes;
        g_j.gLast = gy; g_j.gx = pos[0]; g_j.gz = pos[2];
        if (!slope) {
            if (gy >= pos[1]) ++g_j.steps;
            return;
        }
        if (gy > g_j.base) { g_j.base = gy; ++g_j.slopeFrames; }
        // The floor moves from the next frame; keep this frame airborne.
        // Near the curve's end the ground meeting us is the touchdown.
        if (gy >= pos[1] - 0.005f && g_j.u < 0.9f) {
            gy = pos[1] - 0.01f;
            ++g_j.saves;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {}
}

// For the RJUMP end / landed early lines.
const char* SlopeSummary()
{
    static char buf[160];
    if (g_slopeTan <= 0.f) return "uphill follow off";
    std::snprintf(buf, sizeof(buf), "uphill: floor +%.2f m (rose on %d of %d probes), %d landing tests held off, %d steps",
                  g_j.base - g_j.start[1], g_j.slopeFrames, g_j.probes, g_j.saves, g_j.steps);
    return buf;
}

// After our jump (from take-off to 2 s after its planned end): clear BG3's
// landing hold before the engine's Update, so the landed state ends at once
// (state 3 pops layer 1 on the next Update) and you move / hop right away.
void SkipLandHold(uint8_t* st)
{
    if (g_landHold.load(std::memory_order_relaxed) || !g_j.seq || st != g_j.state) return;
    LARGE_INTEGER now; QueryPerformanceCounter(&now);
    const double sinceEnd = Seconds(g_j.t0, now) - g_j.durMs / 1000.0;
    if (sinceEnd > 2.0) return;
    if (*reinterpret_cast<int*>(st + 0x54) != 2 || st[0x40] == 0) return;
    st[0x40] = 0;
    if (!g_j.holdSkipped) {
        g_j.holdSkipped = true;
        dag::log::Writef("RJUMP landing hold skipped seq=%d %.0f ms after the jump's end (BG3's landing animation held the fall)",
                         g_j.seq, sinceEnd * 1000.0);
    }
}

uint64_t __fastcall HookUpdate(uint8_t* st, uint8_t* gameTime)
{
    if (!g_j.active || st != g_j.state) {
        __try { SkipLandHold(st); } __except (EXCEPTION_EXECUTE_HANDLER) {}
        return g_origUpdate(st, gameTime);
    }

    float dt = 0.016f;
    __try { dt = *reinterpret_cast<float*>(gameTime + 8); } __except (EXCEPTION_EXECUTE_HANDLER) {}
    if (!(dt > 0.f && dt < 0.25f)) dt = 0.016f;

    LARGE_INTEGER now; QueryPerformanceCounter(&now);
    const float u = static_cast<float>(Seconds(g_j.t0, now) * 1000.0 / g_j.durMs);

    // Someone else re-seeded the fall (MoveTo / Idle fall check)?
    float curStart[3];
    std::memcpy(curStart, st + 0x1C, 12);
    if (g_j.frames > 0 && std::memcmp(curStart, g_j.wrote, 12) != 0) ++g_j.reseeds;

    // Horizontal: WASD steers at the take-off speed (min 2.5 m/s); no keys
    // = keep the momentum.
    float dir[2];
    if (InputDir(dir)) {
        const float sp = std::sqrt(g_j.vel[0] * g_j.vel[0] + g_j.vel[1] * g_j.vel[1]);
        const float speed = sp > 2.5f ? sp : 2.5f;
        g_j.vel[0] = dir[0] * speed;
        g_j.vel[1] = dir[1] * speed;
    }
    // Walls: sweep the step at chest height (2026-10-10: knee height caught
    // rocks and debris); blocked = stop.
    {
        const float sx = g_j.vel[0] * dt, sz = g_j.vel[1] * dt;
        const float sl = std::sqrt(sx * sx + sz * sz);
        if (sl > 1e-5f) {
            const float nx = sx / sl, nz = sz / sl;
            const float reach = sl + 0.35f;
            bool blocked = false;
            for (float hh : { g_wallH }) {
                const float from[3] = { g_j.pos[0], g_j.pos[1] + hh, g_j.pos[2] };
                const float to[3] = { from[0] + nx * reach, from[1], from[2] + nz * reach };
                float d;
                if (Sweep(from, to, 0.25f, d)) { blocked = true; break; }
            }
            if (blocked) {
                if (g_j.walls++ == 0)
                    dag::log::Writef("RJUMP wall seq=%d at u=%.2f -> horizontal motion stopped", g_j.seq, u);
                g_j.vel[0] = g_j.vel[1] = 0.f;
            } else {
                g_j.pos[0] += sx;
                g_j.pos[2] += sz;
            }
        }
    }

    // Ceiling: rising into something = bonk, the engine's gravity takes over.
    if (u < 1.f && !g_j.bonked) {
        const float yNext = g_j.base + Curve(u);
        if (yNext > g_j.pos[1] + 1e-4f) {
            const float from[3] = { g_j.pos[0], g_j.pos[1] + 1.6f, g_j.pos[2] };
            const float to[3] = { from[0], yNext + 1.6f + 0.15f, from[2] };
            float d;
            if (Sweep(from, to, 0.25f, d)) {
                g_j.bonked = true;
                const float p[3] = { g_j.pos[0], g_j.pos[1], g_j.pos[2] };
                std::memcpy(st + 0x1C, p, 12);
                const float v[3] = { g_j.vel[0], 0.f, g_j.vel[1] };
                std::memcpy(st + 0x28, v, 12);
                *reinterpret_cast<float*>(st + 0x48) = 0.f;
                g_j.active = false;
                dag::log::Writef("RJUMP ceiling seq=%d at u=%.2f y=%.2f -> falls from here (%d frames, walls=%d)",
                                 g_j.seq, u, g_j.pos[1], g_j.frames, g_j.walls);
                return g_origUpdate(st, gameTime);
            }
        }
    }

    if (u >= 1.f) {
        // Curve done: hand back to the engine with our momentum and a
        // gentle fall speed (the curve's own end is ~13 m/s at k=3, which
        // landed hard); it falls on / lands by itself.
        const float du = 0.01f;
        float vy = (Curve(1.f - du) - Curve(1.f - 2 * du)) / (du * g_j.durMs / 1000.f);
        if (vy < -g_landSpeed) vy = -g_landSpeed;
        const float p[3] = { g_j.pos[0], g_j.base + 0.001f, g_j.pos[2] };
        std::memcpy(st + 0x1C, p, 12);
        const float v[3] = { g_j.vel[0], vy < 0.f ? vy : -1.f, g_j.vel[1] };
        std::memcpy(st + 0x28, v, 12);
        *reinterpret_cast<float*>(st + 0x48) = 0.f;
        g_j.active = false;
        dag::log::Writef("RJUMP end seq=%d steered %d frames, re-seeds=%d, walls=%d, handed back vy=%.2f at (%.2f,%.2f,%.2f) scene=%s; %s",
                         g_j.seq, g_j.frames, g_j.reseeds, g_j.walls, v[1], p[0], p[1], p[2],
                         g_scene.load() ? "yes" : "NO (no wall/ceiling checks)", SlopeSummary());
        return g_origUpdate(st, gameTime);
    }

    // Height from the curve; keep a 3 cm floor early on so the engine's
    // landing test doesn't end the jump on the first frame.
    float y = g_j.base + Curve(u);
    if (u < 0.5f && y < g_j.base + 0.03f) y = g_j.base + 0.03f;
    g_j.pos[1] = y;
    g_j.u = u;

    // The engine computes pos = Start + Vel*t' - (0, 20 t'^2, 0), t' = t + dt.
    // With Vel = 0 and t = 0: Start = our point + (0, 20 dt^2, 0).
    const float s[3] = { g_j.pos[0], y + 20.f * dt * dt, g_j.pos[2] };
    std::memcpy(st + 0x1C, s, 12);
    std::memset(st + 0x28, 0, 12);
    *reinterpret_cast<float*>(st + 0x48) = 0.f;
    std::memcpy(g_j.wrote, s, 12);
    ++g_j.frames;

    g_inFallUpdate = true;
    const uint64_t r = g_origUpdate(st, gameTime);
    g_inFallUpdate = false;
    const int stNow = *reinterpret_cast<int*>(st + 0x54);
    if (stNow >= 2) {
        g_j.active = false;
        dag::log::Writef("RJUMP landed early seq=%d at u=%.2f y=%.2f (on something; engine state %d), %d frames, re-seeds=%d; %s",
                         g_j.seq, u, y, stNow, g_j.frames, g_j.reseeds, SlopeSummary());
    }
    return r;
}

// Falling Exit (vtable slot 6): who ends our jump while we still steer it?
// Logs the engine callers (module rvas) once per jump.
void __fastcall HookExit(uint8_t* st)
{
    if (g_j.active && st == g_j.state) {
        void* frames[8] = {};
        const USHORT n = RtlCaptureStackBackTrace(1, 8, frames, nullptr);
        char buf[160] = {};
        size_t len = 0;
        for (USHORT i = 0; i < n && len + 20 < sizeof(buf); ++i) {
            const uintptr_t a = reinterpret_cast<uintptr_t>(frames[i]);
            const int w = (a >= g_base && a < g_base + 0x8000000)
                ? std::snprintf(buf + len, sizeof(buf) - len, " 0x%llX", static_cast<unsigned long long>(a - g_base))
                : std::snprintf(buf + len, sizeof(buf) - len, " ?");
            if (w > 0) len += static_cast<size_t>(w);
        }
        LARGE_INTEGER now; QueryPerformanceCounter(&now);
        const float u = static_cast<float>(Seconds(g_j.t0, now) * 1000.0 / g_j.durMs);
        dag::log::Writef("RJUMP exit seq=%d at u=%.2f after %d frames%s: the engine is ending our falling state (callers rva%s)",
                         g_j.seq, u, g_j.frames, g_inFallUpdate ? " (inside its own Update: a landing)" : "", buf);
    }
    g_origExit(st);
}

void __fastcall HookSyncReset(void* sys, void* character, uint8_t flag)
{
    if (character && character == g_char.load(std::memory_order_relaxed)) {
        ++g_syncSeen;
        LARGE_INTEGER now; QueryPerformanceCounter(&now);
        const double ms = g_j.seq && g_j.t0.QuadPart ? Seconds(g_j.t0, now) * 1000.0 : 1e9;
        const bool inJump = ms >= 0.0 && ms < g_j.durMs + 600.0;
        if (inJump && g_syncGuard.load(std::memory_order_relaxed)) {
            ++g_syncSkipped;
            if (g_syncSkipped <= 20 || g_syncSkipped % 50 == 0)
                dag::log::Writef("RJUMP sync #%ld: the server set flag 0x20 = %d on us %.0f ms after take-off (seq %d) -> "
                                 "the engine's stop-everything reset skipped (sync guard)", g_syncSkipped, flag ? 1 : 0, ms, g_j.seq);
            return;
        }
        if (g_syncSeen <= 20 || g_syncSeen % 50 == 0)
            dag::log::Writef("RJUMP sync: the server set flag 0x20 = %d on us (%s) -> the engine's stop-everything reset runs",
                             flag ? 1 : 0, inJump ? "during a jump, guard off" : "no jump");
    }
    g_origSyncReset(sys, character, flag);
}

bool HookVtable(uint8_t* st)
{
    if (g_hooked) return true;
    void* vtp = nullptr;
    if (!dag::safemem::ReadPtr(st, 0, vtp) || !vtp) return false;
    void** slots = reinterpret_cast<void**>(vtp);
    const uintptr_t upd = reinterpret_cast<uintptr_t>(slots[4]);
    // Validate: GetType returns 6, Update matches the pattern.
    uint8_t gt[6] = {};
    dag::safemem::ReadBytes(slots[1], gt, 6);
    static const uint8_t kGt[6] = { 0xB8, 0x06, 0x00, 0x00, 0x00, 0xC3 };
    uint8_t* found = dag::patternscan::Find(GetModuleHandleW(nullptr), kFallUpdatePattern);
    if (std::memcmp(gt, kGt, 6) != 0 || !found || reinterpret_cast<uintptr_t>(found) != upd) {
        std::snprintf(g_why, sizeof(g_why), "failed: Falling vtable check (GetType ok=%d, Update match=%d)",
                      std::memcmp(gt, kGt, 6) == 0 ? 1 : 0, found && reinterpret_cast<uintptr_t>(found) == upd ? 1 : 0);
        dag::log::Writef("RJUMP: %s", g_why);
        return false;
    }
    DWORD old = 0;
    if (!VirtualProtect(&slots[4], sizeof(void*), PAGE_READWRITE, &old)) return false;
    g_origUpdate = reinterpret_cast<UpdateFn>(slots[4]);
    slots[4] = reinterpret_cast<void*>(&HookUpdate);
    DWORD tmp = 0;
    VirtualProtect(&slots[4], sizeof(void*), old, &tmp);
    if (VirtualProtect(&slots[6], sizeof(void*), PAGE_READWRITE, &old)) {
        g_origExit = reinterpret_cast<VoidStateFn>(slots[6]);
        slots[6] = reinterpret_cast<void*>(&HookExit);
        VirtualProtect(&slots[6], sizeof(void*), old, &tmp);
    }
    g_hooked = true;
    dag::log::Writef("RJUMP: Falling Update hooked (vtable rva 0x%llX slot 4, orig rva 0x%llX)",
                     static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(vtp) - g_base),
                     static_cast<unsigned long long>(upd - g_base));
    return true;
}

}  // namespace

void Install()
{
    HMODULE mod = GetModuleHandleW(nullptr);
    g_base = reinterpret_cast<uintptr_t>(mod);
    uint8_t* gs = dag::patternscan::Find(mod, kGetStatePattern);
    if (!gs) {
        strcpy_s(g_why, "failed: MovementMachine GetState pattern not found (game patched?)");
        dag::log::Writef("RJUMP: %s", g_why);
        return;
    }
    g_getState = reinterpret_cast<GetStateFn>(gs);
    g_counter = reinterpret_cast<int*>(g_base + kCounterRva);
    if (uint8_t* pc = dag::patternscan::Find(mod, kProbeCallPattern)) {
        uint8_t* call = pc + 31;
        uint8_t* prev = dag::patternscan::InstallFarCall5(call, reinterpret_cast<void*>(&HookProbe));
        if (prev) {
            g_origProbe = reinterpret_cast<ProbeFn>(prev);
            dag::log::Writef("RJUMP: falling ground-probe call hooked at rva 0x%llX (physics scene for wall/ceiling checks)",
                             static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(call) - g_base));
        }
    } else {
        dag::log::Writef("RJUMP: ground-probe call pattern not found -> no wall/ceiling checks");
    }
    if (uint8_t* sr = dag::patternscan::Find(mod, kSyncResetPattern)) {
        if (dag::patternscan::InstallEntryDetour(sr, kSyncResetEntry, sizeof(kSyncResetEntry), reinterpret_cast<void*>(&HookSyncReset),
                                                 reinterpret_cast<void* volatile*>(&g_origSyncReset)))
            dag::log::Writef("RJUMP: sync guard on the server-flag reset at rva 0x%llX",
                             static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(sr) - g_base));
        else
            dag::log::Writef("RJUMP: sync guard refused (reset entry bytes differ) -> jumps can be cut off ~60 ms in");
    } else {
        dag::log::Writef("RJUMP: sync guard: reset pattern not found -> jumps can be cut off ~60 ms in");
    }
    strcpy_s(g_why, "ready");
    dag::log::Writef("RJUMP: GetState at rva 0x%llX", static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(gs) - g_base));
}

void NoteCharacter(void* character)
{
    if (character && g_base && character != g_char.load(std::memory_order_relaxed) && VtIs(character, kCharVtRva)) {
        g_char.store(character, std::memory_order_relaxed);
        dag::log::Writef("RJUMP: WASD character %p", character);
    }
}

void ForgetCharacter()
{
    if (g_char.exchange(nullptr)) dag::log::Writef("RJUMP: level change / teleport -> WASD character forgotten (re-learned on the next move)");
    g_lastPosT.QuadPart = 0;
    g_measVel[0] = g_measVel[1] = 0.f;
}

void SetStrafeSign(float s) { g_strafeSign = s < 0.f ? -1.f : 1.f; }
void SetLandSpeed(float vmax) { if (vmax > 0.1f && vmax < 50.f) g_landSpeed = vmax; }
void SetWallHeight(float h) { if (h > 0.2f && h < 3.f) g_wallH = h; }

void SetSlopeFollow(float maxDeg)
{
    const float t = (maxDeg > 0.f && maxDeg < 85.f) ? std::tan(maxDeg * 3.14159265f / 180.f) : 0.f;
    if (std::fabs(t - g_slopeTan) > 1e-4f) {
        g_slopeTan = t;
        if (t > 0.f) dag::log::Writef("RJUMP: uphill follow on, slopes up to %.0f deg", maxDeg);
        else dag::log::Writef("RJUMP: uphill follow off (the curve starts at the take-off height)");
    }
}
bool RefusedAirborne() { return g_refusedAirborne; }

void SetLandHold(bool on)
{
    if (g_landHold.exchange(on) != on) dag::log::Writef("RJUMP: BG3's landing hold after a jump %s", on ? "kept" : "skipped");
}

void SetSyncGuard(bool on)
{
    if (g_syncGuard.exchange(on) != on) dag::log::Writef("RJUMP: sync guard %s", on ? "ON" : "off");
}

void MeasureFrame()
{
    Active();   // notices a jump taken off the machine, every frame
    // How long after our jump the fall state stays on the machine (the
    // recover: WASD and the next hop wait for it). Logged once per jump.
    if (g_j.seq && !g_j.active && !g_j.offLogged && g_j.machine) {
        void* l1 = nullptr;
        if (dag::safemem::ReadPtr(g_j.machine, 0x40, l1) && l1 != g_j.state) {
            g_j.offLogged = true;
            LARGE_INTEGER n; QueryPerformanceCounter(&n);
            dag::log::Writef("RJUMP landing: fall state off the machine %.0f ms after the jump's end (hold %s)",
                             (Seconds(g_j.t0, n) - g_j.durMs / 1000.0) * 1000.0, g_j.holdSkipped ? "skipped" : "not seen");
        }
    }
    // Inertia: measured horizontal velocity of the WASD character.
    void* c = g_char.load(std::memory_order_relaxed);
    if (!c) return;
    // A freed or reused object (after a level change) no longer has the
    // character vtable: drop it instead of calling through it.
    if (!VtIs(c, kCharVtRva)) { g_char.store(nullptr); g_lastPosT.QuadPart = 0; return; }
    float p[3];
    LARGE_INTEGER now; QueryPerformanceCounter(&now);
    if (!ReadPos(c, p)) return;
    if (g_lastPosT.QuadPart) {
        const double dt = Seconds(g_lastPosT, now);
        if (dt > 0.005 && dt < 0.5) {
            const float vx = static_cast<float>((p[0] - g_lastPos[0]) / dt), vz = static_cast<float>((p[2] - g_lastPos[2]) / dt);
            g_measVel[0] = g_measVel[0] * 0.6f + vx * 0.4f;
            g_measVel[1] = g_measVel[1] * 0.6f + vz * 0.4f;
        }
    }
    std::memcpy(g_lastPos, p, 12);
    g_lastPosT = now;
}

void SetCameraForward(float fx, float fz) { g_camFwd[0] = fx; g_camFwd[1] = fz; }

float MeasuredSpeed() { return std::sqrt(g_measVel[0] * g_measVel[0] + g_measVel[1] * g_measVel[1]); }

bool Start(float durMs, float h, float k, const float camFwdXZ[2], int seq)
{
    if (!g_getState || !g_counter) { dag::log::Writef("RJUMP: not available (%s)", g_why); return false; }
    uint8_t* c = static_cast<uint8_t*>(g_char.load());
    if (!c) { dag::log::Writef("RJUMP: no WASD character seen yet (move once first) -> visual lift"); return false; }
    if (!VtIs(c, kCharVtRva)) { g_char.store(nullptr); dag::log::Writef("RJUMP: the WASD character is stale (level change?) -> visual lift"); return false; }
    if (camFwdXZ) SetCameraForward(camFwdXZ[0], camFwdXZ[1]);
    uint8_t* machine = nullptr;
    uint8_t* st = nullptr;
    float pos[3];
    if (!ReadPos(c, pos)) { dag::log::Writef("RJUMP: can't read the character position -> visual lift"); return false; }
    __try {
        machine = *reinterpret_cast<uint8_t**>(c + 0x78);
        if (!machine) { dag::log::Writef("RJUMP: no movement machine -> visual lift"); return false; }
        st = g_getState(machine, 6);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        dag::log::Writef("RJUMP: GetState faulted -> visual lift");
        return false;
    }
    if (!st || !VtIs(st, kFallVtRva)) { dag::log::Writef("RJUMP: Falling state not found/validated -> visual lift"); return false; }
    if (!HookVtable(st)) return false;
    g_refusedAirborne = false;
    // Bunny hop: a hop right after our last jump keeps that jump's momentum
    // (the landing stops the measured velocity; playtest 8 hops took off at
    // 0 m/s and were steered at the 2.5 m/s floor).
    float carry[2] = { 0.f, 0.f };
    {
        LARGE_INTEGER n; QueryPerformanceCounter(&n);
        const double sinceLast = g_j.seq && g_j.t0.QuadPart ? Seconds(g_j.t0, n) - g_j.durMs / 1000.0 : 1e9;
        if (!g_j.active && sinceLast > -0.3 && sinceLast < 0.35) { carry[0] = g_j.vel[0]; carry[1] = g_j.vel[1]; }
    }
    __try {
        if (*reinterpret_cast<uint8_t**>(machine + 0x40) == st) {
            // The fall is still on the machine. After our jump that is its
            // landing phase (state >= 2) or the short drop after the curve
            // handed back; hopping right after a landing hit it every other
            // jump (playtest 7), and the jump fell back to the visual lift:
            // you stayed on the ground and BG3's walk carried you on ("the
            // direction changes"). Take the state over for the new jump:
            // exit it, clear layer 1, push it again below.
            const int fallState = *reinterpret_cast<int*>(st + 0x54);
            LARGE_INTEGER now; QueryPerformanceCounter(&now);
            const double sinceEnd = g_j.seq && g_j.t0.QuadPart ? Seconds(g_j.t0, now) - g_j.durMs / 1000.0 : 1e9;
            // Our jump's tail: the curve handed back at the take-off height
            // and the engine hasn't registered the landing yet. Lower than
            // that is a real fall (off a ledge): no take-over mid-air (the
            // bunny-hop grace would make that a double jump); Pov waits for
            // the landing instead.
            const float drop = g_j.seq ? g_j.base - pos[1] : 0.f;
            const bool ourTail = !g_j.active && sinceEnd > -0.05 && sinceEnd < 0.8 && drop < 0.25f;
            if (fallState < 2 && !ourTail) {
                g_refusedAirborne = true;
                if (seq != g_refusedLogSeq) {
                    g_refusedLogSeq = seq;
                    dag::log::Writef("RJUMP: already in the air (fall state %d, %s, %.2f m under the last take-off) -> no jump yet",
                                     fallState, g_j.active ? "our jump still steers" : "not our jump's landing", drop);
                }
                return false;
            }
            auto exitFn = reinterpret_cast<VoidStateFn>(VtSlot(st, 6));
            if (exitFn) exitFn(st);
            *reinterpret_cast<uint8_t**>(machine + 0x40) = nullptr;
            dag::log::Writef("RJUMP: re-arming the last fall for a new jump (fall state %d, %.0f ms after the last jump's end)",
                             fallState, sinceEnd * 1000.0);
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }

    g_j = Jump{};
    g_j.seq = seq; g_j.state = st; g_j.character = c; g_j.machine = machine;
    g_j.durMs = durMs > 50.f ? durMs : 50.f; g_j.h = h; g_j.k = k < 1.f ? 1.f : k;
    std::memcpy(g_j.start, pos, 12);
    std::memcpy(g_j.pos, pos, 12);
    g_j.base = g_j.gLast = pos[1];
    g_j.gx = pos[0]; g_j.gz = pos[2];
    g_j.vel[0] = g_measVel[0]; g_j.vel[1] = g_measVel[1];
    const bool carried = carry[0] * carry[0] + carry[1] * carry[1] > g_j.vel[0] * g_j.vel[0] + g_j.vel[1] * g_j.vel[1];
    if (carried) { g_j.vel[0] = carry[0]; g_j.vel[1] = carry[1]; }
    QueryPerformanceCounter(&g_j.t0);

    // Fill the state like the engine's own push, with the preset flag.
    const float start[3] = { pos[0], pos[1] + 0.03f, pos[2] };
    std::memcpy(st + 0x18, "\0\0\0\0", 4);
    std::memcpy(st + 0x1C, start, 12);
    std::memset(st + 0x28, 0, 12);
    st[0x41] = 0;
    st[0x44] = 1;
    g_j.active = true;   // before Enter: the first Update may run right away
    if (!PushLayer(machine, 0x40, st, "falling")) { g_j.active = false; return false; }
    uint8_t* idle = nullptr;
    __try { idle = g_getState(machine, 4); } __except (EXCEPTION_EXECUTE_HANDLER) {}
    const bool idleOk = idle && PushLayer(machine, 0x38, idle, "idle");
    dag::log::Writef("RJUMP start seq=%d char=%p machine=%p state=%p pos=(%.2f,%.2f,%.2f) vel=(%.2f,%.2f)%s dur=%.0fms h=%.2f k=%.1f layer0 idle=%d",
                     seq, c, machine, st, pos[0], pos[1], pos[2], g_j.vel[0], g_j.vel[1],
                     carried ? " (the last jump's momentum)" : "", g_j.durMs, h, g_j.k, idleOk ? 1 : 0);
    return true;
}

// True while our jump steers. Something else can take the falling state
// off the movement machine mid-air (playtest 2026-10-13: 11 of 53 running
// jumps ended with no end line, and the view snapped back to the ground).
// That ends the jump here, logged, instead of leaving it "active" until the
// next one (where a later ledge fall would have been steered by it).
// GetType (vtable slot 1) of a movement state, -1 if none / unreadable.
int StateType(void* st)
{
    if (!st) return -1;
    __try {
        auto get = reinterpret_cast<int(__fastcall*)(void*)>(VtSlot(st, 1));
        return get ? get(st) : -1;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return -1;
    }
}

bool Active()
{
    if (!g_j.active) return false;
    void* l1 = nullptr;
    const bool ok = g_j.machine && dag::safemem::ReadPtr(g_j.machine, 0x40, l1);
    LARGE_INTEGER now; QueryPerformanceCounter(&now);
    const float u = static_cast<float>(Seconds(g_j.t0, now) * 1000.0 / g_j.durMs);
    if (ok && l1 == g_j.state && u < 2.f) return true;
    g_j.active = false;
    void* l0 = nullptr;
    if (ok) dag::safemem::ReadPtr(g_j.machine, 0x38, l0);
    dag::log::Writef("RJUMP interrupted seq=%d at u=%.2f after %d frames, re-seeds=%d (%s; now layer 0 type %d, layer 1 type %d)",
                     g_j.seq, u, g_j.frames, g_j.reseeds,
                     !ok ? "movement machine unreadable"
                         : (l1 != g_j.state ? "the falling state left the movement machine" : "never handed back"),
                     StateType(l0), StateType(l1));
    return false;
}

const char* State() { return g_why; }

}  // namespace dag::realjump
