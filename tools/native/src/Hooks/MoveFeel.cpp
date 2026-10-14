// SPDX-License-Identifier: GPL-3.0-or-later
//
// Direct WASD movement + movement-feel metrics. See MoveFeel.h and
// docs/spikes/move-feel.md (static RE, bg3_dx11.exe Patch 8).
//
// Client MoveController (vtable rva 0x591A158; BG3WASD unlocks it for the
// keyboard): slot 7 "may WASD run?" (0x14425EC30), slot 25 Enter
// (0x14425F160), slot 26 Update (0x14425F2C0, (ctl, GameTime*), dt at
// GameTime+8). ctl+0x68 = ecl::Character*, ctl+0x100 = input flag byte,
// player id = character+0x12C (0 when its high half is set). All three read
// the movement input through GetMovementInputWorldVec(out vec3*, u16 player,
// u8 flag) (0x14425E7F0): the camera-relative WASD vector, normalised,
// length 1 running, BG3WASD's WalkSpeed walking.
//
// Inside Update:
//   * a 50 ms dead time after every Enter (WASD state +0x80 <= 0.05: only
//     dt is added): the jbe at 0x14425F589;
//   * the move-target offset ("carrot", WASD state +0x34) moves toward
//     speed x dir by at most 16 m/s^2 x dt: the minss at 0x14425FA4C;
//   * the MoveTo request gets |carrot| as an explicit speed; "may WASD run?"
//     stays true while the carrot is non-zero, so after key-up the character
//     walks on to the shrinking carrot (the vanilla stop slide).
// MSMoveTo::Update (0x141BEE2C0) writes the resolved target speed to
// eoc::MovementComponent.Speed2 (+0x14) and steps along its path by
// Movement.Speed (+0x10) x dt; Speed ramps elsewhere. The server's replay of
// the client's synced path (MSMoveToSync, 0x143060A30) does the same.

#include "MoveFeel.h"

#include <windows.h>

#include <atomic>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "../Log.h"
#include "../PatternScan.h"
#include "../SafeMem.h"
#include "AnimRate.h"
#include "MoveSpeed.h"
#include "RealJump.h"

