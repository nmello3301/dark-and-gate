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
#include "../Watchdog.h"
#include "VisualLift.h"
#include "Mouselook.h"
#include "AnimRate.h"
#include "GenomeCapture.h"
#include "MoveSpeed.h"
#include "MoveFeel.h"
#include "RealJump.h"
#include "CombatWasd.h"

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
    float downFwd   = 0.20f;   // extra forward shift when looking straight down
    int   dump      = 0;       // bumped by Lua to request a pose dump
    int   anchor    = 1;       // 1 = head bone (pivot until calibrated), 0 = engine pivot only
    int   jumpSeq   = 0;       // Lua bumps it on every jump (Jump.lua)
    float jumpMs    = 0;       // jump duration
    float jumpH     = 0;       // apex lift, metres
    float jumpK     = 2;       // apex flatness (2 = parabola)
    int   sockBone  = -1;      // head socket bone index (Lua)
    int   skelBones = 0;       // skeleton bone count (Lua)
    float root[3]   = { 0, 0, 0 };
    int   numMeshes = 0;
    uintptr_t meshes[kMaxMeshes] = {};
    uintptr_t visual = 0;      // player's root rf Visual (body lift)
    uintptr_t animInst = 0;    // GenomeBlueprintInstance to play at animRate (AnimRate.cpp)
    float     animRate = 1.f;
    uintptr_t recInst  = 0;    // instance to record animations of (AnimRate.cpp)
    uintptr_t clipInst = 0;    // per-clip rates target (AnimRate SetClipRates)
    char      clipRates[400] = "";
    // Per-clip rates on other characters (AnimRate SetNpcClipRates, bows):
    // "INST:ID:RATE|..." or empty.
    char      npcClips[1024] = "";
    // Clear the camera's combat mode flag while first person commits
    // (Lua nocombatcam; BG3's combat camera follows casters, BG3WASD gives
    // WASD to the camera in combat).
    bool      noCombatCam = true;
    // Skip BG3's "no WASD while in a combat" check (CombatWasd.cpp) while
    // first person is on (Lua combat_wasd; our fights are real time).
    bool      combatWasd = true;
    float     smooth   = 0.f;  // head-bone smoothing 0..0.9 (0 = raw pose)
    float     moveWalk = 1.f;  // WASD speed multipliers (MoveSpeed.cpp)
    float     moveRun  = 1.f;
    bool      liftObjects = true;  // lift the meshes' render objects too (VisualLift)
    int       genomeCapture = 0;   // 1 = log spell genome events (GenomeCapture.cpp)
    int       jumpMode = 0;        // 0 visual lift, 1 real (RealJump.cpp)
    float     strafeSign = 1.f;
    float     landSpeed = 3.f;
    float     wallH = 1.3f;
    bool      syncGuard = true;   // RealJump: skip the server-flag reset during a jump
    float     jumpWaitMs = 250.f; // bunny-hop grace: a jump that comes while still in the air waits this long for the landing
    bool      landHold = false;   // RealJump: keep BG3's landing hold (recover) after a jump
    float     slopeDeg = 50.f;    // RealJump: steepest uphill the curve's floor follows (0 = off)
    bool      menu = false;        // a BG3 panel is open (Lua, Client/HUD): mouse-look off, cursor free
    // Foreign camera (see Foreign below; data/camera.lua foreign_camera):
    // follow 1 = the view keeps following your mouse, 0 = it holds the last
    // direction (the 2026-10-12 behaviour); BG3's camera turning counts as
    // yours only within foreignMouseMs of a mouse movement (0 = always);
    // back on you, ease foreignEaseMs onto BG3's camera (0 = snap).
    bool      foreignFollow = true;
    float     foreignMouseMs = 300.f;
    float     foreignEaseMs = 150.f;
    // Mouse-look sensitivity (MCM slider / data/camera.lua look_sensitivity):
    // mouse motion is scaled by this while we hold Camera Rotate (OurFilter).
    float     lookSens = 1.f;
    // Crouch = sneaking (Client/Crouch.lua): the head bone lowers by itself;
    // the eye-height calibration must not run while crouched.
    bool      crouch = false;
    // Bumped by Lua on a level load / fast travel / teleport (FullPov.lua):
    // forget the head selection and the WASD character pointer.
    int       levelSeq = 0;
    // Downed orbit camera (Client/Downed.lua): third person around a target.
    bool      orbit = false;
    int       orbitSeq = 0;        // bumped on enter / target change: re-seed yaw + pitch
    float     orbitDist = 3.5f;    // metres from the target
    float     orbitUp = 0.6f;      // target point above the body's root
    float     orbitPMin = -10.f;   // pitch clamp, degrees (+ = camera above)
    float     orbitPMax = 70.f;
    int       orbitSpin = 0;       // -1 / 0 / +1 while A/D or LMB/RMB are held
    int       orbitTilt = 0;       // -1 / 0 / +1 while S/W are held
    float     orbitRate = 120.f;   // deg/s for spin
    float     orbitTiltRate = 60.f;
    uintptr_t orbitVis = 0;        // the watched character's root Visual (0 = use orbitPos)
    float     orbitPos[3] = { 0, 0, 0 };   // Lua's position of that character
    // Direct WASD movement (MoveFeel.cpp, Client/Movement/Movement.lua):
    // move_mode 1 = direct, 0 = vanilla (BG3WASD); accel / decel seconds;
    // move_turn 0 engine (BG3's steering, the default), -1 instant, > 0 deg/s; move_raw 1 = physical
    // keys; move_hold 1 = input released (menus, dialogue, map, downed).
    int       moveMode = 0;
    float     moveAccel = 0.06f;
    float     moveDecel = 0.04f;
    float     moveTurn = 0.f;
    bool      moveRaw = false;
    bool      moveHold = false;
    bool      moveMetrics = false;
    float     moveFaceIdle = 30.f;  // standing still: the body turns to the camera past this (0 = never)
    bool      moveFaceAir = true;   // in the air: the body turns with the camera
    bool      mpRemote = false;     // multiplayer: other players connected (Client/MP.lua roster)
    // Locomotion Start / End / turn clips fast-forwarded in direct mode
    // (AnimRate SetLocoSkip): the player's instance, ids, rate.
    uintptr_t locoInst = 0;
    char      locoSkip[2048] = "";
    float     locoRate = 1.f;
    DWORD readTick  = 0;
};

LuaState g_lua;
// g_lua.lookSens for the SDL event filter (OurFilter), which may run on another thread.
constexpr float kLookSensMin = 0.1f;
constexpr float kLookSensMax = 5.0f;
std::atomic<float> g_lookSens{ 1.f };
DWORD    g_lastPollMs = 0;
FILETIME g_lastMtime  = {};
int      g_lastDump   = 0;

// Checked every frame, but only the mtime (GetFileAttributesEx, no open)
// unless the file changed, so a jump written by Lua starts within a frame.
bool LuaFileMtime(FILETIME* mt)
{
    wchar_t path[MAX_PATH * 2];
    OutputPath(path, MAX_PATH * 2, L"native-pov.txt");
    WIN32_FILE_ATTRIBUTE_DATA fad;
    if (!path[0] || !GetFileAttributesExW(path, GetFileExInfoStandard, &fad)) return false;
    *mt = fad.ftLastWriteTime;
    return true;
}

