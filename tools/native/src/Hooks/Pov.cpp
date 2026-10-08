// SPDX-License-Identifier: GPL-3.0-or-later
//
// Full first-person POV. See Pov.h for the design.
//
// Camera object layout used here is NCT's (reference/BG3_NativeCameraTweaks
// src/RE/Camera.h, static_asserted there against cameraModeFlags @ 0xA8):
//   0x18 cameraRootPos (vec3)       0x24 desiredCameraRootPos (vec3)
//   0x3C unkCameraRootPosA (vec3)   0x48 unkCameraRootPosB (vec3)
//   0x54 currentZoomA               0x58 currentZoomB
//   0x70 cameraRotation (unit vec3, points pivot -> eye)
//   0xC4 cameraPos (vec3)
// The commit is vt[0x58](self, slot, &eye, cam + 0x48) with
// eye = cam[0x48] + cam[0x54] * cam[0x70]. We verify the rotation offset
// at runtime (0x70 vs 0x74) from that identity before trusting it.

#include "Pov.h"

#include <windows.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "../Log.h"
#include "../SafeMem.h"

namespace dag::pov {

namespace {

// ---------------------------------------------------------------------
// Small helpers (POD only, so SEH is legal inside them).
// ---------------------------------------------------------------------
bool SafeWrite(void* addr, const void* src, size_t n)
{
    if (!addr) return false;
    __try {
        std::memcpy(addr, src, n);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

inline bool Finite3(const float v[3])
{
    for (int i = 0; i < 3; ++i) {
        if (!std::isfinite(v[i]) || std::fabs(v[i]) > 1.0e6f) return false;
    }
    return true;
}

inline float Len3(const float v[3]) { return std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]); }

bool ReadVec(const void* base, uint32_t off, float out[3])
{
    if (!dag::safemem::ReadFloat3(base, off, out)) return false;
    return Finite3(out);
}

void OutputPath(wchar_t* out, size_t cap, const wchar_t* file)
{
    wchar_t buf[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) { out[0] = 0; return; }
    swprintf_s(out, cap, L"%s\\Larian Studios\\Baldur's Gate 3\\Script Extender\\DarkAndGate\\%s",
               buf, file);
}

bool ReadSmallFile(const wchar_t* file, char* out, size_t cap, FILETIME* mtime)
{
    wchar_t path[MAX_PATH * 2];
    OutputPath(path, MAX_PATH * 2, file);
    if (!path[0]) return false;
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    if (mtime) GetFileTime(h, nullptr, nullptr, mtime);
    DWORD got = 0;
    BOOL ok = ReadFile(h, out, static_cast<DWORD>(cap - 1), &got, nullptr);
    CloseHandle(h);
    if (!ok) return false;
    out[got] = 0;
    return true;
}

void WriteSmallFile(const wchar_t* file, const char* data, int len)
{
    wchar_t path[MAX_PATH * 2];
    OutputPath(path, MAX_PATH * 2, file);
    if (!path[0] || len <= 0) return;
    HANDLE h = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    WriteFile(h, data, static_cast<DWORD>(len), &written, nullptr);
    CloseHandle(h);
}

// Finds `key=` in a space-separated line and returns a pointer to the value.
const char* FindVal(const char* line, const char* key)
{
    const size_t kl = std::strlen(key);
    const char* p = line;
    while ((p = std::strstr(p, key)) != nullptr) {
        const bool startOk = (p == line) || p[-1] == ' ' || p[-1] == '\n' || p[-1] == '\t';
        if (startOk && p[kl] == '=') return p + kl + 1;
        p += kl;
    }
    return nullptr;
}

float ValF(const char* line, const char* key, float def)
{
    const char* v = FindVal(line, key);
    return v ? static_cast<float>(std::atof(v)) : def;
}

int ValI(const char* line, const char* key, int def)
{
    const char* v = FindVal(line, key);
    return v ? std::atoi(v) : def;
}

// ---------------------------------------------------------------------
// Lua -> DLL state (native-pov.txt)
// ---------------------------------------------------------------------
constexpr int kMaxMeshes = 16;

struct LuaState {
    bool  on        = false;
    bool  active    = false;
    float eyeUp     = 0.06f;   // metres above the head bone
    float eyeFwd    = 0.08f;   // metres forward of it (camera yaw)
    float look      = 1.0f;    // distance of the look-at point
    float eyeHeight = 1.65f;   // for the mesh-transform fallback
    float pivotUp   = -0.15f;  // for the engine-pivot fallback
    int   dump      = 0;       // bumped by Lua to request a pose dump
    int   sockBone  = -1;      // head socket bone index (Lua)
    int   skelBones = 0;       // skeleton bone count (Lua)
    float root[3]   = { 0, 0, 0 };
    int   numMeshes = 0;
    uintptr_t meshes[kMaxMeshes] = {};
    DWORD readTick  = 0;
};

LuaState g_lua;
DWORD    g_lastPollMs = 0;
FILETIME g_lastMtime  = {};
int      g_lastDump   = 0;

void PollLuaFile()
{
    const DWORD now = GetTickCount();
    if (now - g_lastPollMs < 100) return;
    g_lastPollMs = now;

    char buf[2048];
    FILETIME mt = {};
    if (!ReadSmallFile(L"native-pov.txt", buf, sizeof(buf), &mt)) {
        g_lua.on = false;
        return;
    }
    if (CompareFileTime(&mt, &g_lastMtime) == 0) {
        // Unchanged. If Lua stopped writing for > 2 s (game paused, Lua
        // error), drop out of POV rather than freeze the camera on stale data.
        if (now - g_lua.readTick > 2000) g_lua.active = false;
        return;
    }
    g_lastMtime = mt;

    LuaState s;
    s.on        = ValI(buf, "on", 0) != 0;
    s.active    = ValI(buf, "active", 0) != 0;
    s.eyeUp     = ValF(buf, "eye_up", s.eyeUp);
    s.eyeFwd    = ValF(buf, "eye_fwd", s.eyeFwd);
    s.look      = ValF(buf, "look", s.look);
    s.eyeHeight = ValF(buf, "eye_height", s.eyeHeight);
    s.pivotUp   = ValF(buf, "pivot_up", s.pivotUp);
    s.dump      = ValI(buf, "dump", 0);
    s.sockBone  = ValI(buf, "sock", -1);
    s.skelBones = ValI(buf, "skel", 0);
    s.root[0]   = ValF(buf, "rootx", 0);
    s.root[1]   = ValF(buf, "rooty", 0);
    s.root[2]   = ValF(buf, "rootz", 0);
    if (s.look < 0.2f) s.look = 0.2f;

    if (const char* m = FindVal(buf, "meshes")) {
        while (*m && *m != ' ' && *m != '\n' && *m != '\r' && s.numMeshes < kMaxMeshes) {
            char* end = nullptr;
            const unsigned long long v = std::strtoull(m, &end, 16);
            if (end == m) break;
            if (v) s.meshes[s.numMeshes++] = static_cast<uintptr_t>(v);
            m = end;
            if (*m == ',') ++m;
        }
    }
    s.readTick = now;
    g_lua = s;
}

// ---------------------------------------------------------------------
// Pose reading
//
// MeshBinding (bg3se GameDefinitions/Render.h):
//   +0x00 VMT, +0x08 field_8,
//   +0x10 Pose { mat3x4* Pose1 (+0x10); mat3x4* Pose2 (+0x18); u16 BoneCount (+0x20) }
//   +0x28 MoveableObject* Object, +0x30 glm::mat4 Transform (column-major)
// The per-bone matrices are 12 floats. We don't know their layout or space
// for sure, so selection tries 2 layouts x 2 spaces and keeps the combo
// whose bones cluster around the character.
// ---------------------------------------------------------------------
constexpr int kMaxBones = 512;

struct Selection {
    bool      valid    = false;
    uintptr_t mesh     = 0;
    int       meshIdx  = -1;
    int       poseSlot = 0;     // 0 = Pose1, 1 = Pose2
    int       layout   = 0;     // 0: t=(m3,m7,m11)  1: t=(m9,m10,m11)
    int       space    = 0;     // 0: world  1: model (mul by mesh Transform)
    int       bone     = -1;
    int       count    = 0;
    float     frac     = 0;
    bool      fromSocket = false;
};

Selection g_sel;
DWORD     g_lastSelectMs = 0;
int       g_badFrames = 0;

bool ReadMeshTransform(uintptr_t mesh, float m[16])
{
    if (!dag::safemem::ReadBytes(reinterpret_cast<void*>(mesh + 0x30), m, sizeof(float) * 16)) return false;
    for (int i = 0; i < 16; ++i) if (!std::isfinite(m[i])) return false;
    return std::fabs(m[15] - 1.0f) < 1e-3f && std::fabs(m[3]) < 1e-3f && std::fabs(m[7]) < 1e-3f;
}

bool ReadPoseHeader(uintptr_t mesh, int slot, uintptr_t& poseArr, int& count)
{
    void* p = nullptr;
    if (!dag::safemem::ReadPtr(reinterpret_cast<void*>(mesh), slot == 0 ? 0x10 : 0x18, p)) return false;
    uint16_t c = 0;
    if (!dag::safemem::ReadBytes(reinterpret_cast<void*>(mesh + 0x20), &c, sizeof(c))) return false;
    if (!p || c == 0 || c > kMaxBones) return false;
    poseArr = reinterpret_cast<uintptr_t>(p);
    count = c;
    return true;
}

// Bone translation in world space for a given combo. `mt` is the mesh
// transform (only used when space == 1).
bool BoneWorld(uintptr_t poseArr, int bone, int layout, int space, const float mt[16], float out[3])
{
    float m[12];
    if (!dag::safemem::ReadBytes(reinterpret_cast<void*>(poseArr + static_cast<uintptr_t>(bone) * 48), m, sizeof(m)))
        return false;
    float t[3];
    if (layout == 0) { t[0] = m[3]; t[1] = m[7];  t[2] = m[11]; }
    else             { t[0] = m[9]; t[1] = m[10]; t[2] = m[11]; }
    if (!Finite3(t)) return false;
    if (space == 0) {
        out[0] = t[0]; out[1] = t[1]; out[2] = t[2];
    } else {
        out[0] = mt[0] * t[0] + mt[4] * t[1] + mt[8]  * t[2] + mt[12];
        out[1] = mt[1] * t[0] + mt[5] * t[1] + mt[9]  * t[2] + mt[13];
        out[2] = mt[2] * t[0] + mt[6] * t[1] + mt[10] * t[2] + mt[14];
    }
    return Finite3(out);
}

// Is `p` a plausible head position for a character standing at `root`?
bool PlausibleHead(const float p[3], const float root[3])
{
    const float dy = p[1] - root[1];
    const float dx = p[0] - root[0], dz = p[2] - root[2];
    return dy > 0.5f && dy < 3.2f && std::sqrt(dx * dx + dz * dz) < 0.9f;
}

void Select(bool dumpToLog)
{
    g_lastSelectMs = GetTickCount();
    Selection best;
    const float* root = g_lua.root;

    if (dumpToLog) {
        dag::log::Writef("POV dump: %d meshes, sock=%d skel=%d root=(%.2f,%.2f,%.2f)",
                         g_lua.numMeshes, g_lua.sockBone, g_lua.skelBones, root[0], root[1], root[2]);
    }

    for (int mi = 0; mi < g_lua.numMeshes; ++mi) {
        const uintptr_t mesh = g_lua.meshes[mi];
        float mt[16] = {};
        const bool mtOk = ReadMeshTransform(mesh, mt);
        if (dumpToLog) {
            dag::log::Writef("POV dump: mesh[%d]=%p transformOk=%d T=(%.2f,%.2f,%.2f)",
                             mi, reinterpret_cast<void*>(mesh), mtOk ? 1 : 0, mt[12], mt[13], mt[14]);
        }
        for (int slot = 0; slot < 2; ++slot) {
            uintptr_t arr = 0; int count = 0;
            if (!ReadPoseHeader(mesh, slot, arr, count)) {
                if (dumpToLog) dag::log::Writef("POV dump:   pose%d unreadable", slot + 1);
                continue;
            }
            for (int layout = 0; layout < 2; ++layout) {
                for (int space = 0; space < 2; ++space) {
                    if (space == 1 && !mtOk) continue;
                    int nearCount = 0, readCount = 0;
                    int topBone = -1; float topY = -1e9f;
                    for (int b = 0; b < count; ++b) {
                        float w[3];
                        if (!BoneWorld(arr, b, layout, space, mt, w)) continue;
                        ++readCount;
                        const float dx = w[0] - root[0], dy = w[1] - root[1], dz = w[2] - root[2];
                        if (std::sqrt(dx * dx + dy * dy + dz * dz) < 3.5f) ++nearCount;
                        if (std::sqrt(dx * dx + dz * dz) < 0.45f && w[1] > topY) { topY = w[1]; topBone = b; }
                    }
                    const float frac = readCount ? static_cast<float>(nearCount) / static_cast<float>(count) : 0.f;
                    if (dumpToLog) {
                        dag::log::Writef("POV dump:   pose%d layout%d %s n=%d near=%.2f top=%d (y-root=%.2f)",
                                         slot + 1, layout, space ? "model" : "world", count, frac,
                                         topBone, topBone >= 0 ? topY - root[1] : 0.f);
                    }
                    if (frac < 0.8f || topBone < 0) continue;
                    // Prefer more bones (the full body skeleton), then a higher fraction.
                    const bool better = !best.valid || count > best.count ||
                                        (count == best.count && frac > best.frac + 0.01f);
                    if (better) {
                        best.valid = true; best.mesh = mesh; best.meshIdx = mi;
                        best.poseSlot = slot; best.layout = layout; best.space = space;
                        best.bone = topBone; best.count = count; best.frac = frac;
                        best.fromSocket = false;
                    }
                }
            }
        }
    }

    // Prefer the head socket's bone when it maps onto the chosen pose.
    if (best.valid && g_lua.sockBone >= 0 && g_lua.sockBone < best.count &&
        (g_lua.skelBones == 0 || g_lua.skelBones == best.count)) {
        uintptr_t arr = 0; int count = 0;
        float mt[16] = {}; ReadMeshTransform(best.mesh, mt);
        float w[3];
        if (ReadPoseHeader(best.mesh, best.poseSlot, arr, count) &&
            BoneWorld(arr, g_lua.sockBone, best.layout, best.space, mt, w) && PlausibleHead(w, root)) {
            best.bone = g_lua.sockBone;
            best.fromSocket = true;
        }
    }

    if (dumpToLog && best.valid) {
        // Full bone list for the winner, so we can pick a better bone by hand.
        uintptr_t arr = 0; int count = 0;
        float mt[16] = {}; ReadMeshTransform(best.mesh, mt);
        if (ReadPoseHeader(best.mesh, best.poseSlot, arr, count)) {
            for (int b = 0; b < count; ++b) {
                float w[3];
                if (BoneWorld(arr, b, best.layout, best.space, mt, w)) {
                    dag::log::Writef("POV dump:     bone[%d] rel=(%.2f,%.2f,%.2f)", b,
                                     w[0] - root[0], w[1] - root[1], w[2] - root[2]);
                }
            }
        }
    }

    g_sel = best;
    g_badFrames = 0;
    dag::log::Writef("POV select: %s mesh[%d]=%p pose%d layout%d %s bone=%d%s n=%d near=%.2f",
                     best.valid ? "OK" : "NONE", best.meshIdx, reinterpret_cast<void*>(best.mesh),
                     best.poseSlot + 1, best.layout, best.space ? "model" : "world", best.bone,
                     best.fromSocket ? "(socket)" : "(top)", best.count, best.frac);
}

bool HeadWorld(float out[3])
{
    if (!g_sel.valid) return false;
    // The mesh list from Lua must still contain our mesh (character swap,
    // equipment change, reload all invalidate it).
    bool present = false;
    for (int i = 0; i < g_lua.numMeshes; ++i) if (g_lua.meshes[i] == g_sel.mesh) present = true;
    if (!present) { g_sel.valid = false; return false; }

    uintptr_t arr = 0; int count = 0;
    if (!ReadPoseHeader(g_sel.mesh, g_sel.poseSlot, arr, count) || g_sel.bone >= count) return false;
    float mt[16] = {};
    if (g_sel.space == 1 && !ReadMeshTransform(g_sel.mesh, mt)) return false;
    return BoneWorld(arr, g_sel.bone, g_sel.layout, g_sel.space, mt, out);
}

// ---------------------------------------------------------------------
// MMB toggle via SDL event filter
// ---------------------------------------------------------------------
using SDL_EventFilterFn   = int(__cdecl*)(void*, void*);
using SDL_GetEventFilterF = int(__cdecl*)(SDL_EventFilterFn*, void**);
using SDL_SetEventFilterF = void(__cdecl*)(SDL_EventFilterFn, void*);
using SDL_PushEventF      = int(__cdecl*)(void*);
using SDL_GetMouseStateF  = uint32_t(__cdecl*)(int*, int*);
using SDL_GetMouseFocusF  = void*(__cdecl*)();
using SDL_GetWindowIDF    = uint32_t(__cdecl*)(void*);
using SDL_GetTicksF       = uint32_t(__cdecl*)();

SDL_EventFilterFn   g_prevFilter   = nullptr;
void*               g_prevUserdata = nullptr;
SDL_PushEventF      g_push         = nullptr;
SDL_GetMouseStateF  g_mouseState   = nullptr;
SDL_GetMouseFocusF  g_mouseFocus   = nullptr;
SDL_GetWindowIDF    g_windowId     = nullptr;
SDL_GetTicksF       g_ticks        = nullptr;
bool                g_filterInstalled = false;
DWORD               g_lastFilterTry   = 0;

constexpr uint32_t kMouseDown = 0x401;
constexpr uint32_t kMouseUp   = 0x402;
constexpr uint8_t  kMiddle    = 2;

std::atomic<bool> g_mlWanted { false };   // POV on + gameplay active
std::atomic<bool> g_toggled  { false };   // we are holding Camera Rotate
std::atomic<int>  g_synthDown{ 0 };
std::atomic<int>  g_synthUp  { 0 };

int __cdecl OurFilter(void* userdata, void* ev)
{
    (void)userdata;
    uint32_t type = 0;
    std::memcpy(&type, ev, 4);
    if (type == kMouseDown || type == kMouseUp) {
        uint8_t* e = static_cast<uint8_t*>(ev);
        if (e[16] == kMiddle) {
            if (type == kMouseDown) {
                if (g_synthDown.load() > 0) { g_synthDown.fetch_sub(1); }
                else if (g_mlWanted.load()) {
                    if (!g_toggled.load()) {
                        g_toggled.store(true);           // start rotating, keep it held
                    } else {
                        g_toggled.store(false);          // second press: release
                        type = kMouseUp;
                        std::memcpy(ev, &type, 4);
                        e[17] = 0;                       // SDL_RELEASED
                    }
                }
            } else {
                if (g_synthUp.load() > 0) { g_synthUp.fetch_sub(1); }
                else if (g_mlWanted.load()) {
                    return 0;                            // swallow the real release
                }
            }
        }
    }
    if (g_prevFilter) return g_prevFilter(g_prevUserdata, ev);
    return 1;
}

void TryInstallFilter()
{
    if (g_filterInstalled) return;
    const DWORD now = GetTickCount();
    if (now - g_lastFilterTry < 2000) return;
    g_lastFilterTry = now;

    HMODULE sdl = GetModuleHandleW(L"SDL2.dll");
    if (!sdl) return;
    auto getF  = reinterpret_cast<SDL_GetEventFilterF>(GetProcAddress(sdl, "SDL_GetEventFilter"));
    auto setF  = reinterpret_cast<SDL_SetEventFilterF>(GetProcAddress(sdl, "SDL_SetEventFilter"));
    g_push       = reinterpret_cast<SDL_PushEventF>(GetProcAddress(sdl, "SDL_PushEvent"));
    g_mouseState = reinterpret_cast<SDL_GetMouseStateF>(GetProcAddress(sdl, "SDL_GetMouseState"));
    g_mouseFocus = reinterpret_cast<SDL_GetMouseFocusF>(GetProcAddress(sdl, "SDL_GetMouseFocus"));
    g_windowId   = reinterpret_cast<SDL_GetWindowIDF>(GetProcAddress(sdl, "SDL_GetWindowID"));
    g_ticks      = reinterpret_cast<SDL_GetTicksF>(GetProcAddress(sdl, "SDL_GetTicks"));
    if (!getF || !setF || !g_push) {
        dag::log::Writef("POV: SDL2 exports missing (get=%p set=%p push=%p)", getF, setF, g_push);
        g_filterInstalled = true;  // don't retry forever
        return;
    }
    SDL_EventFilterFn prev = nullptr; void* prevUd = nullptr;
    if (getF(&prev, &prevUd) && prev != &OurFilter) {
        g_prevFilter = prev; g_prevUserdata = prevUd;
    }
    setF(&OurFilter, nullptr);
    g_filterInstalled = true;
    dag::log::Writef("POV: SDL event filter installed (chained prev=%p)", reinterpret_cast<void*>(g_prevFilter));
}

void PushMiddle(bool down)
{
    if (!g_push) return;
    uint8_t ev[56] = {};
    const uint32_t type = down ? kMouseDown : kMouseUp;
    std::memcpy(ev + 0, &type, 4);
    const uint32_t ts = g_ticks ? g_ticks() : 0;
    std::memcpy(ev + 4, &ts, 4);
    uint32_t wid = 0;
    if (g_mouseFocus && g_windowId) { void* w = g_mouseFocus(); if (w) wid = g_windowId(w); }
    std::memcpy(ev + 8, &wid, 4);
    ev[16] = kMiddle;
    ev[17] = down ? 1 : 0;
    ev[18] = 1;
    int x = 0, y = 0;
    if (g_mouseState) g_mouseState(&x, &y);
    std::memcpy(ev + 20, &x, 4);
    std::memcpy(ev + 24, &y, 4);
    if (down) g_synthDown.fetch_add(1); else g_synthUp.fetch_add(1);
    if (g_push(ev) < 1) {
        if (down) g_synthDown.fetch_sub(1); else g_synthUp.fetch_sub(1);
    }
}

void UpdateMouselookState()
{
    const bool want = g_lua.on && g_lua.active;
    const bool was  = g_mlWanted.load();
    if (want == was) return;
    g_mlWanted.store(want);
    if (want) {
        // Entering POV: start rotating straight away (mouse-look on).
        if (!g_toggled.load()) { g_toggled.store(true); PushMiddle(true); }
    } else {
        // Leaving POV, or a dialog/cutscene started: let go of Rotate.
        if (g_toggled.load()) { g_toggled.store(false); PushMiddle(false); }
    }
    dag::log::Writef("POV: mouselook %s", want ? "ON (MMB toggles)" : "OFF");
}

// ---------------------------------------------------------------------
// Rotation-offset calibration and status
// ---------------------------------------------------------------------
void*    g_gameplayCam = nullptr;
uint32_t g_rotOff      = 0x70;
int      g_rotVotes70  = 0;
int      g_rotVotes74  = 0;
bool     g_rotLogged   = false;

struct Status {
    const char* src = "none";
    float eye[3]  = {};
    float P[3]    = {};
    float head[3] = {};
    float rot[3]  = {};
    bool  applied = false;
} g_status;
DWORD g_lastStatusMs = 0;
bool  g_lastOn = false;

void CalibrateRot(uint8_t* cam, const float* engineEye)
{
    if (g_rotLogged) return;
    float pivot[3], r70[3], r74[3], zoom = 0;
    if (!ReadVec(cam, 0x48, pivot) || !ReadVec(cam, 0x70, r70) || !ReadVec(cam, 0x74, r74)) return;
    if (!dag::safemem::ReadFloat(cam, 0x54, zoom) || !std::isfinite(zoom) || zoom < 0.5f) return;
    auto err = [&](const float r[3]) {
        const float d0 = pivot[0] + zoom * r[0] - engineEye[0];
        const float d1 = pivot[1] + zoom * r[1] - engineEye[1];
        const float d2 = pivot[2] + zoom * r[2] - engineEye[2];
        return std::sqrt(d0 * d0 + d1 * d1 + d2 * d2);
    };
    const float e70 = err(r70), e74 = err(r74);
    if (e70 < 0.05f) ++g_rotVotes70;
    if (e74 < 0.05f) ++g_rotVotes74;
    if (g_rotVotes70 + g_rotVotes74 >= 30) {
        g_rotOff = (g_rotVotes74 > g_rotVotes70) ? 0x74 : 0x70;
        g_rotLogged = true;
        dag::log::Writef("POV: rotation offset calibrated -> 0x%X (votes 0x70=%d 0x74=%d, last err %.3f / %.3f)",
                         g_rotOff, g_rotVotes70, g_rotVotes74, e70, e74);
    }
}

void WriteStatus()
{
    const DWORD now = GetTickCount();
    if (now - g_lastStatusMs < 500) return;
    g_lastStatusMs = now;
    char line[768];
    const int len = std::snprintf(line, sizeof(line),
        "on=%d active=%d applied=%d src=%s rotOff=0x%X rotCal=%d sel=%d bone=%d%s mesh=%d pose%d layout%d %s "
        "eye=%.3f,%.3f,%.3f P=%.3f,%.3f,%.3f head=%.3f,%.3f,%.3f rot=%.3f,%.3f,%.3f "
        "root=%.3f,%.3f,%.3f mouselook=%d toggled=%d filter=%d meshes=%d t=%u\n",
        g_lua.on ? 1 : 0, g_lua.active ? 1 : 0, g_status.applied ? 1 : 0, g_status.src,
        g_rotOff, g_rotLogged ? 1 : 0, g_sel.valid ? 1 : 0, g_sel.bone,
        g_sel.fromSocket ? "(socket)" : "(top)", g_sel.meshIdx, g_sel.poseSlot + 1, g_sel.layout,
        g_sel.space ? "model" : "world",
        g_status.eye[0], g_status.eye[1], g_status.eye[2],
        g_status.P[0], g_status.P[1], g_status.P[2],
        g_status.head[0], g_status.head[1], g_status.head[2],
        g_status.rot[0], g_status.rot[1], g_status.rot[2],
        g_lua.root[0], g_lua.root[1], g_lua.root[2],
        g_mlWanted.load() ? 1 : 0, g_toggled.load() ? 1 : 0, g_filterInstalled ? 1 : 0,
        g_lua.numMeshes, (unsigned)now);
    WriteSmallFile(L"native-pov-status.txt", line, len);
}

}  // namespace

// ---------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------
void OnFrame(void* gameplayCam)
{
    g_gameplayCam = gameplayCam;
    PollLuaFile();
    TryInstallFilter();
    UpdateMouselookState();

    if (g_lua.on != g_lastOn) {
        g_lastOn = g_lua.on;
        dag::log::Writef("POV: %s", g_lua.on ? "ON" : "OFF");
        if (g_lua.on) g_sel.valid = false;  // fresh selection on every enable
    }

    if (g_lua.on && g_lua.numMeshes > 0) {
        const DWORD now = GetTickCount();
        const bool dumpReq = (g_lua.dump != g_lastDump);
        if (dumpReq) g_lastDump = g_lua.dump;
        if (dumpReq || (!g_sel.valid && now - g_lastSelectMs > 1000)) {
            Select(dumpReq);
        }
    }
    if (!g_lua.on) g_status.applied = false;
    WriteStatus();
}

bool HandleCommit(void* self, void* slotToken, float* newPos, float* outPos, CommitFn original)
{
    if (!original || !newPos || !outPos) return false;
    uint8_t* cam = reinterpret_cast<uint8_t*>(outPos) - 0x48;
    if (!g_gameplayCam || cam != g_gameplayCam) return false;

    // Learn the rotation offset from the engine's own eye while it is
    // still the engine's (POV off, zoomed out).
    if (!g_lua.on || !g_lua.active) {
        float engineEye[3];
        if (ReadVec(newPos, 0, engineEye)) CalibrateRot(cam, engineEye);
        g_status.applied = false;
        return false;
    }

    float rot[3];
    if (!ReadVec(cam, g_rotOff, rot)) return false;
    const float rl = Len3(rot);
    if (rl < 0.5f || rl > 1.5f) return false;
    rot[0] /= rl; rot[1] /= rl; rot[2] /= rl;

    // Horizontal forward (the way the camera looks, flattened).
    float fx = -rot[0], fz = -rot[2];
    const float fh = std::sqrt(fx * fx + fz * fz);
    if (fh > 1e-4f) { fx /= fh; fz /= fh; } else { fx = 0; fz = 0; }

    float eye[3];
    float head[3] = {};
    const char* src = "pivot";
    bool have = false;

    float pivot[3];
    const bool pivotOk = ReadVec(cam, 0x24, pivot);

    if (HeadWorld(head)) {
        // Sanity: must be near the engine's own idea of where the character is.
        const bool sane = !pivotOk ||
            (std::fabs(head[0] - pivot[0]) < 2.0f && std::fabs(head[2] - pivot[2]) < 2.0f &&
             std::fabs(head[1] - pivot[1]) < 2.5f);
        if (sane) {
            eye[0] = head[0] + fx * g_lua.eyeFwd;
            eye[1] = head[1] + g_lua.eyeUp;
            eye[2] = head[2] + fz * g_lua.eyeFwd;
            src = "bone"; have = true; g_badFrames = 0;
        } else if (++g_badFrames > 30) {
            g_sel.valid = false;  // reselect next second
        }
    }
    if (!have && g_sel.mesh) {
        float mt[16];
        if (ReadMeshTransform(g_sel.mesh, mt)) {
            const float base[3] = { mt[12], mt[13], mt[14] };
            if (!pivotOk || (std::fabs(base[0] - pivot[0]) < 2.0f && std::fabs(base[2] - pivot[2]) < 2.0f)) {
                eye[0] = base[0] + fx * g_lua.eyeFwd;
                eye[1] = base[1] + g_lua.eyeHeight;
                eye[2] = base[2] + fz * g_lua.eyeFwd;
                src = "mesh"; have = true;
            }
        }
    }
    if (!have) {
        if (!pivotOk) return false;
        eye[0] = pivot[0] + fx * g_lua.eyeFwd;
        eye[1] = pivot[1] + g_lua.pivotUp;
        eye[2] = pivot[2] + fz * g_lua.eyeFwd;
        src = "pivot";
    }

    // Look-at point: in front of the eye along the engine's view direction.
    const float P[3] = {
        eye[0] - rot[0] * g_lua.look,
        eye[1] - rot[1] * g_lua.look,
        eye[2] - rot[2] * g_lua.look,
    };

    // Every field the commit might build its view from gets the same
    // point, then is restored afterwards (only if still ours).
    static const uint32_t kFields[] = { 0x18, 0x24, 0x3C, 0x48, 0xC4 };
    constexpr int kN = static_cast<int>(sizeof(kFields) / sizeof(kFields[0]));
    float saved[kN][3];
    bool  savedOk[kN];
    for (int i = 0; i < kN; ++i) {
        savedOk[i] = dag::safemem::ReadBytes(cam + kFields[i], saved[i], sizeof(float) * 3);
        if (savedOk[i]) SafeWrite(cam + kFields[i], P, sizeof(float) * 3);
    }

    float eyeBuf[3] = { eye[0], eye[1], eye[2] };
    original(self, slotToken, eyeBuf, outPos);

    for (int i = 0; i < kN; ++i) {
        if (!savedOk[i]) continue;
        float now[3];
        if (dag::safemem::ReadBytes(cam + kFields[i], now, sizeof(now)) &&
            std::memcmp(now, P, sizeof(now)) == 0) {
            SafeWrite(cam + kFields[i], saved[i], sizeof(float) * 3);
        }
    }

    g_status.applied = true;
    g_status.src = src;
    std::memcpy(g_status.eye, eye, sizeof(eye));
    std::memcpy(g_status.P, P, sizeof(P));
    std::memcpy(g_status.head, head, sizeof(head));
    std::memcpy(g_status.rot, rot, sizeof(rot));
    return true;
}

}  // namespace dag::pov