namespace dag::movefeel {

namespace {

constexpr uintptr_t kCharVtRva = 0x56576A0;   // ecl::Character
// Body facing: the steering machine (ecl::Character +0x80) holds its states
// by type at +0x00..+0x20 (type 6 = look-at at +0x20) and the active one at
// +0x38. The look-at state keeps a horizontal direction at +0x18 and turns
// it into SteeringComponent.TargetRotation every frame (Update 0x141BEAA60).
// The push (0x142006580): same type -> Continue, else CanExit / Exit, set,
// counter, Enter.
constexpr uintptr_t kLookVtRva = 0x56508A0;   // steering look-at state (type 6)
constexpr const char* kSteerPushPat =
    "48 89 6C 24 10 48 89 74 24 18 57 48 83 EC 20 48 8B 7A 38 49 8B F1 48 8B EA 48 85 FF 74 ?? 4D 85 C9 74 ?? 48 8B 07 48 8B CF 48 89 5C 24 30 FF 50 08";
constexpr float kFaceDoneDeg = 4.f;      // an idle turn ends this close to the camera
constexpr double kFaceTimeout = 1.5;     // ... or after this long (logged)
constexpr float kStillSpeed = 0.3f;      // m/s, as data move.idle_speed
constexpr float kPi = 3.14159265f;

// Patterns: each unique in Patch 8 .text (byte scan, 2026-10-13).
constexpr const char* kStartInputPat =
    "45 0F B6 87 00 01 00 00 48 8D 4D CF 0F B7 D7 E8 ?? ?? ?? ?? F3 0F 10 55 CF";
constexpr size_t kStartInputCall = 15, kStartFnBack = 0x444;
constexpr const char* kEnterInputPat =
    "44 0F B6 87 00 01 00 00 48 8D 4C 24 30 0F B7 D3 48 8B F0 E8 ?? ?? ?? ?? F2 0F 10 00 F2 0F 11 46 10";
constexpr size_t kEnterInputCall = 19, kEnterFnBack = 0x89;
constexpr const char* kUpdateInputPat =
    "44 0F B6 86 00 01 00 00 0F B7 D7 48 8D 4C 24 40 E8 ?? ?? ?? ?? 4D 8D 7E 10";
constexpr size_t kUpdateInputCall = 16, kUpdateFnBack = 0x1B2;
constexpr const char* kDeadTimePat =
    "F3 41 0F 10 86 80 00 00 00 0F 2F 05 ?? ?? ?? ?? 0F 86 ?? ?? ?? ?? 48 8B D3 49 8B CD E8";
constexpr size_t kDeadTimeJbe = 16;
constexpr const char* kCarrotPat =
    "48 8B 45 30 F3 0F 10 48 08 F3 0F 59 0D ?? ?? ?? ?? F3 0F 5D D9";
constexpr size_t kCarrotMinss = 17;
constexpr const char* kClientStepPat =
    "F3 41 0F 11 75 14 48 8B 45 D0 F3 0F 10 78 10 4C 8B A5 28 02 00 00 F3 41 0F 59 7C 24 08";
constexpr size_t kClientStepLoad = 10;
constexpr const char* kServerStepPat =
    "F3 45 0F 11 41 14 48 8B 44 24 58 F3 44 0F 10 50 10 48 8B 45 80 F3 44 0F 59 50 08";
constexpr size_t kServerStepLoad = 11;

constexpr uint8_t kUpdateProlog[] = { 0x48, 0x8B, 0xC4, 0x48, 0x89, 0x58, 0x10, 0x48, 0x89, 0x70, 0x18, 0x48,
                                      0x89, 0x78, 0x20, 0x55, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57 };
constexpr uint8_t kEnterProlog[] = { 0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10,
                                     0x57, 0x48, 0x83, 0xEC, 0x40, 0x48, 0x8B, 0x41, 0x68 };
constexpr uint8_t kNop6[6] = { 0x66, 0x0F, 0x1F, 0x44, 0x00, 0x00 };
constexpr uint8_t kNop4[4] = { 0x0F, 0x1F, 0x40, 0x00 };

// Speed stubs, called in place of the Movement.Speed load (flag at +0x80 /
// +0x81 of the block): flag set -> Speed = the target speed just resolved
// (still in xmm6 / xmm8) and step with it; flag clear -> the original load.
//   client: cmp byte [rip+f],0 ; je L ; movss [rax+10],xmm6 ; movaps xmm7,xmm6 ; ret
//           L: movss xmm7,[rax+10] ; ret
//   server: cmp byte [rip+f],0 ; je L ; movss [rax+10],xmm8 ; movaps xmm10,xmm8 ; ret
//           L: movss xmm10,[rax+10] ; ret
constexpr uint8_t kClientStub[] = { 0x80, 0x3D, 0, 0, 0, 0, 0x00, 0x74, 0x09, 0xF3, 0x0F, 0x11, 0x70, 0x10,
                                    0x0F, 0x28, 0xFE, 0xC3, 0xF3, 0x0F, 0x10, 0x78, 0x10, 0xC3 };
constexpr uint8_t kServerStub[] = { 0x80, 0x3D, 0, 0, 0, 0, 0x00, 0x74, 0x0B, 0xF3, 0x44, 0x0F, 0x11, 0x40, 0x10,
                                    0x45, 0x0F, 0x28, 0xD0, 0xC3, 0xF3, 0x44, 0x0F, 0x10, 0x50, 0x10, 0xC3 };

using GetVecFn   = float*(__fastcall*)(float* out, uint32_t player, uint32_t flag);
using UpdateFn   = uint64_t(__fastcall*)(void* ctl, uint8_t* gameTime);
using EnterFn    = uint64_t(__fastcall*)(void* ctl);
using GetXformFn = uint8_t*(__fastcall*)(void* character);
using SetQuatFn  = void(__fastcall*)(void* character, const float* quat);
using SteerPushFn = char(__fastcall*)(void* unused, void* machine, void* unused2, void* state);

uintptr_t g_base = 0;
bool      g_ok = false;
char      g_why[160] = "not installed";

GetVecFn g_origStartVec = nullptr, g_origEnterVec = nullptr, g_origUpdateVec = nullptr;
UpdateFn g_origUpdate = nullptr;
EnterFn  g_origEnter = nullptr;
uint8_t* g_deadTime = nullptr;
uint8_t  g_deadTimeOrig[6] = {};
uint8_t* g_carrot = nullptr;
uint8_t  g_carrotOrig[4] = {};
volatile uint8_t* g_clientFlag = nullptr;
volatile uint8_t* g_serverFlag = nullptr;

std::atomic<bool>  g_direct{ false };
std::atomic<float> g_accel{ 0.06f }, g_decel{ 0.04f }, g_turn{ -1.f }, g_strafe{ -1.f };
std::atomic<bool>  g_raw{ false }, g_hold{ false }, g_metricsOn{ false };
std::atomic<float> g_camFx{ 0.f }, g_camFz{ 1.f };
std::atomic<void*> g_char{ nullptr };
std::atomic<float> g_vOut{ 0.f }, g_target{ 0.f };
std::atomic<long>  g_updates{ 0 };
SteerPushFn        g_steerPush = nullptr;
std::atomic<float> g_faceIdle{ 30.f };
std::atomic<bool>  g_faceAir{ true };

// Body facing (camera hook thread, Facing()).
struct Face {
    bool   turning = false;     // an idle turn is running
    double t0 = 0.0;
    float  from = 0.f;          // degrees off when it started
    long   turns = 0;
    bool   air = false;         // following the camera in the air
    long   airFrames = 0;
    float  airMax = 0.f;        // the most the body lagged the camera in the air
    int    pointFails = 0;
} g_f;

// Controller state, game thread only (the MoveController Update).
struct Ctl {
    float vx = 0.f, vz = 0.f;
    float lastTarget = 3.75f;
    bool  walking = true;          // BG3WASD's WalkingIsDefault; learned from its input length
    double lastUpd = 0.0;
    double rawGateSince = 0.0;
    float outX = 0.f, outZ = 0.f;
    bool  outValid = false;
    bool  inUpdate = false;
    float yaw = 0.f;
    bool  yawValid = false;
} g_c;

// Checks for the 2026-10-13 flicker ("MOVEFEEL check" lines, direct mode,
// game thread): BG3's input pointing away from the keys on our camera, the
// body turned by something other than us, a locomotion Start / End clip
// playing in the middle of a steady run.
enum CheckKind { kInputOff, kYawMoved, kLocoMid, kPathOff, kChecks };
const char* kCheckName[kChecks] = { "input off", "body turned by others", "loco clip mid-run", "moving off the keys" };
struct Checks {
    long   n[kChecks] = {};
    long   reported[kChecks] = {};
    double lastReport = 0.0;
    int    keysPrev = 0;
    double keysSince = 0.0;
    double steadySince = 0.0;
    long   locoPrev = 0;
    int    airUpdates = 0;     // controller frames during the current real jump
    double posT = 0.0;         // moving-off-the-keys window start
    float  pos[3] = {};
} g_k;
std::atomic<long> g_checkN[kChecks];

double g_qpcFreq = 0.0;
double Now()
{
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    if (g_qpcFreq == 0.0) { LARGE_INTEGER f; QueryPerformanceFrequency(&f); g_qpcFreq = static_cast<double>(f.QuadPart); }
    return static_cast<double>(c.QuadPart) / g_qpcFreq;
}

bool VtIs(const void* obj, uintptr_t rva)
{
    void* vt = nullptr;
    return obj && dag::safemem::ReadPtr(obj, 0, vt) && reinterpret_cast<uintptr_t>(vt) == g_base + rva;
}

uintptr_t VtSlot(const void* obj, int i)
{
    void* vt = nullptr;
    if (!dag::safemem::ReadPtr(obj, 0, vt) || !vt) return 0;
    uintptr_t f = 0;
    dag::safemem::ReadBytes(reinterpret_cast<uint8_t*>(vt) + i * 8, &f, 8);
    return f;
}

// Translate (+0x10) and rotation quaternion x,y,z,w (+0x00) of the
// character's TransformComponent (ecl::Character vtable +0xD0).
bool ReadXform(void* character, float pos[3], float quat[4])
{
    __try {
        auto get = reinterpret_cast<GetXformFn>(VtSlot(character, 0xD0 / 8));
        if (!get) return false;
        uint8_t* xf = get(character);
        if (!xf) return false;
        if (pos) std::memcpy(pos, xf + 0x10, 12);
        if (quat) std::memcpy(quat, xf, 16);
        return !pos || (std::isfinite(pos[0]) && std::isfinite(pos[1]) && std::isfinite(pos[2]));
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool SetYaw(void* character, float yaw)
{
    const float q[4] = { 0.f, std::sin(yaw * 0.5f), 0.f, std::cos(yaw * 0.5f) };
    __try {
        auto set = reinterpret_cast<SetQuatFn>(VtSlot(character, 0xE0 / 8));
        if (!set) return false;
        set(character, q);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool Foreground()
{
    HWND fg = GetForegroundWindow();
    DWORD pid = 0;
    if (fg) GetWindowThreadProcessId(fg, &pid);
    return pid == GetCurrentProcessId();
}

// W=1 S=2 A=4 D=8, 0 when the game window is not in front.
int KeyMask()
{
    if (!Foreground()) return 0;
    int m = 0;
    if (GetAsyncKeyState('W') & 0x8000) m |= 1;
    if (GetAsyncKeyState('S') & 0x8000) m |= 2;
    if (GetAsyncKeyState('A') & 0x8000) m |= 4;
    if (GetAsyncKeyState('D') & 0x8000) m |= 8;
    return m;
}

// Keys -> world XZ unit vector from the camera forward (RealJump's
// convention: right = forward turned about Y, times the strafe sign).
bool RawWish(int m, float& wx, float& wz)
{
    const float f = ((m & 1) ? 1.f : 0.f) - ((m & 2) ? 1.f : 0.f);
    const float r = (((m & 8) ? 1.f : 0.f) - ((m & 4) ? 1.f : 0.f)) * g_strafe.load(std::memory_order_relaxed);
    const float fx = g_camFx.load(std::memory_order_relaxed), fz = g_camFz.load(std::memory_order_relaxed);
    const float x = fx * f - fz * r, z = fz * f + fx * r;
    const float l = std::sqrt(x * x + z * z);
    if (l < 1e-4f) return false;
    wx = x / l; wz = z / l;
    return true;
}

// Velocity toward wish * S: along the wish it accelerates (A) up to S, and
// brakes (D) first if it points backwards; across the wish it brakes (D).
// No wish: brakes to a stop. accel / decel 0 = instant.
void Integrate(float dt, float wx, float wz, float S)
{
    const float accel = g_accel.load(std::memory_order_relaxed);
    const float decel = g_decel.load(std::memory_order_relaxed);
    float vx = g_c.vx, vz = g_c.vz;
    const float vl = std::sqrt(vx * vx + vz * vz);
    const float ref = g_c.lastTarget > vl ? g_c.lastTarget : vl;
    const float A = accel <= 1e-4f ? 1e9f : (S > 0.f ? S : ref) / accel;
    const float D = decel <= 1e-4f ? 1e9f : ref / decel;
    if (wx != 0.f || wz != 0.f) {
        float a = vx * wx + vz * wz;
        float lx = vx - a * wx, lz = vz - a * wz;
        const float ll = std::sqrt(lx * lx + lz * lz);
        const float nl = ll - D * dt > 0.f ? ll - D * dt : 0.f;
        if (ll > 1e-6f) { lx *= nl / ll; lz *= nl / ll; } else { lx = lz = 0.f; }
        if (a < 0.f)    a = (a + D * dt < 0.f) ? a + D * dt : 0.f;
        else if (a < S) a = (a + A * dt < S) ? a + A * dt : S;
        else            a = (a - D * dt > S) ? a - D * dt : S;
        vx = a * wx + lx;
        vz = a * wz + lz;
    } else if (vl > 1e-6f) {
        const float nl = vl - D * dt > 0.f ? vl - D * dt : 0.f;
        vx *= nl / vl;
        vz *= nl / vl;
    }
    g_c.vx = vx;
    g_c.vz = vz;
}

float WrapPi(float a)
{
    while (a > kPi) a -= 2.f * kPi;
    while (a < -kPi) a += 2.f * kPi;
    return a;
}

// Yaw of a rotation quaternion (x, y, z, w): local +Z = forward.
float QuatYaw(const float q[4])
{
    const float fx = 2.f * (q[0] * q[2] + q[3] * q[1]);
    const float fz = 1.f - 2.f * (q[0] * q[0] + q[1] * q[1]);
    return std::atan2(fx, fz);
}

// One check hit: every hit counts; the first 12 of each kind are logged,
// then every 50th.
void Note(CheckKind k, const char* fmt, ...)
{
    const long n = ++g_k.n[k];
    g_checkN[k].store(n, std::memory_order_relaxed);
    if (n > 12 && n % 50 != 0) return;
    char msg[256];
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    dag::log::Writef("MOVEFEEL check #%ld %s: %s", n, kCheckName[k], msg);
}

void Face(void* ch, float vx, float vz, float dt)
{
    const float turn = g_turn.load(std::memory_order_relaxed);
    if (turn == 0.f) return;   // BG3's own steering turns the body
    const float want = std::atan2(vx, vz);
    float yaw = want;
    if (turn > 0.f) {
        if (!g_c.yawValid) {
            float q[4];
            if (!ReadXform(ch, nullptr, q)) return;
            g_c.yaw = QuatYaw(q);
        }
        const float d = WrapPi(want - g_c.yaw);
        const float step = turn * kPi / 180.f * dt;
        yaw = g_c.yaw + (d > step ? step : (d < -step ? -step : d));
    }
    g_c.yaw = yaw;
    g_c.yawValid = true;
    SetYaw(ch, yaw);
}

// ---- hooks (game thread) -------------------------------------------------

uint64_t __fastcall HookUpdate(void* ctl, uint8_t* gameTime)
{
    g_updates.fetch_add(1, std::memory_order_relaxed);
    void* ch = nullptr;
    dag::safemem::ReadPtr(ctl, 0x68, ch);
    if (ch && ch != g_char.load(std::memory_order_relaxed) && VtIs(ch, kCharVtRva)) {
        g_char.store(ch, std::memory_order_relaxed);
        dag::log::Writef("MOVEFEEL: WASD character %p", ch);
    }
    if (!g_direct.load(std::memory_order_acquire) || !ch) {
        g_c.outValid = false;
        g_c.vx = g_c.vz = 0.f;
        g_c.yawValid = false;
        return g_origUpdate(ctl, gameTime);
    }

    float dt = 1.f / 60.f;
    dag::safemem::ReadFloat(gameTime, 8, dt);
    if (!(dt > 0.f && dt < 0.1f)) dt = 1.f / 60.f;
    const double now = Now();
    // A real jump is in the air (RealJump steers it): the controller sits
    // still, as on BG3's own start-delay frames (its Update returns 0 on every
    // path). Running on, its MoveTo requests re-seeded the fall every few
    // frames, and 11 of 53 running jumps ended mid-air (playtest 3,
    // 2026-10-13). The velocity is kept for the landing.
    if (dag::realjump::Active()) {
        ++g_k.airUpdates;
        g_c.lastUpd = now;
        return 0;
    }
    if (g_k.airUpdates > 0) {
        dag::log::Writef("MOVEFEEL: the WASD controller sat out %d frames of the last jump", g_k.airUpdates);
        g_k.airUpdates = 0;
    }
    // Check: did something else turn the body since our last facing write?
    if (g_c.yawValid && now - g_c.lastUpd < 0.1) {
        float q[4];
        if (ReadXform(ch, nullptr, q)) {
            const float d = std::fabs(WrapPi(QuatYaw(q) - g_c.yaw)) * 180.f / kPi;
            if (d > 20.f) Note(kYawMoved, "%.0f deg away from the facing we set last frame", d);
        }
    }
    if (now - g_c.lastUpd > 0.25) { g_c.vx = g_c.vz = 0.f; g_c.yawValid = false; }   // the controller was idle
    g_c.lastUpd = now;

    // BG3's own movement input (fed by BG3WASD): walk / run, and whether BG3
    // lets the keys move you at all (UI focus, chat, camera mode); its
    // direction too with move_input game.
    uint32_t pid = 0;
    dag::safemem::ReadBytes(reinterpret_cast<uint8_t*>(ch) + 0x12C, &pid, 4);
    if (pid & 0xFFFF0000u) pid = 0;
    uint8_t flag = 0;
    dag::safemem::ReadBytes(reinterpret_cast<uint8_t*>(ctl) + 0x100, &flag, 1);
    float gv[3] = { 0.f, 0.f, 0.f };
    g_origUpdateVec(gv, pid & 0xFFFF, flag);
    const float gl = std::sqrt(gv[0] * gv[0] + gv[2] * gv[2]);
    if (gl > 0.05f) g_c.walking = gl < 0.95f;

    // The physical W/A/S/D on OUR camera's forward (what the real jump steers
    // with). BG3's vector is turned by the yaw of its active gameplay camera
    // object, which BG3 swaps while you move; with instant acceleration a
    // stale yaw there turned the body away and back about once a second (the
    // 2026-10-13 flicker), so move_input raw (the default) moves on ours.
    const int m = KeyMask();
    float kx = 0.f, kz = 0.f;
    const bool keyDir = m != 0 && RawWish(m, kx, kz);
    if (m != g_k.keysPrev) { g_k.keysPrev = m; g_k.keysSince = now; }
    if (keyDir && gl > 0.05f && now - g_k.keysSince > 0.1) {
        float c = (kx * gv[0] + kz * gv[2]) / gl;
        c = c > 1.f ? 1.f : (c < -1.f ? -1.f : c);
        const float ang = std::acos(c) * 180.f / kPi;
        if (ang > 25.f)
            Note(kInputOff, "BG3's input points %.0f deg away from the keys on our camera (BG3 %.2f,%.2f ours %.2f,%.2f)",
                 ang, gv[0] / gl, gv[2] / gl, kx, kz);
    }

    float wx = 0.f, wz = 0.f;
    if (g_raw.load(std::memory_order_relaxed)) {
        if (m) {
            // Keys down but BG3 sees no movement for 120 ms: something else
            // has the keyboard (chat, console, a text field) -> released.
            if (gl <= 0.05f) { if (g_c.rawGateSince == 0.0) g_c.rawGateSince = now; }
            else g_c.rawGateSince = 0.0;
            if (keyDir && !(g_c.rawGateSince != 0.0 && now - g_c.rawGateSince > 0.12)) { wx = kx; wz = kz; }
        } else {
            g_c.rawGateSince = 0.0;
        }
    } else if (gl > 0.05f) {
        wx = gv[0] / gl;
        wz = gv[2] / gl;
    }
    if (g_hold.load(std::memory_order_relaxed)) wx = wz = 0.f;

    const bool wish = (wx != 0.f || wz != 0.f);
    const float S = wish ? dag::movespeed::NaturalSpeed(g_c.walking) : 0.f;
    if (S > 0.f) g_c.lastTarget = S;
    Integrate(dt, wx, wz, S);
    const float sp = std::sqrt(g_c.vx * g_c.vx + g_c.vz * g_c.vz);
    float speed = 0.f;
    if (sp > 0.03f) {
        g_c.outX = g_c.vx / sp; g_c.outZ = g_c.vz / sp; speed = sp;
    } else if (wish) {
        g_c.outX = wx; g_c.outZ = wz; speed = 0.05f;   // turning around: never a stop frame
    } else {
        g_c.outX = g_c.outZ = 0.f;                      // zero carrot: BG3 stops on the spot
    }
    g_c.outValid = true;
    g_vOut.store(speed, std::memory_order_relaxed);
    g_target.store(S, std::memory_order_relaxed);

    // Check: the locomotion Start / End clips (sped up in direct mode) should
    // not play in the middle of a steady run.
    const long lh = dag::animrate::LocoHits();
    if (wish && S > 0.f && sp >= 0.9f * S && now - g_k.keysSince > 0.4) {
        if (g_k.steadySince == 0.0) g_k.steadySince = now;
    } else {
        g_k.steadySince = 0.0;
    }
    if (g_k.steadySince != 0.0 && now - g_k.steadySince > 0.3 && lh > g_k.locoPrev)
        Note(kLocoMid, "a locomotion Start / End clip is playing (%ld hook calls) at %.2f m/s", lh - g_k.locoPrev, sp);
    g_k.locoPrev = lh;

    // Check: the character really moves where the keys point. BG3 walks
    // you along a nav path to pos + carrot; off its walkable map (debris,
    // a rock) or around a blocker that path can head somewhere else
    // (playtest 6: "suddenly changes direction completely"). Measured over
    // >= 0.1 s windows of the real position, keys steady 0.3 s, > 1 m/s.
    {
        float pos[3];
        if (ReadXform(ch, pos, nullptr)) {
            if (g_k.posT == 0.0 || now - g_k.posT > 0.5) {
                std::memcpy(g_k.pos, pos, 12);
                g_k.posT = now;
            } else if (now - g_k.posT >= 0.1) {
                const float mvx = static_cast<float>((pos[0] - g_k.pos[0]) / (now - g_k.posT));
                const float mvz = static_cast<float>((pos[2] - g_k.pos[2]) / (now - g_k.posT));
                const float ms = std::sqrt(mvx * mvx + mvz * mvz);
                if (wish && ms > 1.f && now - g_k.keysSince > 0.3) {
                    float c = (mvx * wx + mvz * wz) / ms;
                    c = c > 1.f ? 1.f : (c < -1.f ? -1.f : c);
                    const float ang = std::acos(c) * 180.f / kPi;
                    if (ang > 60.f)
                        Note(kPathOff, "moving %.0f deg away from the keys at %.2f m/s, at (%.2f, %.2f, %.2f)", ang, ms, pos[0],
                             pos[1], pos[2]);
                }
                std::memcpy(g_k.pos, pos, 12);
                g_k.posT = now;
            }
        }
    }

    if (now - g_k.lastReport >= 30.0) {
        g_k.lastReport = now;
        if (std::memcmp(g_k.n, g_k.reported, sizeof(g_k.n)) != 0) {
            dag::log::Writef("MOVEFEEL checks so far: input off %ld, body turned by others %ld, loco clip mid-run %ld, moving off the keys %ld",
                             g_k.n[0], g_k.n[1], g_k.n[2], g_k.n[3]);
            std::memcpy(g_k.reported, g_k.n, sizeof(g_k.n));
        }
    }

    dag::movespeed::SetDirectSpeed(speed);
    g_c.inUpdate = true;
    const uint64_t r = g_origUpdate(ctl, gameTime);
    g_c.inUpdate = false;
    dag::movespeed::SetDirectSpeed(-1.f);

    if (sp > 0.25f) Face(ch, g_c.vx, g_c.vz, dt);
    else g_c.yawValid = false;
    return r;
}

uint64_t __fastcall HookEnter(void* ctl)
{
    if (Now() - g_c.lastUpd > 0.25) { g_c.vx = g_c.vz = 0.f; g_c.yawValid = false; }
    return g_origEnter(ctl);
}

float* __fastcall HookUpdateVec(float* out, uint32_t player, uint32_t flag)
{
    if (g_c.inUpdate && g_c.outValid) {
        // Unit length: the MoveController's lerp lands on Run, which the
        // direct speed (MoveSpeed.cpp) has set to our speed this frame.
        out[0] = g_c.outX; out[1] = 0.f; out[2] = g_c.outZ;
        return out;
    }
    return g_origUpdateVec(out, player, flag);
}

float* __fastcall HookStartVec(float* out, uint32_t player, uint32_t flag)
{
    float* r = g_origStartVec(out, player, flag);
    if (g_direct.load(std::memory_order_relaxed) && g_hold.load(std::memory_order_relaxed) && r) r[0] = r[1] = r[2] = 0.f;
    return r;
}

float* __fastcall HookEnterVec(float* out, uint32_t player, uint32_t flag)
{
    float* r = g_origEnterVec(out, player, flag);
    if (g_direct.load(std::memory_order_relaxed) && g_hold.load(std::memory_order_relaxed) && r) r[0] = r[1] = r[2] = 0.f;
    return r;
}

// ---- install ---------------------------------------------------------------

bool FindVtable(uint8_t* updateFn, uint8_t* enterFn, uint8_t* startFn, uintptr_t*& slotUpdate)
{
    const uintptr_t base = g_base;
    auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    auto* nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    IMAGE_SECTION_HEADER* sec = IMAGE_FIRST_SECTION(nt);
    for (int i = 0; i < nt->FileHeader.NumberOfSections; ++i, ++sec) {
        if (std::memcmp(sec->Name, ".rdata", 6) != 0) continue;
        auto* q = reinterpret_cast<uintptr_t*>(base + sec->VirtualAddress);
        const size_t n = sec->Misc.VirtualSize / sizeof(uintptr_t);
        for (size_t k = 19; k < n; ++k) {
            if (q[k] != reinterpret_cast<uintptr_t>(updateFn)) continue;
            if (q[k - 1] != reinterpret_cast<uintptr_t>(enterFn) || q[k - 19] != reinterpret_cast<uintptr_t>(startFn)) continue;
            slotUpdate = &q[k];
            return true;
        }
    }
    return false;
}

bool WriteSlot(uintptr_t* slot, void* fn)
{
    DWORD old = 0;
    if (!VirtualProtect(slot, sizeof(uintptr_t), PAGE_READWRITE, &old)) return false;
    *slot = reinterpret_cast<uintptr_t>(fn);
    DWORD tmp = 0;
    VirtualProtect(slot, sizeof(uintptr_t), old, &tmp);
    return true;
}

bool Fail(const char* why)
{
    std::snprintf(g_why, sizeof(g_why), "failed: %s", why);
    dag::log::Writef("MOVEFEEL: %s -> direct mode unavailable (vanilla movement)", g_why);
    return false;
}

// Points `site` (n = 5 or 6 bytes, one whole instruction) at a stub copied
// into `blk`, whose flag byte is `flag` (rip-relative cmp at stub+2).
bool InstallStub(uint8_t* site, size_t n, uint8_t* blk, const uint8_t* code, size_t codeLen, uint8_t* flag)
{
    std::memcpy(blk, code, codeLen);
    const int32_t rel = static_cast<int32_t>(flag - (blk + 7));
    std::memcpy(blk + 2, &rel, 4);
    FlushInstructionCache(GetCurrentProcess(), blk, codeLen);
    uint8_t patch[8] = { 0xE8, 0, 0, 0, 0, 0x90, 0x90, 0x90 };
    const int32_t disp = static_cast<int32_t>(blk - (site + 5));
    std::memcpy(patch + 1, &disp, 4);
    return dag::patternscan::PatchCode(site, patch, n);
}

}  // namespace

void Install()
{
    HMODULE mod = GetModuleHandleW(nullptr);
    g_base = reinterpret_cast<uintptr_t>(mod);
    uint8_t* ps = dag::patternscan::Find(mod, kStartInputPat);
    uint8_t* pe = dag::patternscan::Find(mod, kEnterInputPat);
    uint8_t* pu = dag::patternscan::Find(mod, kUpdateInputPat);
    if (!ps || !pe || !pu) { Fail("MoveController input-call patterns not found (game patched?)"); return; }
    uint8_t* startFn = ps - kStartFnBack;
    uint8_t* enterFn = pe - kEnterFnBack;
    uint8_t* updateFn = pu - kUpdateFnBack;
    if (std::memcmp(updateFn, kUpdateProlog, sizeof(kUpdateProlog)) != 0 ||
        std::memcmp(enterFn, kEnterProlog, sizeof(kEnterProlog)) != 0) {
        Fail("MoveController Update / Enter prologue mismatch");
        return;
    }
    uintptr_t* slotUpdate = nullptr;
    if (!FindVtable(updateFn, enterFn, startFn, slotUpdate)) { Fail("MoveController vtable not found"); return; }

    uint8_t* dt = dag::patternscan::Find(mod, kDeadTimePat);
    uint8_t* cr = dag::patternscan::Find(mod, kCarrotPat);
    uint8_t* cs = dag::patternscan::Find(mod, kClientStepPat);
    uint8_t* ss = dag::patternscan::Find(mod, kServerStepPat);
    if (!dt || !cr || !cs || !ss) { Fail("start-delay / ramp / step patterns not found"); return; }
    g_deadTime = dt + kDeadTimeJbe;
    g_carrot = cr + kCarrotMinss;
    if (g_deadTime[0] != 0x0F || g_deadTime[1] != 0x86 || std::memcmp(g_carrot, "\xF3\x0F\x5D\xD9", 4) != 0) {
        g_deadTime = g_carrot = nullptr;
        Fail("start-delay / ramp instructions differ");
        return;
    }
    std::memcpy(g_deadTimeOrig, g_deadTime, 6);
    std::memcpy(g_carrotOrig, g_carrot, 4);

    uint8_t* blk = dag::patternscan::AllocNear(cs, 0x100);
    if (!blk) { Fail("no memory near the step code for the speed stubs"); return; }
    std::memset(blk, 0xCC, 0x100);
    uint8_t* cflag = blk + 0x80;
    uint8_t* sflag = blk + 0x81;
    *cflag = 0;
    *sflag = 0;
    if (!InstallStub(cs + kClientStepLoad, 5, blk, kClientStub, sizeof(kClientStub), cflag) ||
        !InstallStub(ss + kServerStepLoad, 6, blk + 0x40, kServerStub, sizeof(kServerStub), sflag)) {
        Fail("could not patch the MoveTo step loads");
        return;
    }
    g_clientFlag = cflag;
    g_serverFlag = sflag;

    uint8_t* a = dag::patternscan::InstallFarCall5(ps + kStartInputCall, reinterpret_cast<void*>(&HookStartVec));
    uint8_t* b = dag::patternscan::InstallFarCall5(pe + kEnterInputCall, reinterpret_cast<void*>(&HookEnterVec));
    uint8_t* c = dag::patternscan::InstallFarCall5(pu + kUpdateInputCall, reinterpret_cast<void*>(&HookUpdateVec));
    if (!a || !b || !c) { Fail("could not hook the input calls"); return; }
    g_origStartVec = reinterpret_cast<GetVecFn>(a);
    g_origEnterVec = reinterpret_cast<GetVecFn>(b);
    g_origUpdateVec = reinterpret_cast<GetVecFn>(c);

    g_origUpdate = reinterpret_cast<UpdateFn>(updateFn);
    g_origEnter = reinterpret_cast<EnterFn>(enterFn);
    if (!WriteSlot(slotUpdate, reinterpret_cast<void*>(&HookUpdate)) ||
        !WriteSlot(slotUpdate - 1, reinterpret_cast<void*>(&HookEnter))) {
        Fail("could not patch the MoveController vtable");
        return;
    }
    if (uint8_t* sp = dag::patternscan::Find(mod, kSteerPushPat)) {
        g_steerPush = reinterpret_cast<SteerPushFn>(sp);
        dag::log::Writef("MOVEFEEL: steering push at rva 0x%llX (body facing from the camera)",
                         static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(sp) - g_base));
    } else {
        dag::log::Writef("MOVEFEEL: steering push pattern not found -> no body facing from the camera");
    }
    g_ok = true;
    strcpy_s(g_why, "vanilla");
    dag::log::Writef("MOVEFEEL: installed (MoveController vtable slot rva 0x%llX, start-delay rva 0x%llX, ramp rva 0x%llX, "
                     "client step rva 0x%llX, server step rva 0x%llX); direct mode when Lua asks",
                     static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(slotUpdate) - g_base),
                     static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(g_deadTime) - g_base),
                     static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(g_carrot) - g_base),
                     static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(cs + kClientStepLoad) - g_base),
                     static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(ss + kServerStepLoad) - g_base));
}