void PollLuaFile()
{
    const DWORD now = GetTickCount();
    FILETIME mt = {};
    if (!LuaFileMtime(&mt)) {
        if (now - g_lastPollMs > 100) { g_lastPollMs = now; g_lua.on = false; }
        return;
    }
    if (CompareFileTime(&mt, &g_lastMtime) == 0) {
        // Unchanged. If Lua stopped writing for > 2 s (game paused, Lua
        // error), drop out of POV rather than freeze the camera on stale data.
        if (now - g_lua.readTick > 2000) g_lua.active = false;
        return;
    }
    g_lastPollMs = now;

    static char buf[8192];
    if (!ReadSmallFile(L"native-pov.txt", buf, sizeof(buf), &mt)) return;
    // Lua writes the line in one go and ends it with " t=<ms>"; a read that
    // caught a half-written file is retried next frame (mtime not taken).
    if (!std::strstr(buf, " t=")) return;
    g_lastMtime = mt;

    LuaState s;
    s.on        = ValI(buf, "on", 0) != 0;
    s.active    = ValI(buf, "active", 0) != 0;
    s.eyeUp     = ValF(buf, "eye_up", s.eyeUp);
    s.eyeFwd    = ValF(buf, "eye_fwd", s.eyeFwd);
    s.look      = ValF(buf, "look", s.look);
    s.eyeHeight = ValF(buf, "eye_height", s.eyeHeight);
    s.pivotUp   = ValF(buf, "pivot_up", s.pivotUp);
    s.downFwd   = ValF(buf, "down_fwd", s.downFwd);
    s.dump      = ValI(buf, "dump", 0);
    s.anchor    = ValI(buf, "anchor", 1);
    s.jumpSeq   = ValI(buf, "jump_seq", g_lua.jumpSeq);
    s.jumpMs    = ValF(buf, "jump_ms", 0);
    s.jumpH     = ValF(buf, "jump_h", 0);
    s.jumpK     = ValF(buf, "jump_k", 2);
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
    if (const char* v = FindVal(buf, "anim_inst")) {
        s.animInst = static_cast<uintptr_t>(std::strtoull(v, nullptr, 16));
    }
    s.animRate = ValF(buf, "anim_rate", 1.f);
    if (const char* v = FindVal(buf, "clip_inst")) s.clipInst = static_cast<uintptr_t>(std::strtoull(v, nullptr, 16));
    if (const char* v = FindVal(buf, "clip_rates")) {
        size_t n = 0;
        while (v[n] && v[n] != ' ' && v[n] != '\n' && v[n] != '\r' && n + 1 < sizeof(s.clipRates)) { s.clipRates[n] = v[n]; ++n; }
        s.clipRates[n] = 0;
        if (std::strcmp(s.clipRates, "-") == 0) s.clipRates[0] = 0;
    }
    if (const char* v = FindVal(buf, "nclips")) {
        size_t n = 0;
        while (v[n] && v[n] != ' ' && v[n] != '\n' && v[n] != '\r' && n + 1 < sizeof(s.npcClips)) { s.npcClips[n] = v[n]; ++n; }
        s.npcClips[n] = 0;
        if (std::strcmp(s.npcClips, "-") == 0) s.npcClips[0] = 0;
    }
    if (const char* v = FindVal(buf, "rec_inst")) {
        s.recInst = static_cast<uintptr_t>(std::strtoull(v, nullptr, 16));
    }
    s.smooth   = ValF(buf, "head_smooth", 0.f);
    if (s.smooth < 0.f) s.smooth = 0.f;
    if (s.smooth > 0.9f) s.smooth = 0.9f;
    s.moveWalk = ValF(buf, "move_walk", 1.f);
    s.moveRun  = ValF(buf, "move_run", 1.f);
    s.liftObjects = ValI(buf, "lift_objects", 1) != 0;
    s.jumpMode = ValI(buf, "jump_mode", 0);
    s.genomeCapture = ValI(buf, "genome_capture", 0);
    s.strafeSign = ValF(buf, "strafe_sign", 1.f);
    s.landSpeed = ValF(buf, "rj_land_speed", 3.f);
    s.wallH = ValF(buf, "rj_wall_h", 1.3f);
    s.syncGuard = ValI(buf, "rj_sync_guard", 1) != 0;
    s.jumpWaitMs = ValF(buf, "jump_wait_ms", 250.f);
    s.landHold = ValI(buf, "rj_land_hold", 0) != 0;
    s.slopeDeg = ValF(buf, "rj_slope_deg", 50.f);
    // Multiplayer log tag ("u65537-host"), once the server has said who we are.
    if (const char* v = FindVal(buf, "mp_tag")) {
        char tag[48];
        size_t n = 0;
        while (v[n] && v[n] != ' ' && v[n] != '\n' && v[n] != '\r' && n + 1 < sizeof(tag)) { tag[n] = v[n]; ++n; }
        tag[n] = 0;
        dag::log::SetTag(std::strcmp(tag, "-") == 0 ? "" : tag);
    }
    s.menu = ValI(buf, "menu", 0) != 0;
    s.foreignFollow = ValI(buf, "foreign_follow", 1) != 0;
    s.foreignMouseMs = ValF(buf, "foreign_mouse_ms", 300.f);
    if (s.foreignMouseMs < 0.f) s.foreignMouseMs = 0.f;
    if (s.foreignMouseMs > 5000.f) s.foreignMouseMs = 5000.f;
    s.foreignEaseMs = ValF(buf, "foreign_ease_ms", 150.f);
    if (s.foreignEaseMs < 0.f) s.foreignEaseMs = 0.f;
    if (s.foreignEaseMs > 2000.f) s.foreignEaseMs = 2000.f;
    s.lookSens = ValF(buf, "look_sens", 1.f);
    if (!(s.lookSens >= kLookSensMin)) s.lookSens = kLookSensMin;   // also NaN
    if (s.lookSens > kLookSensMax) s.lookSens = kLookSensMax;
    g_lookSens.store(s.lookSens);
    s.crouch = ValI(buf, "crouch", 0) != 0;
    s.noCombatCam = ValI(buf, "nocombatcam", 1) != 0;
    s.combatWasd = ValI(buf, "combat_wasd", 1) != 0;
    s.levelSeq = ValI(buf, "level_seq", g_lua.levelSeq);
    s.orbit = ValI(buf, "orbit", 0) != 0;
    s.orbitSeq = ValI(buf, "orbit_seq", 0);
    s.orbitDist = ValF(buf, "orbit_dist", 3.5f);
    if (s.orbitDist < 1.0f) s.orbitDist = 1.0f;
    if (s.orbitDist > 12.f) s.orbitDist = 12.f;
    s.orbitUp = ValF(buf, "orbit_up", 0.6f);
    s.orbitPMin = ValF(buf, "orbit_pmin", -10.f);
    s.orbitPMax = ValF(buf, "orbit_pmax", 70.f);
    s.orbitSpin = ValI(buf, "orbit_spin", 0);
    s.orbitTilt = ValI(buf, "orbit_tilt", 0);
    s.orbitRate = ValF(buf, "orbit_rate", 120.f);
    s.orbitTiltRate = ValF(buf, "orbit_tilt_rate", 60.f);
    if (const char* v = FindVal(buf, "orbit_vis")) s.orbitVis = static_cast<uintptr_t>(std::strtoull(v, nullptr, 16));
    s.orbitPos[0] = ValF(buf, "orbit_x", 0);
    s.orbitPos[1] = ValF(buf, "orbit_y", 0);
    s.orbitPos[2] = ValF(buf, "orbit_z", 0);
    if (const char* v = FindVal(buf, "visual")) {
        s.visual = static_cast<uintptr_t>(std::strtoull(v, nullptr, 16));
    }
    s.moveMode = ValI(buf, "move_mode", 0);
    s.moveAccel = ValF(buf, "move_accel", 0.06f);
    s.moveDecel = ValF(buf, "move_decel", 0.04f);
    s.moveTurn = ValF(buf, "move_turn", 0.f);
    s.moveFaceIdle = ValF(buf, "move_face_idle", 30.f);
    s.moveFaceAir = ValI(buf, "move_face_air", 1) != 0;
    s.mpRemote = ValI(buf, "mp_remote", 0) != 0;
    s.moveRaw = ValI(buf, "move_raw", 0) != 0;
    s.moveHold = ValI(buf, "move_hold", 0) != 0;
    s.moveMetrics = ValI(buf, "move_metrics", 0) != 0;
    if (const char* v = FindVal(buf, "loco_inst")) s.locoInst = static_cast<uintptr_t>(std::strtoull(v, nullptr, 16));
    s.locoRate = ValF(buf, "loco_rate", 1.f);
    if (const char* v = FindVal(buf, "loco_skip")) {
        size_t n = 0;
        while (v[n] && v[n] != ' ' && v[n] != '\n' && v[n] != '\r' && n + 1 < sizeof(s.locoSkip)) { s.locoSkip[n] = v[n]; ++n; }
        s.locoSkip[n] = 0;
        if (std::strcmp(s.locoSkip, "-") == 0) s.locoSkip[0] = 0;
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
            if (mi < 2) {
                void* obj = nullptr;
                (void)dag::safemem::ReadPtr(reinterpret_cast<void*>(mesh), 0x28, obj);
                float wt[10] = {};
                const bool okW = obj && dag::safemem::ReadBytes(static_cast<uint8_t*>(obj) + 8, wt, sizeof(wt));
                dag::log::Writef("POV dump:   object=%p ok=%d worldT: q=(%.3f %.3f %.3f %.3f) t=(%.3f %.3f %.3f) s=(%.3f %.3f %.3f)",
                                 obj, okW ? 1 : 0, wt[0], wt[1], wt[2], wt[3], wt[4], wt[5], wt[6], wt[7], wt[8], wt[9]);
            }
        }
        for (int slot = 0; slot < 2; ++slot) {
            uintptr_t arr = 0; int count = 0;
            if (!ReadPoseHeader(mesh, slot, arr, count)) {
                if (dumpToLog) dag::log::Writef("POV dump:   pose%d unreadable", slot + 1);
                continue;
            }
            if (dumpToLog && mi < 2) {
                for (int b = 0; b < count && b < 6; ++b) {
                    float m[12] = {};
                    const bool ok = dag::safemem::ReadBytes(
                        reinterpret_cast<void*>(arr + static_cast<uintptr_t>(b) * 48), m, sizeof(m));
                    dag::log::Writef("POV dump:   pose%d raw[%d] ok=%d %.3f %.3f %.3f %.3f | %.3f %.3f %.3f %.3f | %.3f %.3f %.3f %.3f",
                                     slot + 1, b, ok ? 1 : 0, m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7],
                                     m[8], m[9], m[10], m[11]);
                }
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

// ---------------------------------------------------------------------
// Head bone from the live Granny world pose (docs/spikes/m1b-head-bone.md)
//
// MeshBinding +0xD0 u8 flags (bit0 = remapped), +0xB8 / +0xC0 Skeleton*
// ("to" / "from"; the composite uses +0xC0 when remapped), +0xA0 / +0xA8
// int* binding -> skeleton bone index.
// Skeleton +0xD8 granny_skeleton*, +0xE0 granny_world_pose* (lazy).
// granny_skeleton (packed): +0x08 int BoneCount, +0x0C granny_bone*.
// granny_bone (packed, stride 0xA4): +0x00 char* Name, +0x50 InverseWorld4x4.
// granny_world_pose (packed): +0x00 int count, +0x04 float(*)[16] World4x4
// (row-vector 4x4: translation = floats 12..14). Pose[i] = IW(k) * W[k],
// so W[k] is the bone's model-space transform the skin uses this frame.
// ---------------------------------------------------------------------
// Jump lift state (curve and UpdateJump further down).
struct JumpLift {
    bool          seen = false;  // first seq read is a sync, not a jump
    int           seq = 0;
    bool          active = false;
    LARGE_INTEGER t0 = {};
    float         durMs = 0, h = 0, k = 2;
    float         lift = 0;      // this frame, metres
    bool          real = false;  // the real position carries it (RealJump)
    bool          waiting = false; // still in the air: retried until the landing (bunny-hop grace)
    LARGE_INTEGER waitT0 = {};
};
JumpLift g_jump;

// Per-jump record of where the visible lift came from (logged at JUMP end):
// frames with the bone anchor, frames where the camera had to add lift the
// body didn't carry ("fill"), and the worst body-vs-curve error.
struct JumpLiftStats {
    int   frames = 0, boneFrames = 0, fillFrames = 0, bodyFrames = 0;
    float maxMissing = 0, maxBodyErr = 0;
    float maxMeshRise = 0;      // how far the head's mesh really rose
    int   meshFrames = 0;       // frames the mesh rise could be read
    float takeoffPre = 0;       // biggest per-frame head step in the 250 ms before take-off
    float takeoffMax = 0;       // ... and in the first 300 ms of the jump
    double takeoffAt = 0;       // ms into the jump of that step
};
// The head mesh's render-object height above the pivot at rest (EMA while
// not jumping); during a jump, mesh rise = current offset - this.
bool  g_meshOffOk = false;
float g_meshOff = 0;
JumpLiftStats g_jls;

// The last frames' head steps (the CAM delta per frame, and when), so a jump
// can report the biggest step just before its take-off.
constexpr int kStepRing = 32;
float g_stepD[kStepRing] = {};
DWORD g_stepT[kStepRing] = {};
int   g_stepHead = 0;

// Camera steadiness: the eye's offset from the engine pivot (look-down
// slide and jump lift removed), per frame. delta = |change| per frame,
// jerk = |second difference| (raw pose jitter shows here, smooth motion
// doesn't). Logged every 3 s as "CAM delta ..." and on the status line.
struct CamStats {
    bool  have1 = false, have2 = false;
    float r1[3] = {}, r2[3] = {};
    float maxD = 0, maxJ = 0;
    double sumD = 0;
    int   n = 0;
    DWORD windowStart = 0;
    float lastAvg = 0, lastMax = 0, lastJerk = 0;
    bool  sHave = false;           // head smoothing state (head - pivot)
    float s[3] = {};
};
CamStats g_cam;

struct HeadSel {
    bool      valid = false;
    uintptr_t mb = 0;
    uintptr_t skel = 0;
    int       bone = -1;
    char      name[32] = {};
    int       xf = 0;              // model -> world source, see ModelToWorld
    // Vertical eye offset learned from the signed-off pivot eye at rest,
    // so switching to the bone anchor doesn't move the default eye height.
    bool      calibrated = false;
    int       calN = 0;
    double    calSum = 0;
    float     eyeUpAuto = 0;
    // Stale-pose guard: a live head never stays bit-identical for long.
    float     last[3] = {};
    int       sameFrames = 0;
};
HeadSel g_head;
DWORD   g_lastHeadResolveMs = 0;
int     g_headFailLogged = 0;

bool ReadU64Unaligned(uintptr_t addr, uintptr_t& out)
{
    return dag::safemem::ReadBytes(reinterpret_cast<void*>(addr), &out, sizeof(out));
}

bool ReadI32(uintptr_t addr, int& out)
{
    return dag::safemem::ReadBytes(reinterpret_cast<void*>(addr), &out, sizeof(out));
}

// Reads a C string 8 bytes at a time, falling back to single bytes, so a
// short string at the end of a page doesn't fail the whole read.
bool ReadCStr(uintptr_t p, char* out, size_t cap)
{
    size_t n = 0;
    while (n + 1 < cap) {
        char chunk[8];
        if (dag::safemem::ReadBytes(reinterpret_cast<void*>(p + n), chunk, sizeof(chunk))) {
            for (int i = 0; i < 8 && n + 1 < cap; ++i) {
                out[n++] = chunk[i];
                if (!chunk[i]) return true;
            }
        } else {
            if (!dag::safemem::ReadBytes(reinterpret_cast<void*>(p + n), chunk, 1)) break;
            out[n++] = chunk[0];
            if (!chunk[0]) return true;
        }
    }
    out[n < cap ? n : cap - 1] = 0;
    return n > 0;
}

bool SkelOf(uintptr_t mb, uintptr_t& skel, uintptr_t& idxArr)
{
    uint8_t flags = 0;
    if (!dag::safemem::ReadBytes(reinterpret_cast<void*>(mb + 0xD0), &flags, 1)) return false;
    void* sk = nullptr; void* ix = nullptr;
    if (!dag::safemem::ReadPtr(reinterpret_cast<void*>(mb), (flags & 1) ? 0xC0 : 0xB8, sk) || !sk) return false;
    (void)dag::safemem::ReadPtr(reinterpret_cast<void*>(mb), (flags & 1) ? 0xA8 : 0xA0, ix);
    skel = reinterpret_cast<uintptr_t>(sk);
    idxArr = reinterpret_cast<uintptr_t>(ix);
    return true;
}

bool GrannyBones(uintptr_t skel, uintptr_t& bones, int& n)
{
    void* g = nullptr;
    if (!dag::safemem::ReadPtr(reinterpret_cast<void*>(skel), 0xD8, g) || !g) return false;
    const uintptr_t gs = reinterpret_cast<uintptr_t>(g);
    if (!ReadI32(gs + 0x08, n) || n <= 0 || n > kMaxBones) return false;
    return ReadU64Unaligned(gs + 0x0C, bones) && bones != 0;
}

// Model-space 4x4 (row-vector) of skeleton bone k from the live world pose.
bool WorldPoseBone(uintptr_t skel, int k, float m[16])
{
    void* wp = nullptr;
    if (!dag::safemem::ReadPtr(reinterpret_cast<void*>(skel), 0xE0, wp) || !wp) return false;
    const uintptr_t w = reinterpret_cast<uintptr_t>(wp);
    int cnt = 0; uintptr_t arr = 0;
    if (!ReadI32(w, cnt) || k < 0 || k >= cnt || cnt > kMaxBones) return false;
    if (!ReadU64Unaligned(w + 4, arr) || !arr) return false;
    if (!dag::safemem::ReadBytes(reinterpret_cast<void*>(arr + static_cast<uintptr_t>(k) * 64), m, 64)) return false;
    for (int i = 0; i < 16; ++i) if (!std::isfinite(m[i])) return false;
    return true;
}

// Once per selection: does InverseWorld(k) * W[k] reproduce the skinning
// matrices in Pose1/Pose2? Logged only -- it proves the world pose is the
// live source the skin is built from.
void SelfCheck(uintptr_t mb, uintptr_t skel, uintptr_t idxArr, uintptr_t bones)
{
    float best = 1e9f; int bestSlot = -1, bestLayout = -1, tested = 0;
    for (int slot = 0; slot < 2; ++slot) {
        uintptr_t arr = 0; int count = 0;
        if (!idxArr || !ReadPoseHeader(mb, slot, arr, count)) continue;
        for (int layout = 0; layout < 2; ++layout) {
            float worst = 0; int n = 0;
            for (int i = 0; i < count && i < 8; ++i) {
                int k = -1;
                if (!ReadI32(idxArr + static_cast<uintptr_t>(i) * 4, k)) break;
                float IW[16], W[16], P[12];
                if (!dag::safemem::ReadBytes(reinterpret_cast<void*>(bones + static_cast<uintptr_t>(k) * 0xA4 + 0x50), IW, 64)) break;
                if (!WorldPoseBone(skel, k, W)) break;
                if (!dag::safemem::ReadBytes(reinterpret_cast<void*>(arr + static_cast<uintptr_t>(i) * 48), P, 48)) break;
                float C[16];
                for (int r = 0; r < 4; ++r)
                    for (int c = 0; c < 4; ++c) {
                        float v = 0;
                        for (int j = 0; j < 4; ++j) v += IW[r * 4 + j] * W[j * 4 + c];
                        C[r * 4 + c] = v;
                    }
                for (int e = 0; e < 12; ++e) {
                    // layout 0: transposed 3x4 (row r = column r of C); layout 1: first 3 rows of C.
                    const float cv = layout == 0 ? C[(e % 4) * 4 + (e / 4)] : C[e];
                    const float d = std::fabs(cv - P[e]);
                    if (d > worst) worst = d;
                }
                ++n;
            }
            if (n > 0) {
                ++tested;
                if (worst < best) { best = worst; bestSlot = slot; bestLayout = layout; }
            }
        }
    }
    dag::log::Writef("HEAD check: worldpose %s (max err %.5f, pose%d %s, %d combos)",
                     tested == 0 ? "UNTESTED" : (best < 1e-3f ? "LIVE" : "MISMATCH"),
                     tested ? best : 0.f, bestSlot + 1, bestLayout == 0 ? "transposed" : "direct", tested);
}

// ---------------------------------------------------------------------
// Model -> world for the head bone. The world pose is model space; the
// 2026-10-09 playtest showed MeshBinding+0x30 is NOT the world matrix (the
// head came out at (-0.03, 1.75, 0.01) while the character stood at
// (210, 21, 362)). Candidates, chosen once per selection by plausibility:
//   0 object  the mesh's render object world TRS (MeshBinding+0x28 ->
//             MoveableObject: +0x08 quat, +0x18 translate, +0x24 scale)
//   1 visual  the player's root Visual world TRS (same layout)
//   2 matrix  MeshBinding+0x30 (old path)
//   3 none    pose already in world space
// The render object and the Visual carry the body lift, so the head does too.
// ---------------------------------------------------------------------
const char* kXfNames[] = { "object", "visual", "matrix", "none" };

bool ApplyTrs(uintptr_t obj, const float p[3], float out[3])
{
    float tr[10];
    if (!obj || !dag::safemem::ReadBytes(reinterpret_cast<void*>(obj + 0x08), tr, sizeof(tr))) return false;
    for (int i = 0; i < 10; ++i) if (!std::isfinite(tr[i])) return false;
    float x = tr[0], y = tr[1], z = tr[2], w = tr[3];
    const float ql = std::sqrt(x * x + y * y + z * z + w * w);
    if (ql < 0.9f || ql > 1.1f) return false;
    // glm stores x,y,z,w. A character's rotation is (nearly) yaw-only, so
    // x and z are ~0; if instead slots 1 and 3 are ~0, the layout is w,x,y,z.
    if ((std::fabs(tr[0]) > 0.05f || std::fabs(tr[2]) > 0.05f) &&
        std::fabs(tr[1]) < 0.05f && std::fabs(tr[3]) < 0.05f) {
        w = tr[0]; x = tr[1]; y = tr[2]; z = tr[3];
    }
    const float* t = tr + 4;
    const float* sc = tr + 7;
    const float v[3] = { p[0] * sc[0], p[1] * sc[1], p[2] * sc[2] };
    // v' = v + w * c + q x c, with c = 2 * (q x v)
    const float cx = 2.f * (y * v[2] - z * v[1]);
    const float cy = 2.f * (z * v[0] - x * v[2]);
    const float cz = 2.f * (x * v[1] - y * v[0]);
    out[0] = v[0] + w * cx + (y * cz - z * cy) + t[0];
    out[1] = v[1] + w * cy + (z * cx - x * cz) + t[1];
    out[2] = v[2] + w * cz + (x * cy - y * cx) + t[2];
    return Finite3(out);
}

bool ModelToWorld(int xf, uintptr_t mb, const float p[3], float out[3])
{
    switch (xf) {
    case 0: {
        void* obj = nullptr;
        if (!dag::safemem::ReadPtr(reinterpret_cast<void*>(mb), 0x28, obj) || !obj) return false;
        return ApplyTrs(reinterpret_cast<uintptr_t>(obj), p, out);
    }
    case 1:
        return ApplyTrs(g_lua.visual, p, out);
    case 2: {
        float mt[16];
        if (!ReadMeshTransform(mb, mt)) return false;
        out[0] = mt[0] * p[0] + mt[4] * p[1] + mt[8]  * p[2] + mt[12];
        out[1] = mt[1] * p[0] + mt[5] * p[1] + mt[9]  * p[2] + mt[13];
        out[2] = mt[2] * p[0] + mt[6] * p[1] + mt[10] * p[2] + mt[14];
        return Finite3(out);
    }
    default:
        out[0] = p[0]; out[1] = p[1]; out[2] = p[2];
        return Finite3(out);
    }
}

// A head for a character whose feet are at g_lua.root (Lua's Transform).
// `lift` is the body lift currently applied to the visual, if any.
bool PlausibleHeadAt(const float h[3], float lift)
{
    const float dy = h[1] - g_lua.root[1] - lift;
    const float dx = h[0] - g_lua.root[0], dz = h[2] - g_lua.root[2];
    // 2026-10-12: floor 1.0 -> 0.4 m, so a crouched human, or a halfling /
    // gnome / dwarf standing or crouched, still gets the head-bone anchor.
    return dy > 0.4f && dy < 2.4f && std::sqrt(dx * dx + dz * dz) < 0.7f;
}

bool ResolveHead(bool dumpToLog)
{
    g_lastHeadResolveMs = GetTickCount();
    static const char* kWant[] = { "Head_M", "Head", "Neck_M" };
    for (int mi = 0; mi < g_lua.numMeshes; ++mi) {
        const uintptr_t mb = g_lua.meshes[mi];
        uintptr_t skel = 0, idxArr = 0, bones = 0; int n = 0;
        if (!SkelOf(mb, skel, idxArr) || !GrannyBones(skel, bones, n)) continue;
        int bestRank = 99, bestBone = -1; char bestName[32] = {};
        for (int k = 0; k < n; ++k) {
            uintptr_t np = 0; char nm[32];
            if (!ReadU64Unaligned(bones + static_cast<uintptr_t>(k) * 0xA4, np) || !np) continue;
            if (!ReadCStr(np, nm, sizeof(nm))) continue;
            if (dumpToLog && (std::strstr(nm, "ead") || std::strstr(nm, "eck")))
                dag::log::Writef("HEAD dump: mesh[%d] bone[%d] %s", mi, k, nm);
            for (int r = 0; r < 3; ++r) {
                if (r < bestRank && std::strcmp(nm, kWant[r]) == 0) {
                    bestRank = r; bestBone = k;
                    strncpy_s(bestName, nm, _TRUNCATE);
                }
            }
        }
        if (bestBone < 0) continue;
        float W[16];
        if (!WorldPoseBone(skel, bestBone, W)) continue;  // not animated yet

        // Model -> world: first candidate that puts the head above the feet.
        const float local[3] = { W[12], W[13], W[14] };
        const float liftNow = dag::visuallift::BodyLiftActive() ? g_jump.lift : 0.f;
        int xf = -1;
        char tried[256]; int tl = 0; tried[0] = 0;
        for (int c = 0; c < 4 && xf < 0; ++c) {
            float o[3];
            const bool ok = ModelToWorld(c, mb, local, o);
            if (tl < 200) {
                tl += std::snprintf(tried + tl, sizeof(tried) - tl, " %s=%s", kXfNames[c],
                                    ok ? "" : "fail");
                if (ok && tl < 200)
                    tl += std::snprintf(tried + tl, sizeof(tried) - tl, "(%.2f,%.2f,%.2f)",
                                        o[0] - g_lua.root[0], o[1] - g_lua.root[1], o[2] - g_lua.root[2]);
            }
            if (ok && PlausibleHeadAt(o, liftNow)) xf = c;
        }
        if (xf < 0) {
            if (g_headFailLogged++ < 3)
                dag::log::Writef("HEAD select: %s found but no model->world fits (rel to feet:%s)", bestName, tried);
            continue;
        }

        // Same mesh as before (re-resolve after a hiccup): keep the calibration.
        const bool keepCal = g_head.mb == mb && g_head.calibrated;
        const float keptUp = g_head.eyeUpAuto;
        g_head = HeadSel{};
        g_head.valid = true; g_head.mb = mb; g_head.skel = skel; g_head.bone = bestBone;
        g_head.xf = xf;
        std::memcpy(g_head.name, bestName, sizeof(g_head.name));
        if (keepCal) { g_head.calibrated = true; g_head.eyeUpAuto = keptUp; }
        g_headFailLogged = 0;
        dag::log::Writef("HEAD select: mesh[%d]=%p skel=%p bone[%d]=%s xf=%s bones=%d (rel to feet:%s)",
                         mi, reinterpret_cast<void*>(mb), reinterpret_cast<void*>(skel), bestBone,
                         bestName, kXfNames[xf], n, tried);
        SelfCheck(mb, skel, idxArr, bones);
        return true;
    }
    g_head.valid = false;
    if (g_headFailLogged++ < 3) {
        dag::log::Writef("HEAD select: no head bone in %d meshes (pivot anchor stays)", g_lua.numMeshes);
    }
    return false;
}

bool HeadBoneWorld(float out[3])
{
    if (!g_head.valid) return false;
    bool present = false;
    for (int i = 0; i < g_lua.numMeshes; ++i) if (g_lua.meshes[i] == g_head.mb) present = true;
    if (!present) { g_head.valid = false; return false; }

    float W[16];
    if (!WorldPoseBone(g_head.skel, g_head.bone, W)) return false;
    const float t[3] = { W[12], W[13], W[14] };
    if (!ModelToWorld(g_head.xf, g_head.mb, t, out)) return false;

    if (std::memcmp(out, g_head.last, sizeof(g_head.last)) == 0) {
        if (++g_head.sameFrames == 120) {
            dag::log::Writef("HEAD: pose frozen for 120 frames -- treating as stale, pivot anchor until it moves");
        }
    } else {
        g_head.sameFrames = 0;
        std::memcpy(g_head.last, out, sizeof(g_head.last));
    }
    return g_head.sameFrames < 120;
}

// ---------------------------------------------------------------------
// Jump lift (visual only). Lua bumps jump_seq (Jump.lua); the curve
// y = h * (1 - |2u - 1|^k) runs on QPC time from the frame we see it.
// ---------------------------------------------------------------------
double   g_qpcFreq = 0;

double MsSince(const LARGE_INTEGER& t0)
{
    if (g_qpcFreq == 0) {
        LARGE_INTEGER f; QueryPerformanceFrequency(&f);
        g_qpcFreq = static_cast<double>(f.QuadPart);
    }
    LARGE_INTEGER n; QueryPerformanceCounter(&n);
    return static_cast<double>(n.QuadPart - t0.QuadPart) * 1000.0 / g_qpcFreq;
}

void UpdateJump()
{
    if (g_lua.jumpSeq != g_jump.seq) {
        const bool start = g_jump.seen && g_lua.jumpSeq != 0 && g_lua.jumpMs > 1.0f && g_lua.on && g_lua.active;
        g_jump.seq = g_lua.jumpSeq;
        g_jump.seen = true;
        g_jump.waiting = false;
        if (start) {
            g_jump.active = true;
            QueryPerformanceCounter(&g_jump.t0);
            g_jump.durMs = g_lua.jumpMs;
            g_jump.h = g_lua.jumpH;
            g_jump.k = g_lua.jumpK < 1.0f ? 1.0f : g_lua.jumpK;
            { int a, b, c; dag::visuallift::TakeStats(a, b, c); dag::visuallift::TakeObjectStats(a, b, c); }  // reset per jump
            g_jls = JumpLiftStats{};
            {
                const DWORD nowT = GetTickCount();
                for (int i = 0; i < kStepRing; ++i)
                    if (g_stepT[i] && nowT - g_stepT[i] <= 250 && g_stepD[i] > g_jls.takeoffPre) g_jls.takeoffPre = g_stepD[i];
            }
            g_jump.real = false;
            if (g_lua.jumpMode == 1) {
                dag::realjump::SetStrafeSign(g_lua.strafeSign);
                dag::realjump::SetLandSpeed(g_lua.landSpeed);
                dag::realjump::SetWallHeight(g_lua.wallH);
                dag::realjump::SetSyncGuard(g_lua.syncGuard);
                dag::realjump::SetLandHold(g_lua.landHold);
                dag::realjump::SetSlopeFollow(g_lua.slopeDeg);
                g_jump.real = dag::realjump::Start(g_jump.durMs, g_jump.h, g_jump.k, nullptr, g_jump.seq);
                // Still in the air (the last fall hasn't landed): wait for
                // the landing within the bunny-hop grace, below. Never the
                // visual lift on the ground: that let BG3 walk you on under
                // a fake jump (playtest 7).
                if (!g_jump.real && dag::realjump::RefusedAirborne()) {
                    g_jump.active = false;
                    g_jump.waiting = true;
                    QueryPerformanceCounter(&g_jump.waitT0);
                }
            }
            if (g_jump.waiting)
                dag::log::Writef("JUMP seq=%d waits for the landing (still in the air; grace %.0f ms)", g_jump.seq, g_lua.jumpWaitMs);
            else
                dag::log::Writef("JUMP start seq=%d dur=%.0fms h=%.2f k=%.1f lift=%s",
                                 g_jump.seq, g_jump.durMs, g_jump.h, g_jump.k,
                                 g_jump.real ? "REAL position (RealJump)"
                                 : (dag::visuallift::BodyLiftActive() ? "body+camera" : "camera-only jump"));
        }
    }
    g_jump.lift = 0;
    if (g_jump.waiting) {
        const double waited = MsSince(g_jump.waitT0);
        if (!g_lua.on || !g_lua.active) {
            g_jump.waiting = false;
            dag::log::Writef("JUMP seq=%d dropped while waiting for the landing (first person off)", g_jump.seq);
        } else if (dag::realjump::Start(g_jump.durMs, g_jump.h, g_jump.k, nullptr, g_jump.seq)) {
            g_jump.waiting = false;
            g_jump.active = true;
            g_jump.real = true;
            QueryPerformanceCounter(&g_jump.t0);
            dag::log::Writef("JUMP start seq=%d after waiting %.0f ms for the landing dur=%.0fms h=%.2f k=%.1f lift=REAL position (RealJump)",
                             g_jump.seq, waited, g_jump.durMs, g_jump.h, g_jump.k);
        } else if (!dag::realjump::RefusedAirborne() || waited >= g_lua.jumpWaitMs) {
            g_jump.waiting = false;
            dag::log::Writef("JUMP seq=%d skipped: %s after %.0f ms (no double jump, no visual lift)", g_jump.seq,
                             dag::realjump::RefusedAirborne() ? "still in the air" : "the real jump failed", waited);
        }
    }
    if (!g_jump.active) return;
    const double ms = MsSince(g_jump.t0);
    if (ms >= g_jump.durMs || !g_lua.on || !g_lua.active) {
        g_jump.active = false;
        int hw = 0, rw = 0, ew = 0;
        dag::visuallift::TakeStats(hw, rw, ew);
        dag::log::Writef("JUMP end seq=%d after %.0fms body writes: hook=%d refresh=%d external=%d",
                         g_jump.seq, ms, hw, rw, ew);
        int ow = 0, oe = 0, on = 0;
        dag::visuallift::TakeObjectStats(ow, oe, on);
        dag::log::Writef("JUMP objects seq=%d render objects=%d lifted writes=%d engine rewrites=%d (lift_objects=%d)",
                         g_jump.seq, on, ow, oe, g_lua.liftObjects ? 1 : 0);
        const bool body = dag::visuallift::BodyLiftActive();
        const char* srcName = !body ? "camera-only"
            : (g_jls.fillFrames * 10 > g_jls.frames ? "body+camera-fill" : "body");
        dag::log::Writef("JUMP lift seq=%d liftSrc=%s anchor=%s frames=%d boneFrames=%d bodyFrames=%d "
                         "fillFrames=%d maxMissing=%.3fm maxBodyErr=%.3fm meshRise=%.3fm (of %.2f, %d frames) force=%d",
                         g_jump.seq, srcName, g_lua.anchor ? "head" : "pivot", g_jls.frames, g_jls.boneFrames,
                         g_jls.bodyFrames, g_jls.fillFrames, g_jls.maxMissing, g_jls.maxBodyErr,
                         g_jls.maxMeshRise, g_jump.h, g_jls.meshFrames, dag::visuallift::Forced() ? 1 : 0);
        dag::log::Writef("JUMP takeoff seq=%d head step max %.3fm in the 250 ms before, %.3fm in the first 300 ms "
                         "(at +%.0f ms); move %s (running is about 0.01-0.03)",
                         g_jump.seq, g_jls.takeoffPre, g_jls.takeoffMax, g_jls.takeoffAt, dag::movefeel::State());
        return;
    }
    const float u = static_cast<float>(ms / g_jump.durMs);
    g_jump.lift = g_jump.h * (1.0f - std::pow(std::fabs(2.0f * u - 1.0f), g_jump.k));
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

constexpr uint32_t kMouseMotion = 0x400;   // SDL_MOUSEMOTION: which @12, xrel @28, yrel @32
constexpr uint32_t kMouseDown = 0x401;
constexpr uint32_t kMouseUp   = 0x402;
constexpr uint8_t  kMiddle    = 2;
constexpr uint32_t kTouchMouseId = 0xFFFFFFFFu;   // SDL_TOUCH_MOUSEID: touch, not a mouse

std::atomic<bool> g_mlWanted { false };   // POV on + gameplay active
std::atomic<bool> g_toggled  { false };   // we are holding Camera Rotate
std::atomic<int>  g_synthDown{ 0 };
std::atomic<int>  g_synthUp  { 0 };
// GetTickCount() of the last real mouse motion event SDL queued (0 = none
// yet). Queued before BG3 reads it, so the frame BG3 turns its camera for a
// movement already sees it (the foreign-camera follow, HandleCommit).
std::atomic<DWORD> g_mouseMoveTick{ 0 };
// Camera Rotate watchdog (RotateWatchdog below): sideways mouse motion while
// we hold Rotate, against the gameplay camera's turn (HandleCommit).
std::atomic<int> g_motionX{ 0 };       // sum of |xrel| of real mouse motion events
std::atomic<int> g_turnMilliDeg{ 0 };  // the slot camera's turn, 1/1000 deg

int __cdecl OurFilter(void* userdata, void* ev)
{
    (void)userdata;
    uint32_t type = 0;
    std::memcpy(&type, ev, 4);
    if (type == kMouseMotion) {
        const uint8_t* m = static_cast<const uint8_t*>(ev);
        uint32_t which = 0; int32_t xrel = 0, yrel = 0;
        std::memcpy(&which, m + 12, 4);
        std::memcpy(&xrel, m + 28, 4);
        std::memcpy(&yrel, m + 32, 4);
        if (which != kTouchMouseId && (xrel != 0 || yrel != 0)) g_mouseMoveTick.store(GetTickCount());
        if (which != kTouchMouseId && xrel != 0) g_motionX.fetch_add(xrel < 0 ? -xrel : xrel);
        // Mouse-look sensitivity: only while we hold Camera Rotate, so the
        // cursor in menus moves as always. The fraction carries over, so slow
        // turns at a low setting still turn.
        const float sens = g_lookSens.load();
        if (which != kTouchMouseId && g_mlWanted.load() && g_toggled.load() && std::fabs(sens - 1.f) > 0.001f &&
            (xrel != 0 || yrel != 0)) {
            static float remX = 0.f, remY = 0.f;
            const float fx = xrel * sens + remX, fy = yrel * sens + remY;
            const int32_t nx = static_cast<int32_t>(std::lround(fx)), ny = static_cast<int32_t>(std::lround(fy));
            remX = fx - nx;
            remY = fy - ny;
            uint8_t* w = static_cast<uint8_t*>(ev);
            std::memcpy(w + 28, &nx, 4);
            std::memcpy(w + 32, &ny, 4);
        }
    }
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
    // A BG3 panel (inventory, party view, map...) frees the cursor; the
    // first-person camera itself stays (unlike dialogue, where active = 0).
    const bool want = g_lua.on && g_lua.active && !g_lua.menu;
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
    dag::log::Writef("POV: mouselook %s", want ? "ON (MMB toggles)" : (g_lua.on && g_lua.active && g_lua.menu ? "OFF (menu open)" : "OFF"));
}

// BG3 can let go of the Camera Rotate we hold by itself (playtest 2026-10-16:
// at a fight's start mouse-look stopped, and MMB took two presses: the first
// only "released" a hold BG3 had already dropped). While we hold it, the
// mouse moving sideways must turn the gameplay camera; lots of motion and no
// turn in one window means the hold is gone -> release and press it again.
// (Yaw never clamps, so sideways motion always turns a held camera.)
constexpr DWORD kStallWindowMs  = 400;    // judge this much time at once
constexpr int   kStallMotionPx  = 40;     // at least this much sideways motion...
constexpr int   kStallTurnMilli = 50;     // ...and the camera turned under 0.05 deg
constexpr DWORD kStallRetryMs   = 1000;   // at most one re-press a second
constexpr int   kStallLogs      = 20;     // re-presses logged per session

constexpr DWORD kSensLogMs      = 5000;   // sensitivity line: every 5 s of mouse-look...
constexpr int   kSensLogMinPx   = 200;    // ...with at least this much sideways motion
constexpr int   kSensLogs       = 40;

void RotateWatchdog()
{
    static DWORD t0 = 0, lastFix = 0, logT0 = 0;
    static int m0 = 0, r0 = 0, fixes = 0, logM0 = 0, logR0 = 0, sensLogs = 0;
    if (!g_mlWanted.load() || !g_toggled.load() || g_lua.orbit || !g_push) { t0 = 0; logT0 = 0; return; }
    const DWORD now = GetTickCount();
    const int m = g_motionX.load(), r = g_turnMilliDeg.load();
    // For the log: how far the camera turns per raw mouse count at the current
    // sensitivity (a second setting should scale it by the same factor).
    if (logT0 == 0) { logT0 = now; logM0 = m; logR0 = r; }
    else if (now - logT0 >= kSensLogMs) {
        const int dm = m - logM0, dr = r - logR0;
        if (dm >= kSensLogMinPx && sensLogs < kSensLogs) {
            ++sensLogs;
            dag::log::Writef("POV: mouse-look sensitivity x%.2f: the camera turned %.4f deg per mouse count (%d counts in %.1f s)",
                             g_lookSens.load(), dr / 1000.0 / dm, dm, (now - logT0) / 1000.0);
        }
        logT0 = now; logM0 = m; logR0 = r;
    }
    if (t0 == 0) { t0 = now; m0 = m; r0 = r; return; }
    if (now - t0 < kStallWindowMs) return;
    const int motion = m - m0, turn = r - r0;
    const DWORD span = now - t0;
    t0 = now; m0 = m; r0 = r;
    if (motion < kStallMotionPx || turn >= kStallTurnMilli || now - lastFix < kStallRetryMs) return;
    lastFix = now;
    ++fixes;
    PushMiddle(false);
    PushMiddle(true);
    if (fixes <= kStallLogs)
        dag::log::Writef("POV: BG3 let go of Camera Rotate (mouse moved %d px sideways in %lu ms, the camera turned %.3f deg) -> pressed it again (#%d)",
                         motion, static_cast<unsigned long>(span), turn / 1000.0, fixes);
}

// ---------------------------------------------------------------------
// Rotation-offset calibration and status
// ---------------------------------------------------------------------
void*    g_gameplayCam = nullptr;
uint32_t g_rotOff      = 0x70;

// BG3 sometimes renders through a camera whose pivot is not on the
// character: during your own projectile cast it swaps in a camera that
// rides the projectile (playtest 2026-10-12: pivot 75 m away on the clone's
// flight line, under the ground -> black screen, and the view turned with
// it). A camera whose pivot is more than kForeignM from the character (Lua's
// root) is "foreign": first person keeps the head (checked against the
// character, not that pivot) until the pivot comes back.
//
// The view direction meanwhile (playtest 2026-10-14, brains fight at the
// crashed nautiloid): BG3's gameplay camera kept dropping its follow target
// (cam+0x13C target count != 1, so cam+0xC4 "camera position" is zeroed,
// FUN_141e155e0) and stayed on a fixed point or on someone else for up to
// ~4 s. Holding the last direction froze mouse-look that long, then the
// view snapped to where BG3's camera had turned with the mouse. That camera
// still turns with your mouse (its yaw at +0xAC is turned by the rotate
// input whatever it follows, FUN_141e18270), so the view now follows the
// slot camera's frame-to-frame turn on the same camera object; a turn while
// the mouse has been still for foreignMouseMs is BG3's own and is ignored.
// Back on you, the view eases foreignEaseMs onto BG3's camera. Lua's
// foreign_follow 0 brings back the old hold.
void* g_mainScene = nullptr;   // the render view the gameplay camera commits to
constexpr float kForeignM = 4.0f;
constexpr float kForeignUpM = 12.0f;
constexpr float kPivotAboveFeet = 1.9f;   // the gameplay pivot's height over the feet (PhaseProbe)
constexpr uint32_t kCamTargetCount = 0x13C;   // u32: BG3 camera's follow-target count (FUN_141e155e0)
constexpr float kTurnEpsDeg = 0.001f;         // smaller turns are float noise
constexpr float kMaxTurnDegPerFrame = 60.f;   // more in one frame is a camera swap / copy, not a mouse
constexpr DWORD kSrcStaleMs = 250;            // a rotation sample older than this is no baseline
constexpr DWORD kForeignGapMs = 250;          // a hold interrupted longer (dialogue, load) ends without an ease
constexpr float kEaseMinDeg = 0.5f;           // closer than this: no ease needed
constexpr float kEaseMaxDeg = 150.f;          // farther: a lerp would pass near zero, snap instead
constexpr int   kForeignLogPeriods = 150;     // holds logged per session (start + end line each)
constexpr int   kForeignSwapLogs = 3;         // camera swaps logged per hold (the rest are counted)
struct Foreign {
    bool  on = false;
    void* cam = nullptr;
    float goodRot[3] = { 0.f, 0.f, 1.f };   // the direction first person shows (held / followed while foreign)
    bool  goodRotOk = false;
    int   frames = 0;          // frames on the current camera object
    int   logs = 0;            // holds logged so far
    // One hold: from the first frame on a foreign camera until one is on you again.
    bool  logged = false;      // this hold's lines are written
    bool  follow = true;       // follow mode when it started
    int   periodFrames = 0;
    int   swaps = 0;           // camera objects BG3 swapped in during it
    LARGE_INTEGER t0 = {};
    DWORD lastTick = 0;        // GetTickCount() of its latest frame
    float followDeg = 0.f;     // the view turned with your mouse
    float ignoredDeg = 0.f;    // BG3's camera turned with the mouse still (or in hold mode)
    // Rotation source: the gameplay slot camera's rotation at the last commit.
    void* srcCam = nullptr;
    float srcRot[3] = { 0.f, 0.f, 1.f };
    bool  srcOk = false;
    DWORD srcTick = 0;
    // Back on you: ease from the followed direction onto BG3's camera.
    bool  easing = false;
    float easeFrom[3] = { 0.f, 0.f, 1.f };
    LARGE_INTEGER easeT0 = {};
} g_foreign;
int      g_rotVotes70  = 0;
int      g_rotVotes74  = 0;
bool     g_rotLogged   = false;

// Unit rotation (pivot -> eye) of a camera object, at the calibrated offset.
bool ReadUnitRot(const void* cam, float out[3])
{
    if (!cam || !ReadVec(cam, g_rotOff, out)) return false;
    const float l = Len3(out);
    if (l < 0.5f || l > 1.5f) return false;
    out[0] /= l; out[1] /= l; out[2] /= l;
    return true;
}

// Angle between two unit vectors; atan2(|a x b|, a.b) stays exact for the
// hundredths of a degree a slow mouse turns per frame (acos would round them to 0).
float AngleDeg(const float a[3], const float b[3])
{
    const float cx = a[1] * b[2] - a[2] * b[1];
    const float cy = a[2] * b[0] - a[0] * b[2];
    const float cz = a[0] * b[1] - a[1] * b[0];
    const float d = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    return std::atan2(std::sqrt(cx * cx + cy * cy + cz * cz), d) * 57.29578f;
}

// Turns `held` by the yaw / pitch change from `from` to `to` (all unit
// rotations in the engine's convention: pivot -> eye, y up).
void ApplyTurn(float held[3], const float from[3], const float to[3])
{
    constexpr float kPi = 3.14159265f;
    constexpr float kPitchMax = 1.5533f;   // 89 deg: keep yaw defined
    auto pitchOf = [](const float r[3]) { return std::asin(r[1] > 1.f ? 1.f : (r[1] < -1.f ? -1.f : r[1])); };
    float dYaw = 0.f;
    // Straight up / down the yaw is undefined: take only the pitch change.
    if (std::fabs(from[1]) < 0.999f && std::fabs(to[1]) < 0.999f) {
        dYaw = std::atan2(to[0], to[2]) - std::atan2(from[0], from[2]);
        while (dYaw > kPi) dYaw -= 2.f * kPi;
        while (dYaw < -kPi) dYaw += 2.f * kPi;
    }
    const float dPitch = pitchOf(to) - pitchOf(from);
    const float yaw = std::atan2(held[0], held[2]) + dYaw;
    float pitch = pitchOf(held) + dPitch;
    if (pitch > kPitchMax) pitch = kPitchMax;
    if (pitch < -kPitchMax) pitch = -kPitchMax;
    const float cp = std::cos(pitch);
    held[0] = cp * std::sin(yaw);
    held[1] = std::sin(pitch);
    held[2] = cp * std::cos(yaw);
}

// Did the mouse move within the last `ms`? Two sources: the SDL motion
// events (this frame's, queued before BG3 turns its camera) and SDL's
// relative-mouse delta (Mouselook::Tick, last frame's). 0 = no gate.
bool MouseMovedWithin(float ms)
{
    if (ms <= 0.f) return true;
    const DWORD now = GetTickCount();
    const DWORD lim = static_cast<DWORD>(ms);
    const DWORD a = g_mouseMoveTick.load();
    const DWORD b = static_cast<DWORD>(dag::hooks::mouselook::LastMoveTick());
    return (a != 0 && now - a <= lim) || (b != 0 && now - b <= lim);
}

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
    float ms0, mr0, mt0, mso, mro; long mc;
    dag::movespeed::Read(ms0, mr0, mt0, mso, mro, mc);
    char mf[160];
    dag::movefeel::Status(mf, sizeof(mf));
    char line[1800];
    const int len = std::snprintf(line, sizeof(line),
        "on=%d active=%d applied=%d src=%s rotOff=0x%X rotCal=%d sel=%d bone=%d%s mesh=%d pose%d layout%d %s "
        "eye=%.3f,%.3f,%.3f P=%.3f,%.3f,%.3f head=%.3f,%.3f,%.3f rot=%.3f,%.3f,%.3f "
        "root=%.3f,%.3f,%.3f mouselook=%d toggled=%d filter=%d meshes=%d "
        "headName=%s headBone=%d headCal=%d eyeUpAuto=%.3f lift=%.3f liftMode=%s jumpSeq=%d animRate=%.2f rateHook=%s rateHits=%ld "
        "anchor=%s delta=%.4f deltaMax=%.4f jerk=%.4f smooth=%.2f "
        "move=%s walkX=%.2f runX=%.2f tmplStroll=%.2f tmplRun=%.2f walkT=%.3f outStroll=%.2f outRun=%.2f moveCalls=%ld "
        "orbit=%d crouch=%d levelSeq=%d cwasd=%s foreignCam=%d foreignFollow=%d %s locoHits=%ld t=%u\n",
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
        g_lua.numMeshes,
        g_head.valid ? g_head.name : "none", g_head.bone, g_head.calibrated ? 1 : 0, g_head.eyeUpAuto,
        g_jump.lift, dag::visuallift::Mode(), g_jump.seq, g_lua.animRate, dag::animrate::State(), dag::animrate::Hits(),
        g_lua.anchor ? "head" : "pivot", g_cam.lastAvg, g_cam.lastMax, g_cam.lastJerk, g_lua.smooth,
        dag::movespeed::State(), g_lua.moveWalk, g_lua.moveRun, ms0, mr0, mt0, mso, mro, mc,
        g_lua.orbit ? 1 : 0, g_lua.crouch ? 1 : 0, g_lua.levelSeq,
        dag::combatwasd::State(), g_foreign.on ? 1 : 0, g_lua.foreignFollow ? 1 : 0, mf, dag::animrate::LocoHits(),
        (unsigned)now);
    WriteSmallFile(L"native-pov-status.txt", line, len);
}

}  // namespace

// ---------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------
void OnFrame(void* gameplayCam)
{
    dag::watchdog::Frame();
    dag::watchdog::Stage("OnFrame");
    static int s_camSwaps = 0;
    if (gameplayCam && g_gameplayCam && gameplayCam != g_gameplayCam && s_camSwaps < 40) {
        ++s_camSwaps;
        dag::log::Writef("POV: BG3's gameplay camera object %p -> %p (%d)", g_gameplayCam, gameplayCam, s_camSwaps);
    }
    g_gameplayCam = gameplayCam;
    PollLuaFile();
    TryInstallFilter();
    UpdateMouselookState();
    RotateWatchdog();

    if (g_lua.on != g_lastOn) {
        g_lastOn = g_lua.on;
        dag::log::Writef("POV: %s", g_lua.on ? "ON" : "OFF");
        if (g_lua.on) { g_sel.valid = false; g_head = HeadSel{}; }  // fresh selection on every enable
    }
    // Level load / fast travel / teleport (FullPov.lua bumps level_seq): the
    // meshes, the head selection and the WASD character may all be new.
    static int s_levelSeq = -1;
    if (g_lua.levelSeq != s_levelSeq) {
        if (s_levelSeq != -1) {
            g_sel.valid = false; g_head = HeadSel{}; g_meshOffOk = false;
            dag::realjump::ForgetCharacter();
            dag::movefeel::ForgetCharacter();
            dag::log::Writef("POV: level_seq %d -> head selection and WASD character reset", g_lua.levelSeq);
        }
        s_levelSeq = g_lua.levelSeq;
    }
    static bool s_orbit = false;
    if (g_lua.orbit != s_orbit) {
        s_orbit = g_lua.orbit;
        dag::log::Writef("POV: orbit camera %s", s_orbit ? "ON (downed)" : "OFF (first person)");
    }
    static bool s_crouch = false;
    if (g_lua.crouch != s_crouch) {
        s_crouch = g_lua.crouch;
        dag::log::Writef("POV: crouch %s (eye calibration %s)", s_crouch ? "ON" : "OFF", s_crouch ? "paused" : "allowed");
    }
    // Foreign-camera settings (Lua foreign_*): logged at the first read and on change.
    static int s_ffollow = -1;
    static float s_fmouse = -1.f, s_fease = -1.f;
    if (g_lua.on && ((g_lua.foreignFollow ? 1 : 0) != s_ffollow || g_lua.foreignMouseMs != s_fmouse ||
                     g_lua.foreignEaseMs != s_fease)) {
        s_ffollow = g_lua.foreignFollow ? 1 : 0;
        s_fmouse = g_lua.foreignMouseMs;
        s_fease = g_lua.foreignEaseMs;
        if (g_lua.foreignFollow)
            dag::log::Writef("POV: foreign camera -> the view follows your mouse (BG3's own turns ignored once the mouse is still %.0f ms; back on you: ease %.0f ms)",
                             g_lua.foreignMouseMs, g_lua.foreignEaseMs);
        else
            dag::log::Writef("POV: foreign camera -> the view holds your last direction (foreign_follow 0; back on you: ease %.0f ms)",
                             g_lua.foreignEaseMs);
    }

    if (g_lua.on && g_lua.numMeshes > 0) {
        const DWORD now = GetTickCount();
        const bool dumpReq = (g_lua.dump != g_lastDump);
        if (dumpReq) g_lastDump = g_lua.dump;
        if (dumpReq) Select(true);  // legacy skinning-matrix dump (diagnostics only)
        if (dumpReq || (!g_head.valid && now - g_lastHeadResolveMs > 1000)) {
            ResolveHead(dumpReq);
        }
    }

    UpdateJump();
    // Orbiting (downed): no body lift on the visual.
    dag::visuallift::SetVisual((g_lua.on && g_lua.active && !g_lua.orbit) ? g_lua.visual : 0);
    // A real jump moves the character itself: no visual lift on top.
    dag::realjump::MeasureFrame();
    dag::visuallift::SetLift(g_jump.real ? 0.f : g_jump.lift);
    {
        // The meshes' render objects (MeshBinding+0x28) carry the drawn body.
        uintptr_t objs[kMaxMeshes]; int n = 0;
        if (g_lua.on && g_lua.active && !g_lua.orbit) {
            for (int i = 0; i < g_lua.numMeshes; ++i) {
                void* o = nullptr;
                if (dag::safemem::ReadPtr(reinterpret_cast<void*>(g_lua.meshes[i]), 0x28, o) && o)
                    objs[n++] = reinterpret_cast<uintptr_t>(o);
            }
        }
        dag::visuallift::SetObjects(objs, n, g_lua.liftObjects);
    }
    dag::visuallift::Refresh();
    dag::animrate::Set(g_lua.animInst, g_lua.animRate);
    dag::animrate::Record(g_lua.recInst);
    dag::genomecapture::SetCapture(g_lua.genomeCapture != 0);
    dag::animrate::SetClipRates(g_lua.clipInst, g_lua.clipRates);
    dag::animrate::SetNpcClipRates(g_lua.npcClips);
    dag::movespeed::Set(g_lua.moveWalk, g_lua.moveRun);
    {
        // Direct WASD movement: only while first person is live; otherwise
        // (and in vanilla mode) BG3WASD's movement exactly as before.
        dag::movefeel::Settings ms;
        ms.direct = g_lua.moveMode == 1;
        ms.accelS = g_lua.moveAccel;
        ms.decelS = g_lua.moveDecel;
        ms.turn = g_lua.moveTurn;
        ms.rawInput = g_lua.moveRaw;
        ms.strafeSign = g_lua.strafeSign;
        // BG3's own axes already go quiet wherever vanilla WASD does (chat,
        // dialogue, camera mode); move_hold is for anything beyond that.
        ms.hold = g_lua.moveHold;
        ms.metrics = g_lua.moveMetrics;
        ms.faceIdleDeg = g_lua.moveFaceIdle;
        ms.faceAir = g_lua.moveFaceAir;
        ms.mpRemote = g_lua.mpRemote;
        dag::movefeel::Configure(ms, g_lua.on && g_lua.active && !g_lua.orbit);
        dag::movefeel::Frame();
        // Body facing from the camera: in the air, and standing still past
        // move.face_idle_deg (DECISIONS 2026-10-13).
        dag::movefeel::Facing(dag::realjump::Active());
        const bool direct = std::strcmp(dag::movefeel::State(), "direct") == 0;
        // Not during a jump: its take-off and landing blend exactly as the
        // signed-off jump did (playtest 2: a twitch at every take-off).
        const bool skip = direct && !g_jump.active;
        dag::animrate::SetLocoSkip(skip ? g_lua.locoInst : 0, skip ? g_lua.locoSkip : "", g_lua.locoRate);
    }
    dag::combatwasd::SetEnabled(g_lua.on && g_lua.combatWasd);
    if (!g_lua.on) g_status.applied = false;
    dag::watchdog::Stage("WriteStatus");
    WriteStatus();
    dag::watchdog::Stage("game (outside our frame hook)");
}

namespace {

// The commit itself: every field the engine might build its view from gets
// the same look-at point P, the original commit runs with our eye, and the
// fields are restored afterwards (only if still ours).
// cameraModeFlags (u32 at +0xA8, the layout BG3WASD's Structs/Camera.hpp
// documents; cameraPos at +0xC4 matches ours): bit 0 = combat. In a
// real-time fight it makes BG3 swing the view to casters and BG3WASD hands
// WASD to the camera, so first person clears it on every commit.
void ClearCombatMode(uint8_t* cam)
{
    static bool logged = false;
    uint32_t flags = 0;
    if (!dag::safemem::ReadBytes(cam + 0xA8, &flags, sizeof(flags))) return;
    if (!(flags & 1u)) return;
    flags &= ~1u;
    SafeWrite(cam + 0xA8, &flags, sizeof(flags));
    if (!logged) {
        logged = true;
        dag::log::Writef("POV: camera combat mode cleared on %p (no combat camera; WASD stays character movement)", static_cast<void*>(cam));
    }
}

void CommitWith(void* self, void* slotToken, float* outPos, uint8_t* cam, CommitFn original,
                const float eye[3], const float P[3])
{
    if (g_lua.noCombatCam) ClearCombatMode(cam);
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
}

// ---------------------------------------------------------------------
// Downed orbit (Client/Downed.lua): third person around a target, the
// engine's own mouse rotation (Camera Rotate stays held) as yaw / pitch
// deltas plus Lua's spin / tilt keys, pitch clamped, fixed distance.
//   eye = T + dist * dir, look-at = T   (dir in the engine's rot
//   convention: pointing from the target to the eye)
// T = the watched character's Visual (read every frame, rejected if it is
// more than 3 m from Lua's position for it) + orbit_up, else Lua's position.
// ---------------------------------------------------------------------
struct Orbit {
    int   seq = -1;
    float yaw = 0, pitch = 0;          // degrees
    float lastYawE = 0, lastPitchE = 0;
    LARGE_INTEGER t = {};
    bool  logged = false;
} g_orbit;

float WrapDeg(float a) { while (a > 180.f) a -= 360.f; while (a < -180.f) a += 360.f; return a; }

bool OrbitCommit(void* self, void* slotToken, float* outPos, uint8_t* cam, CommitFn original, const float rot[3])
{
    constexpr float kDeg = 57.29578f;
    const float yawE = std::atan2(rot[0], rot[2]) * kDeg;
    const float pitchE = std::asin(rot[1] > 1.f ? 1.f : (rot[1] < -1.f ? -1.f : rot[1])) * kDeg;
    LARGE_INTEGER now; QueryPerformanceCounter(&now);
    if (g_orbit.seq != g_lua.orbitSeq) {
        g_orbit.seq = g_lua.orbitSeq;
        g_orbit.yaw = yawE;
        g_orbit.pitch = pitchE < g_lua.orbitPMin ? g_lua.orbitPMin : (pitchE > g_lua.orbitPMax ? g_lua.orbitPMax : pitchE);
        if (g_orbit.pitch < 15.f) g_orbit.pitch = 15.f;   // start a little above, looking down at the body
        g_orbit.lastYawE = yawE; g_orbit.lastPitchE = pitchE; g_orbit.t = now;
        g_orbit.logged = false;
        dag::log::Writef("ORBIT start seq=%d yaw=%.0f pitch=%.0f dist=%.2f up=%.2f vis=%p",
                         g_orbit.seq, g_orbit.yaw, g_orbit.pitch, g_lua.orbitDist, g_lua.orbitUp,
                         reinterpret_cast<void*>(g_lua.orbitVis));
    }
    double dt = MsSince(g_orbit.t) / 1000.0;
    g_orbit.t = now;
    if (dt < 0 || dt > 0.25) dt = 0;
    g_orbit.yaw = WrapDeg(g_orbit.yaw + WrapDeg(yawE - g_orbit.lastYawE) + g_lua.orbitSpin * g_lua.orbitRate * static_cast<float>(dt));
    g_orbit.pitch += (pitchE - g_orbit.lastPitchE) + g_lua.orbitTilt * g_lua.orbitTiltRate * static_cast<float>(dt);
    if (g_orbit.pitch < g_lua.orbitPMin) g_orbit.pitch = g_lua.orbitPMin;
    if (g_orbit.pitch > g_lua.orbitPMax) g_orbit.pitch = g_lua.orbitPMax;
    g_orbit.lastYawE = yawE; g_orbit.lastPitchE = pitchE;

    float T[3] = { g_lua.orbitPos[0], g_lua.orbitPos[1], g_lua.orbitPos[2] };
    const char* tsrc = "lua";
    if (g_lua.orbitVis) {
        float v[3];
        if (dag::safemem::ReadBytes(reinterpret_cast<void*>(g_lua.orbitVis + 0x18), v, sizeof(v)) && Finite3(v)) {
            const float dx = v[0] - T[0], dy = v[1] - T[1], dz = v[2] - T[2];
            if (dx * dx + dy * dy + dz * dz < 9.f) { T[0] = v[0]; T[1] = v[1]; T[2] = v[2]; tsrc = "visual"; }
        }
    }
    if (!Finite3(T)) return false;
    T[1] += g_lua.orbitUp;
    const float p = g_orbit.pitch / kDeg, y = g_orbit.yaw / kDeg;
    const float dir[3] = { std::cos(p) * std::sin(y), std::sin(p), std::cos(p) * std::cos(y) };
    const float eye[3] = { T[0] + g_lua.orbitDist * dir[0], T[1] + g_lua.orbitDist * dir[1], T[2] + g_lua.orbitDist * dir[2] };
    CommitWith(self, slotToken, outPos, cam, original, eye, T);
    if (!g_orbit.logged) {
        g_orbit.logged = true;
        dag::log::Writef("ORBIT first frame: target (%.2f,%.2f,%.2f) from %s, eye (%.2f,%.2f,%.2f)",
                         T[0], T[1], T[2], tsrc, eye[0], eye[1], eye[2]);
    }
    g_status.applied = true;
    g_status.src = "orbit";
    std::memcpy(g_status.eye, eye, sizeof(eye));
    std::memcpy(g_status.P, T, sizeof(T));
    std::memcpy(g_status.rot, rot, sizeof(float) * 3);
    return true;
}

}  // namespace

bool HandleCommit(void* self, void* slotToken, float* newPos, float* outPos, CommitFn original)
{
    if (!original || !newPos || !outPos) return false;
    uint8_t* cam = reinterpret_cast<uint8_t*>(outPos) - 0x48;
    // Another camera committed on the main view while first person runs:
    // BG3's attack / spell cameras in a fight (playtest 2026-10-12: Ray of
    // Frost zoomed to the target, Fireball went black) are not always the
    // gameplay camera slot. They get the first-person view too (as foreign).
    const bool slotCam = g_gameplayCam && cam == g_gameplayCam;
    if (!slotCam && (!g_lua.on || !g_lua.active || g_lua.orbit || !g_mainScene || self != g_mainScene)) return false;

    // Learn the rotation offset from the engine's own eye while it is
    // still the engine's (POV off, zoomed out).
    if (!g_lua.on || !g_lua.active) {
        float engineEye[3];
        if (ReadVec(newPos, 0, engineEye)) CalibrateRot(cam, engineEye);
        g_status.applied = false;
        return false;
    }

    float rot[3];
    bool badRot = !ReadVec(cam, g_rotOff, rot);
    const float rl = badRot ? 0.f : Len3(rot);
    if (rl < 0.5f || rl > 1.5f) badRot = true;
    if (!badRot) { rot[0] /= rl; rot[1] /= rl; rot[2] /= rl; }

    // Where mouse-look lives this frame: the gameplay slot camera's rotation
    // (BG3 turns it with the mouse whatever it looks at). Its turn since the
    // last commit on the same camera object drives the view while a foreign
    // camera holds it (Foreign above). A second commit in the same frame
    // sees no turn, so commits are never counted twice.
    float srcNow[3] = { 0.f, 0.f, 1.f };
    void* srcCam = nullptr;
    bool  srcNowOk = false;
    if (slotCam) {
        srcCam = cam;
        srcNowOk = !badRot;
        if (srcNowOk) std::memcpy(srcNow, rot, sizeof(srcNow));
    } else if (g_gameplayCam) {
        srcCam = g_gameplayCam;
        srcNowOk = ReadUnitRot(g_gameplayCam, srcNow);
    }
    const DWORD nowTick = GetTickCount();
    const bool srcTurnOk = srcNowOk && g_foreign.srcOk && srcCam == g_foreign.srcCam &&
                           nowTick - g_foreign.srcTick <= kSrcStaleMs;
    float srcPrev[3];
    std::memcpy(srcPrev, g_foreign.srcRot, sizeof(srcPrev));
    g_foreign.srcCam = srcCam;
    g_foreign.srcOk = srcNowOk;
    g_foreign.srcTick = nowTick;
    if (srcNowOk) std::memcpy(g_foreign.srcRot, srcNow, sizeof(srcNow));
    const float srcTurnDeg = srcTurnOk ? AngleDeg(srcPrev, srcNow) : 0.f;
    // RotateWatchdog: is the held Camera Rotate still turning this camera?
    if (srcTurnOk) g_turnMilliDeg.fetch_add(static_cast<int>((srcTurnDeg < 60.f ? srcTurnDeg : 60.f) * 1000.f));

    if (badRot) {
        if (!g_foreign.goodRotOk) return false;
        std::memcpy(rot, g_foreign.goodRot, sizeof(rot));
    }

    float pivot[3] = { 0.f, 0.f, 0.f };
    bool pivotOk = ReadVec(cam, 0x24, pivot);
    // The gameplay camera always has a camera position; BG3's attack and
    // projectile cameras had none (0,0,0) in the playtest log.
    float camPos[3] = { 1.f, 1.f, 1.f };
    const bool noPos = ReadVec(cam, 0xC4, camPos) && camPos[0] == 0.f && camPos[1] == 0.f && camPos[2] == 0.f;

    // Foreign camera (see Foreign above): its pivot is far from the character.
    const bool rootOk = Finite3(g_lua.root) && (g_lua.root[0] != 0.f || g_lua.root[2] != 0.f);
    bool foreign = false;
    float farM = 0.f;
    if (pivotOk && rootOk && !g_lua.orbit) {   // the downed orbit may watch someone else
        const float dx = pivot[0] - g_lua.root[0], dz = pivot[2] - g_lua.root[2];
        const float dy = pivot[1] - (g_lua.root[1] + kPivotAboveFeet);
        farM = std::sqrt(dx * dx + dz * dz);
        foreign = farM > kForeignM || std::fabs(dy) > kForeignUpM;   // tall test jumps stay ours
        if (foreign && farM < std::fabs(dy)) farM = std::fabs(dy);
    }
    if (!g_lua.orbit && (noPos || badRot)) foreign = true;
    if (slotCam && !foreign) g_mainScene = self;
    if (foreign != g_foreign.on || (foreign && cam != g_foreign.cam)) {
        if (foreign) {
            const bool starting = !g_foreign.on;
            if (starting) {
                // A new hold: fresh counters; logged while the session cap lasts.
                g_foreign.logged = g_foreign.logs < kForeignLogPeriods;
                if (g_foreign.logged) ++g_foreign.logs;
                g_foreign.follow = g_lua.foreignFollow;
                g_foreign.periodFrames = 0;
                g_foreign.swaps = 0;
                g_foreign.followDeg = 0.f;
                g_foreign.ignoredDeg = 0.f;
                g_foreign.easing = false;
                QueryPerformanceCounter(&g_foreign.t0);
            } else {
                ++g_foreign.swaps;
            }
            if (g_foreign.logged && (starting || g_foreign.swaps <= kForeignSwapLogs)) {
                // BG3's follow-target count: 1 = following someone (you, or
                // the one it looks at), 0 = following nobody (a fixed point),
                // 2+ = framing several.
                uint32_t nT = 0;
                char targets[16];
                if (dag::safemem::ReadBytes(cam + kCamTargetCount, &nT, sizeof(nT)) && nT < 64)
                    std::snprintf(targets, sizeof(targets), "%u", nT);
                else
                    std::snprintf(targets, sizeof(targets), "?");
                char swapTag[40] = "";
                if (!starting) std::snprintf(swapTag, sizeof(swapTag), " [camera swap %d in this hold]", g_foreign.swaps);
                const char* what = g_foreign.follow
                    ? " -> first person keeps your head; the view follows your mouse"
                    : " -> first person keeps your head and your last view direction";
                dag::log::Writef("POV: camera %p (%s) pivot (%.1f,%.1f,%.1f) %.1f m from you%s%s, BG3 camera targets %s%s%s%s",
                                 static_cast<void*>(cam), slotCam ? "gameplay slot" : "other camera on the main view",
                                 pivot[0], pivot[1], pivot[2], farM, noPos ? ", no camera position" : "",
                                 badRot ? ", no rotation" : "", targets, what,
                                 g_foreign.goodRotOk ? "" : " (none yet: its own)", swapTag);
            }
        } else {
            // Back on you. Ease from the direction first person showed onto
            // BG3's camera, unless they already agree, the hold was cut off
            // (dialogue, load) or they are too far apart for a lerp.
            const float off = g_foreign.goodRotOk ? AngleDeg(g_foreign.goodRot, rot) : 0.f;
            const bool fresh = nowTick - g_foreign.lastTick <= kForeignGapMs;
            const char* how = "already on BG3's camera";
            char howBuf[96];
            if (off >= kEaseMinDeg) {
                if (g_lua.foreignEaseMs > 0.f && fresh && off <= kEaseMaxDeg && !g_lua.orbit) {
                    g_foreign.easing = true;
                    std::memcpy(g_foreign.easeFrom, g_foreign.goodRot, sizeof(g_foreign.easeFrom));
                    QueryPerformanceCounter(&g_foreign.easeT0);
                    std::snprintf(howBuf, sizeof(howBuf), "easing %.1f deg onto BG3's camera over %.0f ms", off, g_lua.foreignEaseMs);
                } else {
                    std::snprintf(howBuf, sizeof(howBuf), "snapped %.1f deg onto BG3's camera (%s)", off,
                                  g_lua.foreignEaseMs <= 0.f ? "ease 0" : (!fresh ? "hold was interrupted" : (g_lua.orbit ? "orbit" : "too far for an ease")));
                }
                how = howBuf;
            }
            if (g_foreign.logged) {
                const double ms = MsSince(g_foreign.t0);
                if (g_foreign.follow)
                    dag::log::Writef("POV: camera %p is on you again after %d frame(s) (%.0f ms, %d camera swap(s)); the view followed your mouse %.0f deg, ignored %.0f deg BG3 turned by itself; %s",
                                     static_cast<void*>(cam), g_foreign.periodFrames, ms, g_foreign.swaps,
                                     g_foreign.followDeg, g_foreign.ignoredDeg, how);
                else
                    dag::log::Writef("POV: camera %p is on you again after %d frame(s) (%.0f ms, %d camera swap(s)); the view held while BG3's camera turned %.0f deg; %s",
                                     static_cast<void*>(cam), g_foreign.periodFrames, ms, g_foreign.swaps,
                                     g_foreign.ignoredDeg, how);
            }
            g_foreign.logged = false;
        }
        g_foreign.on = foreign;
        g_foreign.cam = cam;
        g_foreign.frames = 0;
    }
    if (foreign) {
        ++g_foreign.frames;
        ++g_foreign.periodFrames;
        g_foreign.lastTick = nowTick;
        // Follow the slot camera's turn while it is your mouse's (see
        // Foreign above); a jump bigger than any mouse turn in one frame,
        // or a turn with the mouse still, is BG3's own and is left out.
        if (srcTurnDeg > kTurnEpsDeg && g_foreign.goodRotOk) {
            const bool mouse = srcTurnDeg <= kMaxTurnDegPerFrame && MouseMovedWithin(g_lua.foreignMouseMs);
            if (g_foreign.follow && mouse) {
                ApplyTurn(g_foreign.goodRot, srcPrev, srcNow);
                g_foreign.followDeg += srcTurnDeg;
            } else {
                g_foreign.ignoredDeg += srcTurnDeg;
            }
        }
        if (g_foreign.goodRotOk) std::memcpy(rot, g_foreign.goodRot, sizeof(rot));
        // Every check below compares against this point: the character's
        // own (Lua root, raised to where the gameplay pivot sits).
        pivot[0] = g_lua.root[0]; pivot[1] = g_lua.root[1] + kPivotAboveFeet; pivot[2] = g_lua.root[2];
        pivotOk = true;
    } else {
        if (g_foreign.easing) {
            const double w = g_lua.foreignEaseMs > 0.f ? MsSince(g_foreign.easeT0) / g_lua.foreignEaseMs : 1.0;
            if (g_lua.orbit || w >= 1.0) {
                g_foreign.easing = false;
            } else {
                // The ease start turns with the mouse too, so only the
                // leftover offset fades; mouse-look stays live throughout.
                if (srcTurnOk && srcTurnDeg > kTurnEpsDeg && srcTurnDeg <= kMaxTurnDegPerFrame)
                    ApplyTurn(g_foreign.easeFrom, srcPrev, srcNow);
                const float a = static_cast<float>(w);
                float e[3] = { g_foreign.easeFrom[0] + (rot[0] - g_foreign.easeFrom[0]) * a,
                               g_foreign.easeFrom[1] + (rot[1] - g_foreign.easeFrom[1]) * a,
                               g_foreign.easeFrom[2] + (rot[2] - g_foreign.easeFrom[2]) * a };
                const float el = Len3(e);
                if (el > 0.1f) { rot[0] = e[0] / el; rot[1] = e[1] / el; rot[2] = e[2] / el; }
                else g_foreign.easing = false;
            }
        }
        std::memcpy(g_foreign.goodRot, rot, sizeof(rot));
        g_foreign.goodRotOk = true;
    }

    if (g_lua.orbit) return OrbitCommit(self, slotToken, outPos, cam, original, rot);

    // Horizontal forward (the way the camera looks, flattened). Near
    // straight up/down the flattened vector degenerates, so keep the last
    // good one instead of letting it jitter.
    static float s_fx = 0.f, s_fz = 1.f;
    float fx = -rot[0], fz = -rot[2];
    const float fh = std::sqrt(fx * fx + fz * fz);
    if (fh > 0.05f) { fx /= fh; fz /= fh; s_fx = fx; s_fz = fz; }
    else            { fx = s_fx; fz = s_fz; }
    dag::realjump::SetCameraForward(fx, fz);
    dag::movefeel::SetCameraForward(fx, fz);

    // Looking down: slide the eye forward (up to downFwd metres when
    // looking straight down) so the view clears the neck/collar.
    // Forward is -rot, so looking down means rot.y > 0.
    const float downAmt = rot[1] > 0.f ? (rot[1] > 1.f ? 1.f : rot[1]) : 0.f;
    const float fwdTotal = g_lua.eyeFwd + g_lua.downFwd * downAmt;

    float eye[3];
    float head[3] = {};
    const char* src = "pivot";
    bool have = false;

    // The body lift (VisualLift) moves the mesh, so a head bone read from
    // it already carries the lift; the pivot (TransformComponent) never does.
    const bool bodyLift = dag::visuallift::BodyLiftActive();
    const float lift = g_jump.real ? 0.f : g_jump.lift;   // real jump: the pivot itself rises

    if (g_lua.anchor && HeadBoneWorld(head)) {
        // Sanity: must be near the engine's own idea of where the character is.
        const bool sane = !pivotOk ||
            (std::fabs(head[0] - pivot[0]) < 2.0f && std::fabs(head[2] - pivot[2]) < 2.0f &&
             std::fabs(head[1] - pivot[1]) < 2.5f + lift);
        if (!sane) {
            if (++g_badFrames > 30) { g_head.valid = false; g_badFrames = 0; }
        } else if (!g_head.calibrated) {
            // Learn the eye height above the head bone from the signed-off
            // pivot eye, at rest (no jump), then switch to the bone.
            if (pivotOk && !foreign && !g_jump.active && !g_lua.crouch) {
                const float bodyY = head[1] - (bodyLift ? lift : 0.f);
                g_head.calSum += static_cast<double>(pivot[1] + g_lua.pivotUp - bodyY);
                if (++g_head.calN >= 30) {
                    float up = static_cast<float>(g_head.calSum / g_head.calN);
                    if (up < -0.30f || up > 0.40f) {
                        dag::log::Writef("HEAD calibrate: eye offset %.3f out of range, using 0.10", up);
                        up = 0.10f;
                    }
                    g_head.eyeUpAuto = up;
                    g_head.calibrated = true;
                    dag::log::Writef("HEAD calibrate: eye = %s + %.3f m (from pivot eye over 30 frames)",
                                     g_head.name, up);
                }
            }
        } else {
            g_badFrames = 0;
            // Optional light smoothing of the head's offset from the pivot
            // (off by default; only if the CAM delta log shows pose jitter).
            if (g_lua.smooth > 0.f && pivotOk) {
                float hr[3] = { head[0] - pivot[0], head[1] - pivot[1], head[2] - pivot[2] };
                if (!g_cam.sHave) { std::memcpy(g_cam.s, hr, sizeof(hr)); g_cam.sHave = true; }
                const float a = 1.f - g_lua.smooth;
                for (int i = 0; i < 3; ++i) {
                    g_cam.s[i] += (hr[i] - g_cam.s[i]) * a;
                    head[i] = pivot[i] + g_cam.s[i];
                }
            } else {
                g_cam.sHave = false;
            }
            eye[0] = head[0] + fx * fwdTotal;
            // The head carries whatever lift is really on the body; add the
            // rest so the camera always rises the full amount. 2026-10-09:
            // while walking the Visual reported the lift but the mesh (and
            // the head bone) stayed down, so the rise is measured on the
            // head mesh's render object, not taken from the Visual.
            // 2026-10-10: the mesh object at MeshBinding+0x28 never moved
            // (meshRise=0 on every jump), so the camera added the full lift
            // on top of a head that already rose: 2x at a 10x jump. The
            // rise is now measured on the head bone itself (its height
            // above the pivot vs the same at rest).
            float missing = lift;
            const float meshY = head[1];
            const bool meshOk = std::isfinite(meshY);
            if (meshOk && pivotOk) {
                const float off = meshY - pivot[1];
                if (!g_jump.active) {
                    g_meshOff = g_meshOffOk ? g_meshOff + (off - g_meshOff) * 0.1f : off;
                    g_meshOffOk = true;
                } else if (g_meshOffOk) {
                    float rise = off - g_meshOff;
                    if (rise > g_jls.maxMeshRise) g_jls.maxMeshRise = rise;
                    ++g_jls.meshFrames;
                    if (rise < 0.f) rise = 0.f;
                    if (rise > lift) rise = lift;
                    missing = lift - rise;
                    // The mesh isn't following the lifted Visual: re-apply
                    // the lift after the engine's own writes from now on.
                    if (bodyLift && !dag::visuallift::Forced() && lift > 0.2f && rise < 0.5f * lift && g_jls.meshFrames > 10) {
                        dag::visuallift::SetForce(true);
                        dag::log::Writef("LIFT: head mesh rose %.2f of %.2f m -> re-applying the lift after engine writes (force on)", rise, lift);
                    }
                }
            } else if (bodyLift) {
                const float applied = dag::visuallift::AppliedLift();
                missing = lift - (applied < 0.f ? 0.f : (applied > lift + 0.05f ? lift : applied));
            }
            eye[1] = head[1] + g_head.eyeUpAuto + g_lua.eyeUp + missing;
            eye[2] = head[2] + fz * fwdTotal;
            src = "bone"; have = true;
            if (g_jump.active) {
                if (missing > g_jls.maxMissing) g_jls.maxMissing = missing;
                if (missing > 0.03f) ++g_jls.fillFrames;
            }
        }
    }
    const uintptr_t meshForFallback = g_head.mb ? g_head.mb : g_sel.mesh;
    if (!have && meshForFallback) {
        float mt[16];
        if (ReadMeshTransform(meshForFallback, mt)) {
            const float base[3] = { mt[12], mt[13], mt[14] };
            if (!pivotOk || (std::fabs(base[0] - pivot[0]) < 2.0f && std::fabs(base[2] - pivot[2]) < 2.0f)) {
                eye[0] = base[0] + fx * fwdTotal;
                eye[1] = base[1] + g_lua.eyeHeight + (bodyLift ? 0.f : lift);
                eye[2] = base[2] + fz * fwdTotal;
                src = "mesh"; have = true;
            }
        }
    }
    if (!have) {
        if (!pivotOk) return false;
        eye[0] = pivot[0] + fx * fwdTotal;
        eye[1] = pivot[1] + g_lua.pivotUp + lift;
        eye[2] = pivot[2] + fz * fwdTotal;
        src = "pivot";
    }

    // Per-jump lift bookkeeping (both anchors).
    if (g_jump.active) {
        ++g_jls.frames;
        if (std::strcmp(src, "bone") == 0) ++g_jls.boneFrames;
        if (bodyLift) {
            const float applied = dag::visuallift::AppliedLift();
            const float err = std::fabs(applied - lift);
            if (err > g_jls.maxBodyErr) g_jls.maxBodyErr = err;
            if (err < 0.03f) ++g_jls.bodyFrames;
        }
    }

    // Camera steadiness relative to the body (see CamStats).
    if (pivotOk) {
        const float rel[3] = { eye[0] - fx * fwdTotal - pivot[0], eye[1] - lift - pivot[1], eye[2] - fz * fwdTotal - pivot[2] };
        const DWORD nowMs = GetTickCount();
        if (g_cam.windowStart == 0) g_cam.windowStart = nowMs;
        if (g_cam.have1) {
            const float d[3] = { rel[0] - g_cam.r1[0], rel[1] - g_cam.r1[1], rel[2] - g_cam.r1[2] };
            const float dl = Len3(d);
            if (dl < 1.0f) {   // ignore teleports / anchor switches
                g_cam.sumD += dl; ++g_cam.n;
                if (dl > g_cam.maxD) g_cam.maxD = dl;
                g_stepD[g_stepHead] = dl; g_stepT[g_stepHead] = nowMs; g_stepHead = (g_stepHead + 1) % kStepRing;
                if (g_jump.active) {
                    const double jms = MsSince(g_jump.t0);
                    if (jms <= 300.0 && dl > g_jls.takeoffMax) { g_jls.takeoffMax = dl; g_jls.takeoffAt = jms; }
                }
                if (g_cam.have2) {
                    const float j[3] = { rel[0] - 2 * g_cam.r1[0] + g_cam.r2[0], rel[1] - 2 * g_cam.r1[1] + g_cam.r2[1],
                                         rel[2] - 2 * g_cam.r1[2] + g_cam.r2[2] };
                    const float jl = Len3(j);
                    if (jl > g_cam.maxJ) g_cam.maxJ = jl;
                }
            }
            std::memcpy(g_cam.r2, g_cam.r1, sizeof(rel)); g_cam.have2 = true;
        }
        std::memcpy(g_cam.r1, rel, sizeof(rel)); g_cam.have1 = true;
        if (nowMs - g_cam.windowStart >= 3000 && g_cam.n > 0) {
            g_cam.lastAvg = static_cast<float>(g_cam.sumD / g_cam.n);
            g_cam.lastMax = g_cam.maxD;
            g_cam.lastJerk = g_cam.maxJ;
            dag::log::Writef("CAM delta anchor=%s src=%s frames=%d avg=%.4f max=%.4f jerk=%.4f smooth=%.2f jump=%d",
                             g_lua.anchor ? "head" : "pivot", src, g_cam.n, g_cam.lastAvg, g_cam.lastMax,
                             g_cam.lastJerk, g_lua.smooth, g_jump.active ? 1 : 0);
            g_cam.windowStart = nowMs; g_cam.n = 0; g_cam.sumD = 0; g_cam.maxD = 0; g_cam.maxJ = 0;
        }
    }

    // Look-at point: in front of the eye along the engine's view direction.
    const float P[3] = {
        eye[0] - rot[0] * g_lua.look,
        eye[1] - rot[1] * g_lua.look,
        eye[2] - rot[2] * g_lua.look,
    };

    // Every field the commit might build its view from gets the same
    // point, then is restored afterwards (only if still ours).
    CommitWith(self, slotToken, outPos, cam, original, eye, P);

    g_status.applied = true;
    g_status.src = src;
    std::memcpy(g_status.eye, eye, sizeof(eye));
    std::memcpy(g_status.P, P, sizeof(P));
    std::memcpy(g_status.head, head, sizeof(head));
    std::memcpy(g_status.rot, rot, sizeof(rot));
    return true;
}

}  // namespace dag::pov