namespace {

void ApplyDirect(bool on, const char* why)
{
    if (on) {
        dag::patternscan::PatchCode(g_deadTime, kNop6, 6);
        dag::patternscan::PatchCode(g_carrot, kNop4, 4);
    } else {
        dag::patternscan::PatchCode(g_deadTime, g_deadTimeOrig, 6);
        dag::patternscan::PatchCode(g_carrot, g_carrotOrig, 4);
    }
    *g_clientFlag = on ? 1 : 0;
    *g_serverFlag = on ? 1 : 0;
    g_direct.store(on, std::memory_order_release);
    strcpy_s(g_why, on ? "direct" : "vanilla");
    dag::log::Writef("MOVEFEEL: %s (%s) accel %.3fs decel %.3fs turn %s input %s", on ? "DIRECT" : "VANILLA", why,
                     g_accel.load(), g_decel.load(),
                     g_turn.load() < 0.f ? "instant" : (g_turn.load() == 0.f ? "engine" : "deg/s"),
                     g_raw.load() ? "raw keys" : "BG3 axes");
}

}  // namespace

void Configure(const Settings& s, bool povLive)
{
    g_faceIdle.store(s.faceIdleDeg, std::memory_order_relaxed);
    g_faceAir.store(s.faceAir, std::memory_order_relaxed);
    g_accel.store(s.accelS < 0.f ? 0.f : s.accelS, std::memory_order_relaxed);
    g_decel.store(s.decelS < 0.f ? 0.f : s.decelS, std::memory_order_relaxed);
    g_turn.store(s.turn, std::memory_order_relaxed);
    g_raw.store(s.rawInput, std::memory_order_relaxed);
    g_strafe.store(s.strafeSign < 0.f ? -1.f : 1.f, std::memory_order_relaxed);
    g_hold.store(s.hold, std::memory_order_relaxed);
    g_metricsOn.store(s.metrics, std::memory_order_relaxed);
    if (!g_ok) return;
    const bool want = s.direct && povLive;
    if (want != g_direct.load(std::memory_order_relaxed)) {
        ApplyDirect(want, want ? "first person, move_mode direct"
                               : (!s.direct ? "move_mode vanilla" : "first person off / paused / downed"));
    }
    // Multiplayer (host): the server replays every player's synced path. With
    // other players connected, its step stub follows the direct-mode setting,
    // not this machine's first person (the host in a menu or in third person
    // must not slow the others' replay). Alone: exactly as before.
    if (g_serverFlag) {
        const bool serverWant = s.direct && (povLive || s.mpRemote);
        if ((*g_serverFlag != 0) != serverWant) {
            *g_serverFlag = serverWant ? 1 : 0;
            dag::log::Writef("MOVEFEEL: server path replay %s (direct %d, first person %d, other players %d)",
                             serverWant ? "at the requested speed" : "vanilla", s.direct ? 1 : 0, povLive ? 1 : 0, s.mpRemote ? 1 : 0);
        }
    }
}

void SetCameraForward(float fx, float fz)
{
    g_camFx.store(fx, std::memory_order_relaxed);
    g_camFz.store(fz, std::memory_order_relaxed);
}

namespace {

// Point BG3's look-at steering along (fx, fz): its Update turns the body
// there at BG3's own rate. Pushed as the active steering state if it isn't.
bool Point(void* ch, float fx, float fz)
{
    __try {
        uint8_t* steer = *reinterpret_cast<uint8_t**>(static_cast<uint8_t*>(ch) + 0x80);
        if (!steer) return false;
        uint8_t* look = *reinterpret_cast<uint8_t**>(steer + 0x20);
        if (!look || !VtIs(look, kLookVtRva)) return false;   // made by the first WASD move
        float* d = reinterpret_cast<float*>(look + 0x18);
        d[0] = fx;   // the look-at direction is the way the body should face
        d[1] = 0.f;  // (as the WASD controller's step direction; playtest 10)
        d[2] = fz;
        if (*reinterpret_cast<uint8_t**>(steer + 0x38) != look && !g_steerPush(nullptr, steer, nullptr, look)) return false;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

void PointOrNote(void* ch, float fx, float fz)
{
    if (Point(ch, fx, fz)) return;
    if (++g_f.pointFails <= 5 || g_f.pointFails % 100 == 0)
        dag::log::Writef("FACING: couldn't point BG3's steering (#%d: no look-at state yet = move once first, or the active steering state can't exit)",
                         g_f.pointFails);
}

}  // namespace

void Facing(bool airborne)
{
    void* ch = g_char.load(std::memory_order_relaxed);
    if (!g_steerPush || !g_direct.load(std::memory_order_relaxed) || !ch || !VtIs(ch, kCharVtRva)) {
        g_f.turning = false;
        g_f.air = false;
        return;
    }
    float q[4];
    if (!ReadXform(ch, nullptr, q)) return;
    const float fx = g_camFx.load(std::memory_order_relaxed), fz = g_camFz.load(std::memory_order_relaxed);
    // The body's visible front is the Transform's local -Z, not +Z
    // (playtest 10: walking forward then stopping read as 180 deg off, and
    // the build 11 self-check "fixed" it by turning everyone around).
    const float bodyYaw = QuatYaw(q) + kPi;
    const float off = std::fabs(WrapPi(std::atan2(fx, fz) - bodyYaw)) * 180.f / kPi;
    const double now = Now();

    // In the air: the body follows the camera every frame.
    const bool air = airborne && g_faceAir.load(std::memory_order_relaxed);
    if (air != g_f.air) {
        if (!air && g_f.airFrames > 0)
            dag::log::Writef("FACING: air: the body followed the camera for %ld frames, at most %.0f deg behind", g_f.airFrames, g_f.airMax);
        g_f.air = air;
        g_f.airFrames = 0;
        g_f.airMax = 0.f;
    }
    if (air) {
        ++g_f.airFrames;
        if (off > g_f.airMax) g_f.airMax = off;
        g_f.turning = false;
        PointOrNote(ch, fx, fz);
        return;
    }
    if (airborne) return;   // face_air off: BG3's own

    // On the ground: moving keeps BG3's facing (the way you move).
    if (KeyMask() != 0 || dag::realjump::MeasuredSpeed() > kStillSpeed) {
        g_f.turning = false;
        return;
    }
    const bool logTurn = g_f.turns <= 10 || g_f.turns % 25 == 0;
    if (g_f.turning) {
        if (off < kFaceDoneDeg) {
            g_f.turning = false;
            if (logTurn) dag::log::Writef("FACING: idle turn #%ld done, %.0f deg -> %.0f deg in %.0f ms", g_f.turns, g_f.from, off, (now - g_f.t0) * 1000.0);
            return;
        }
        if (now - g_f.t0 > kFaceTimeout) {
            g_f.turning = false;
            dag::log::Writef("FACING: idle turn #%ld gave up after %.1f s, still %.0f deg off (from %.0f)%s", g_f.turns, now - g_f.t0, off, g_f.from,
                             off > 150.f ? " -- the body faces AWAY from the camera" : "");
            return;
        }
        PointOrNote(ch, fx, fz);
        return;
    }
    const float idle = g_faceIdle.load(std::memory_order_relaxed);
    if (idle > 0.f && off > idle) {
        g_f.turning = true;
        g_f.t0 = now;
        g_f.from = off;
        ++g_f.turns;
        PointOrNote(ch, fx, fz);
    }
}

void ForgetCharacter()
{
    if (g_char.exchange(nullptr)) dag::log::Writef("MOVEFEEL: level change / teleport -> WASD character forgotten");
}

const char* State() { return g_why; }

// ---------------------------------------------------------------------------
// Metrics (render thread). Position of the WASD character every frame, the
// physical W/A/S/D state, and four probes:
//   start    keys down from standing -> first time at 90% of the speed it
//            holds 0.7-1.0 s later (and the first visible motion);
//   stop     all keys up while moving -> time until the position stops
//            changing, and how far it slid;
//   reverse  the key direction flips (W -> S) while moving -> time until the
//            velocity points the other way at 90% of the old speed;
//   strafe   the key direction turns 30-150 degrees while moving -> time until
//            the velocity has turned that far (within 10 degrees).
// The angles are in camera space: keep the mouse still for these.
// Corrections: a frame whose horizontal jump is far more than the speed
// explains (6 m or more counts as a teleport instead).
// ---------------------------------------------------------------------------
namespace {

constexpr int kRing = 512;
struct Sample { double t; float x, y, z; };
Sample g_ring[kRing];
int    g_ringN = 0, g_ringHead = 0;   // head = next write

const Sample& At(int back) { return g_ring[(g_ringHead - 1 - back + kRing * 2) % kRing]; }

void Push(double t, const float p[3])
{
    g_ring[g_ringHead] = { t, p[0], p[1], p[2] };
    g_ringHead = (g_ringHead + 1) % kRing;
    if (g_ringN < kRing) ++g_ringN;
}

// Horizontal velocity over the last ~60 ms.
bool Velocity(float& vx, float& vz)
{
    if (g_ringN < 2) return false;
    const Sample& a = At(0);
    for (int i = 1; i < g_ringN; ++i) {
        const Sample& b = At(i);
        const double dt = a.t - b.t;
        if (dt >= 0.06) {
            vx = static_cast<float>((a.x - b.x) / dt);
            vz = static_cast<float>((a.z - b.z) / dt);
            return true;
        }
    }
    return false;
}

enum Kind { kStart, kStop, kReverse, kStrafe, kKinds };
const char* kKindName[kKinds] = { "start", "stop", "reverse", "strafe" };

struct Probe {
    bool   active = false;
    double t0 = 0;
    float  p0[3] = {};
    float  v0x = 0, v0z = 0, v0 = 0;
    float  turnDeg = 0;
    int    keys = 0;
    double tFirst = 0;
    double tStill = 0;
    // start: (t, speed) trace
    int    n = 0;
    double tt[160];
    float  sp[160];
} g_probe[kKinds];

constexpr int kStats = 64;
struct Stat { float v[kStats]; float extra[kStats]; int n = 0; } g_stat[kKinds];

struct Metrics {
    bool   on = false;
    double since = 0, lastSummary = 0;
    int    keysPrev = 0;
    float  wishPrevF = 0, wishPrevR = 0;
    double lastChangeT = 0;
    float  lastChange[3] = {};
    bool   haveChange = false;
    int    corrections = 0, teleports = 0;
    float  maxSpeed = 0;
} g_m;

void AddStat(Kind k, float v, float extra)
{
    Stat& s = g_stat[k];
    if (s.n < kStats) { s.v[s.n] = v; s.extra[s.n] = extra; ++s.n; }
}

float Median(const float* a, int n)
{
    if (n <= 0) return 0.f;
    float t[kStats];
    std::memcpy(t, a, sizeof(float) * n);
    for (int i = 1; i < n; ++i) for (int j = i; j > 0 && t[j] < t[j - 1]; --j) { const float x = t[j]; t[j] = t[j - 1]; t[j - 1] = x; }
    return (n & 1) ? t[n / 2] : 0.5f * (t[n / 2 - 1] + t[n / 2]);
}

float Max(const float* a, int n)
{
    float m = 0.f;
    for (int i = 0; i < n; ++i) if (a[i] > m) m = a[i];
    return m;
}

const char* ModeTag() { return g_direct.load(std::memory_order_relaxed) ? "direct" : "vanilla"; }

void Summary(const char* why)
{
    const Stat& st = g_stat[kStart];
    const Stat& sp = g_stat[kStop];
    const Stat& rv = g_stat[kReverse];
    const Stat& sf = g_stat[kStrafe];
    dag::log::Writef("MOVEFEEL summary [%s] (%s, %.0f s): start n=%d 90%% med %.0f ms max %.0f | stop n=%d med %.0f ms max %.0f, "
                     "slide med %.2f m max %.2f | reverse n=%d med %.0f ms max %.0f | strafe n=%d med %.0f ms max %.0f | "
                     "corrections %d, teleports %d, top speed %.2f m/s | checks (whole session): input off %ld, "
                     "body turned by others %ld, loco clip mid-run %ld, moving off the keys %ld",
                     ModeTag(), why, Now() - g_m.since,
                     st.n, Median(st.v, st.n), Max(st.v, st.n),
                     sp.n, Median(sp.v, sp.n), Max(sp.v, sp.n), Median(sp.extra, sp.n), Max(sp.extra, sp.n),
                     rv.n, Median(rv.v, rv.n), Max(rv.v, rv.n),
                     sf.n, Median(sf.v, sf.n), Max(sf.v, sf.n),
                     g_m.corrections, g_m.teleports, g_m.maxSpeed,
                     g_checkN[kInputOff].load(), g_checkN[kYawMoved].load(), g_checkN[kLocoMid].load(), g_checkN[kPathOff].load());
}

void ResetStats()
{
    for (auto& s : g_stat) s.n = 0;
    for (auto& p : g_probe) p.active = false;
    g_m.corrections = g_m.teleports = 0;
    g_m.maxSpeed = 0.f;
}

float AngleDeg(float ax, float az, float bx, float bz)
{
    const float la = std::sqrt(ax * ax + az * az), lb = std::sqrt(bx * bx + bz * bz);
    if (la < 1e-5f || lb < 1e-5f) return 0.f;
    float c = (ax * bx + az * bz) / (la * lb);
    c = c > 1.f ? 1.f : (c < -1.f ? -1.f : c);
    return std::acos(c) * 180.f / kPi;
}

void StartProbe(Kind k, double now, const float p[3], float vx, float vz, int keys, float turnDeg)
{
    Probe& pr = g_probe[k];
    pr = Probe{};
    pr.active = true;
    pr.t0 = now;
    std::memcpy(pr.p0, p, 12);
    pr.v0x = vx; pr.v0z = vz; pr.v0 = std::sqrt(vx * vx + vz * vz);
    pr.keys = keys;
    pr.turnDeg = turnDeg;
}

void RunProbes(double now, const float p[3], float vx, float vz, float speed, int keys)
{
    // start: 90% of the speed it settles at (0.7-1.0 s after the press)
    Probe& s = g_probe[kStart];
    if (s.active) {
        if (keys != s.keys) {
            s.active = false;   // released / changed before it settled
        } else {
            if (s.tFirst == 0.0) {
                const float dx = p[0] - s.p0[0], dz = p[2] - s.p0[2];
                if (dx * dx + dz * dz > 0.02f * 0.02f) s.tFirst = now;
            }
            if (s.n < 160) { s.tt[s.n] = now; s.sp[s.n] = speed; ++s.n; }
            if (now - s.t0 >= 1.0) {
                float sum = 0.f; int c = 0;
                for (int i = 0; i < s.n; ++i) if (s.tt[i] - s.t0 >= 0.7) { sum += s.sp[i]; ++c; }
                const float vf = c ? sum / c : 0.f;
                double t90 = -1.0;
                for (int i = 0; i < s.n && vf > 0.2f; ++i) if (s.sp[i] >= 0.9f * vf) { t90 = s.tt[i] - s.t0; break; }
                if (t90 >= 0.0) {
                    AddStat(kStart, static_cast<float>(t90 * 1000.0), vf);
                    dag::log::Writef("MOVEFEEL [%s] start: 90%% speed after %.0f ms (first motion %.0f ms, settles at %.2f m/s)",
                                     ModeTag(), t90 * 1000.0, s.tFirst > 0.0 ? (s.tFirst - s.t0) * 1000.0 : -1.0, vf);
                }
                s.active = false;
            }
        }
    }
    // stop: until the position no longer changes
    Probe& t = g_probe[kStop];
    if (t.active) {
        if (keys != 0) {
            t.active = false;
        } else {
            if (speed > 0.05f) t.tStill = 0.0;
            else if (t.tStill == 0.0) t.tStill = now;
            if (t.tStill != 0.0 && now - t.tStill >= 0.15) {
                // last time the character was more than 1 cm from where it ended
                double tEnd = t.t0;
                for (int i = 0; i < g_ringN; ++i) {
                    const Sample& a = At(i);
                    if (a.t < t.t0) break;
                    const float dx = a.x - p[0], dz = a.z - p[2];
                    if (dx * dx + dz * dz > 0.01f * 0.01f) { tEnd = a.t; break; }
                }
                const float sx = p[0] - t.p0[0], sz = p[2] - t.p0[2];
                const float slide = std::sqrt(sx * sx + sz * sz);
                AddStat(kStop, static_cast<float>((tEnd - t.t0) * 1000.0), slide);
                dag::log::Writef("MOVEFEEL [%s] stop: %.0f ms, slide %.2f m (from %.2f m/s)", ModeTag(),
                                 (tEnd - t.t0) * 1000.0, slide, t.v0);
                t.active = false;
            } else if (now - t.t0 > 2.0) {
                dag::log::Writef("MOVEFEEL [%s] stop: still moving 2 s after release (%.2f m/s)", ModeTag(), speed);
                t.active = false;
            }
        }
    }
    // reverse / strafe: until the velocity has turned
    for (Kind k : { kReverse, kStrafe }) {
        Probe& r = g_probe[k];
        if (!r.active) continue;
        if (keys != r.keys) { r.active = false; continue; }
        const float ang = AngleDeg(vx, vz, r.v0x, r.v0z);
        const bool done = (k == kReverse) ? (ang > 150.f && speed >= 0.9f * r.v0)
                                          : (ang >= r.turnDeg - 10.f && speed >= 0.6f * r.v0);
        if (done) {
            AddStat(k, static_cast<float>((now - r.t0) * 1000.0), r.turnDeg);
            if (k == kReverse)
                dag::log::Writef("MOVEFEEL [%s] reverse: %.0f ms (%.2f m/s back to %.2f)", ModeTag(), (now - r.t0) * 1000.0, r.v0, speed);
            else
                dag::log::Writef("MOVEFEEL [%s] strafe %.0f deg: %.0f ms", ModeTag(), r.turnDeg, (now - r.t0) * 1000.0);
            r.active = false;
        } else if (now - r.t0 > 2.0) {
            dag::log::Writef("MOVEFEEL [%s] %s: not settled after 2 s (turned %.0f deg, %.2f m/s)", ModeTag(), kKindName[k], ang, speed);
            r.active = false;
        }
    }
}

}  // namespace

void Frame()
{
    const bool want = g_metricsOn.load(std::memory_order_relaxed);
    if (!want) {
        if (g_m.on) { Summary("metrics off"); g_m.on = false; }
        return;
    }
    const double now = Now();
    if (!g_m.on) {
        g_m = Metrics{};
        g_m.on = true;
        g_m.since = g_m.lastSummary = now;
        g_ringN = g_ringHead = 0;
        ResetStats();
        dag::log::Writef("MOVEFEEL metrics ON [%s] (character %p)", ModeTag(), g_char.load());
    }
    void* ch = g_char.load(std::memory_order_relaxed);
    if (!ch || !VtIs(ch, kCharVtRva)) return;
    float p[3];
    if (!ReadXform(ch, p, nullptr)) return;
    Push(now, p);

    // Corrections: a horizontal jump the speed can't explain.
    if (g_m.haveChange) {
        const float dx = p[0] - g_m.lastChange[0], dz = p[2] - g_m.lastChange[2];
        const float d = std::sqrt(dx * dx + dz * dz);
        if (d > 1e-4f) {
            const double dtc = now - g_m.lastChangeT;
            float vx = 0, vz = 0;
            Velocity(vx, vz);
            float vmax = std::sqrt(vx * vx + vz * vz);
            const float tgt = g_target.load(std::memory_order_relaxed);
            if (tgt > vmax) vmax = tgt;
            if (vmax < 1.f) vmax = 1.f;
            const float allowed = static_cast<float>(vmax * 2.0 * dtc) + 0.25f;
            if (d > allowed) {
                if (d < 6.f) {
                    ++g_m.corrections;
                    dag::log::Writef("MOVEFEEL [%s] CORRECTION #%d: %.2f m jump in %.0f ms (speed %.2f) at (%.2f, %.2f)", ModeTag(),
                                     g_m.corrections, d, dtc * 1000.0, vmax, p[0], p[2]);
                } else {
                    ++g_m.teleports;
                    dag::log::Writef("MOVEFEEL [%s] teleport: %.1f m (not a correction)", ModeTag(), d);
                }
            }
            std::memcpy(g_m.lastChange, p, 12);
            g_m.lastChangeT = now;
        }
    } else {
        std::memcpy(g_m.lastChange, p, 12);
        g_m.lastChangeT = now;
        g_m.haveChange = true;
    }

    float vx = 0.f, vz = 0.f;
    if (!Velocity(vx, vz)) return;
    const float speed = std::sqrt(vx * vx + vz * vz);
    if (speed > g_m.maxSpeed && speed < 20.f) g_m.maxSpeed = speed;

    const int keys = KeyMask();
    const float wf = ((keys & 1) ? 1.f : 0.f) - ((keys & 2) ? 1.f : 0.f);
    const float wr = ((keys & 8) ? 1.f : 0.f) - ((keys & 4) ? 1.f : 0.f);
    if (keys != g_m.keysPrev) {
        if (g_m.keysPrev == 0 && keys != 0 && speed < 0.3f) {
            StartProbe(kStart, now, p, vx, vz, keys, 0.f);
        } else if (g_m.keysPrev != 0 && keys == 0 && speed > 0.5f) {
            StartProbe(kStop, now, p, vx, vz, keys, 0.f);
        } else if (g_m.keysPrev != 0 && keys != 0 && speed > 0.5f && (wf != 0.f || wr != 0.f)) {
            const float ang = AngleDeg(g_m.wishPrevR, g_m.wishPrevF, wr, wf);
            if (ang > 150.f) StartProbe(kReverse, now, p, vx, vz, keys, ang);
            else if (ang >= 30.f) StartProbe(kStrafe, now, p, vx, vz, keys, ang);
        }
        g_m.keysPrev = keys;
        if (wf != 0.f || wr != 0.f) { g_m.wishPrevF = wf; g_m.wishPrevR = wr; }
    }
    RunProbes(now, p, vx, vz, speed, keys);

    if (now - g_m.lastSummary >= 60.0) {
        g_m.lastSummary = now;
        Summary("every 60 s");
    }
}

int Status(char* out, size_t cap)
{
    return std::snprintf(out, cap, "mf=%s mfv=%.2f mftarget=%.2f mfcorr=%d mfupd=%ld mfchk=%ld/%ld/%ld/%ld", g_why,
                         g_vOut.load(), g_target.load(), g_m.corrections, g_updates.load(),
                         g_checkN[kInputOff].load(), g_checkN[kYawMoved].load(), g_checkN[kLocoMid].load(), g_checkN[kPathOff].load());
}

}  // namespace dag::movefeel
