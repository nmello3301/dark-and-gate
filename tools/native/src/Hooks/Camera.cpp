// SPDX-License-Identifier: GPL-3.0-or-later
//
// Camera position pin + feature-tick heartbeat.
//
// Approach (reviewed with user, see docs/spikes/m1a-camera-follow.md):
//   1. On each UpdateCamera call, we're given cameraSlot (R9). The slot[6]
//      dereference is the camera-struct (RDI in the engine); offset
//      0x30 inside cameraSlot itself is the lerp target
//      (GameCameraBehavior::TargetDestinationHigh per bg3se). We probe
//      BOTH candidates against Lua's periodic ground-truth file; the
//      first whose (x,y,z) matches within 0.05 m becomes the "live char
//      position" source for every subsequent frame — zero file-driven
//      lag.
//   2. Only cams whose probe matches ground truth are "gameplay". Menu
//      preview, dialog, cutscene cams never match and never get pinned.
//      Any cam whose last probe diverges by >1 m from ground truth gets
//      un-latched and skipped — self-healing against mode changes.
//   3. If Lua's ground truth says active=0 (dialog/cutscene/UI), ALL
//      cams are left vanilla. No pinning, no mouselook, no character
//      facing — the only safe way to never break a cutscene.
//   4. Trampoline chain follows two shapes: 48 B8 ... FF E0 (our
//      InstallFarCall5 output) and FF 25 <rel32> (NCT's IAT-style
//      indirect). The install log now identifies NCT by name.

#include "Camera.h"

#include <windows.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "../Config.h"
#include "../GroundTruth.h"
#include "../Log.h"
#include "../Offsets.h"
#include "../PatternScan.h"
#include "../SafeMem.h"
#include "Mouselook.h"
#include "Stubs.h"

namespace dag::hooks::camera {

namespace {

using UpdateCameraFn = void (*)(void*, void**, uintptr_t, void**);
UpdateCameraFn _UpdateCamera = nullptr;

uint8_t* _callSite      = nullptr;
void*    _ourHookAddr   = nullptr;
DWORD    _installTickMs = 0;
bool     _checked5s     = false;
bool     _checked20s    = false;

// Calibration source "where did the live char position live?" The
// probe records the (base object, offset) pair that matched Lua.
enum class ProbeKind : uint8_t {
    Unprobed,
    Behavior,        // base = cameraSlot (the 4th arg as behavior)
    CamStruct,       // base = cameraSlot[6] (deref'd struct)
    Failed,          // tried, no match within tolerance
};

struct CamStats {
    void*    cam;              // cameraSlot[6], used as cam identity
    void*    behavior;         // the 4th arg (cameraSlot)
    uint64_t count;
    ProbeKind kind;
    uint32_t winningOffset;
    float    lastCharX, lastCharY, lastCharZ;   // what we read from live mem
    float    lastEngX, lastEngY, lastEngZ;      // cam after _UpdateCamera
    float    lastWrittenX, lastWrittenY, lastWrittenZ;
    bool     wroteLast;
    DWORD    lastDivergeLogMs;
};
constexpr size_t kMaxCams = 8;
CamStats _cams[kMaxCams] = {};
size_t   _numCams = 0;

CamStats* FindOrAdd(void* cam, void* behavior) {
    for (size_t i = 0; i < _numCams; ++i) {
        if (_cams[i].cam == cam) {
            _cams[i].behavior = behavior;  // refresh (rarely changes)
            return &_cams[i];
        }
    }
    if (_numCams < kMaxCams) {
        _cams[_numCams] = CamStats{};
        _cams[_numCams].cam      = cam;
        _cams[_numCams].behavior = behavior;
        _cams[_numCams].kind     = ProbeKind::Unprobed;
        return &_cams[_numCams++];
    }
    return nullptr;
}

uint64_t _totalCalls    = 0;
DWORD    _lastTickLogMs = 0;
DWORD    _lastConfigPollMs = 0;
DWORD    _lastStatusWriteMs = 0;

// Phase B pre-hook state (forward-declared so WriteStatusFile can read).
int   _behaviorSlotIdx = -1;
void* _behaviorPtr     = nullptr;
DWORD _lastBehaviorLogMs = 0;

// -------------------------------------------------------------------
// Phase D: hook CameraSystem::vtable[0x58] (CommitSlotTransform).
//
// Why: FUN_141e0f110 (UpdateCamera) ends with `vt[0x58](this, slotTok,
// &local_508, &cam[0x48])`. local_508 is the frame's new camera
// position; vt[0x58] writes it to cam[0x48..0x50] AND into the
// rendered InvViewMatrix. Writing cam[0x48..0x50] before the chain
// gets overwritten by sub-functions in UpdateCamera; writing after
// is too late. Intercepting vt[0x58] catches the write in flight.
//
// Install: on the first live UpdateCamera invocation, read the scene
// vtable (scene is param_1 = CameraSystem*), patch slot 11 (0x58/8)
// to our hook, remember the original for chaining.
//
// Per-call: if g_desiredSet is true (set by the pre-hook block in
// Hook_UpdateCamera when gameplay is active + camera enabled),
// overwrite the newPos vec3 in place. If false, pass through unmodified.
// -------------------------------------------------------------------
using CommitFn = void(__fastcall*)(void*, void*, float*, float*);
CommitFn _OriginalCommit = nullptr;
bool     _vt58Hooked     = false;
void**   _vt58VtableSlot = nullptr;  // for diagnostics

// Thread-local would be nice but x64 __fastcall imposes no reentrancy
// here — UpdateCamera is called single-threaded from the render path.
float g_desiredPos[3] = { 0, 0, 0 };
bool  g_desiredSet    = false;

void __fastcall HookCommit(void* self, void* slotToken, float* newPos, float* outPos)
{
    if (g_desiredSet && newPos) {
        newPos[0] = g_desiredPos[0];
        newPos[1] = g_desiredPos[1];
        newPos[2] = g_desiredPos[2];
    }
    if (_OriginalCommit) {
        _OriginalCommit(self, slotToken, newPos, outPos);
    }
}

void TryInstallVt58(void* scene)
{
    static bool _firstLog = true;
    if (_firstLog) {
        _firstLog = false;
        dag::log::Writef("VT58: TryInstall first call scene=%p hooked=%d",
                         scene, _vt58Hooked ? 1 : 0);
    }
    if (_vt58Hooked) return;
    if (!scene) {
        if (!_firstLog) {
            dag::log::Writef("VT58: scene is NULL -- skipping install this frame");
        }
        return;
    }
    void** vtable = nullptr;
    const bool okV = dag::safemem::ReadBytes(scene, &vtable, sizeof(vtable));
    if (!okV || !vtable) {
        dag::log::Writef("VT58: vtable read failed scene=%p ok=%d vtable=%p",
                         scene, okV ? 1 : 0, vtable);
        return;
    }
    void* entry = nullptr;
    const bool okE = dag::safemem::ReadBytes(&vtable[11], &entry, sizeof(entry));
    if (!okE || !entry) {
        dag::log::Writef("VT58: entry read failed vtable=%p slot11=%p ok=%d entry=%p",
                         vtable, (void*)&vtable[11], okE ? 1 : 0, entry);
        return;
    }
    DWORD oldProt = 0;
    if (!VirtualProtect(&vtable[11], sizeof(void*), PAGE_READWRITE, &oldProt)) {
        dag::log::Writef("VT58: VirtualProtect to RW failed (%lu)", GetLastError());
        return;
    }
    _OriginalCommit = reinterpret_cast<CommitFn>(entry);
    vtable[11]      = reinterpret_cast<void*>(&HookCommit);
    DWORD tmp = 0;
    VirtualProtect(&vtable[11], sizeof(void*), oldProt, &tmp);
    _vt58VtableSlot = &vtable[11];
    _vt58Hooked     = true;
    dag::log::Writef(
        "VT58: hooked. scene=%p vtable=%p slot[11]=%p -> OurHook=%p (orig=%p)",
        scene, vtable, &vtable[11], reinterpret_cast<void*>(&HookCommit),
        reinterpret_cast<void*>(_OriginalCommit));
}

// Write our last-wrote / engine-pre-write / live-char-pos to a status
// file every ~1 s. Lua's !dag_camcheck reads it alongside the rendered
// camera position (from InvViewMatrix) so we can see whether our write
// is reaching the screen.
void WriteStatusFile(const CamStats& s)
{
    const DWORD now = GetTickCount();
    if (now - _lastStatusWriteMs < 1000) return;
    _lastStatusWriteMs = now;

    wchar_t buf[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return;
    wchar_t full[MAX_PATH * 2];
    swprintf_s(full, L"%s\\Larian Studios\\Baldur's Gate 3\\Script Extender\\DarkAndGate\\native-cam-status.txt", buf);

    // Also expose the Phase B pre-hook state: which cameraSlot[N] held
    // the GameCameraBehavior pointer (-1 if not identified), and the
    // last pre-hook write target.
    float preWrote[3] = { 0, 0, 0 };
    if (_behaviorPtr) {
        (void)dag::safemem::ReadFloat3(_behaviorPtr, 0x30, preWrote);
    }
    char line[640];
    const int len = std::snprintf(line, sizeof(line),
        "cam=%p calls=%llu src=%s off=0x%X "
        "char=%.3f,%.3f,%.3f eng=%.3f,%.3f,%.3f wrote=%.3f,%.3f,%.3f w=%d "
        "beh_slot=%d beh_ptr=%p beh_target=%.3f,%.3f,%.3f t=%u\n",
        s.cam, (unsigned long long)s.count,
        s.kind == ProbeKind::Behavior ? "beh" :
        (s.kind == ProbeKind::CamStruct ? "cam" : "unprobed"),
        s.winningOffset,
        s.lastCharX, s.lastCharY, s.lastCharZ,
        s.lastEngX,  s.lastEngY,  s.lastEngZ,
        s.lastWrittenX, s.lastWrittenY, s.lastWrittenZ,
        s.wroteLast ? 1 : 0,
        _behaviorSlotIdx, _behaviorPtr,
        preWrote[0], preWrote[1], preWrote[2],
        (unsigned)now);

    HANDLE h = CreateFileW(full, GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    WriteFile(h, line, len, &written, nullptr);
    CloseHandle(h);
}

// cam[0xC4] confirmed in session 725000015: probe at 0xC0 showed
// (90.0, 219.19, 24.18) while gt=(219.19, 24.18, 372.54) — so reading
// 3 floats at 0xC4 yields (x, y, z). Keep neighbours in probe set in
// case layout shifts between cam types.
constexpr uint32_t kCamStructProbes[] = {
    0xC4, 0xC8, 0xB4, 0x30, 0x60, 0xA0, 0xB0, 0xC0, 0x100, 0x120, 0x160, 0x1A0, 0x200,
};
constexpr uint32_t kBehaviorProbes[] = {
    dag::offsets::kBehaviorTargetDestinationHigh,  // 0x30 — primary
    dag::offsets::kBehaviorTargetDestination,       // 0x24
    dag::offsets::kBehaviorTargetCurrent,           // 0x48
    dag::offsets::kBehaviorTargetCurrentLow,        // 0x3C
};

constexpr float kCalibTolerance = 0.05f;      // match ground truth within 5 cm
// Walking char moves ~2.5 m between the 500 ms gt writes. Divergence
// must be larger than that gap or we re-latch every walking frame.
// 5 m covers running + a bit of head-room; a true cam-mode switch
// (dialog, menu) typically relocates the cam by tens of metres.
constexpr float kDivergeTolerance = 5.00f;

bool Match(const float probe[3], float gx, float gy, float gz, float tol) {
    return std::fabs(probe[0] - gx) <= tol
        && std::fabs(probe[1] - gy) <= tol
        && std::fabs(probe[2] - gz) <= tol;
}

void CheckCallSiteStillOurs(const char* when) {
    if (!_callSite) return;
    if (_callSite[0] != 0xE8) {
        dag::log::Writef("CallSiteCheck[%s]: byte 0 is %02X not E8", when, _callSite[0]);
        return;
    }
    int32_t rel = 0;
    std::memcpy(&rel, _callSite + 1, 4);
    uint8_t* target = _callSite + 5 + rel;
    bool ok = (reinterpret_cast<void*>(target) == _ourHookAddr);
    if (!ok) {
        void* abs = nullptr;
        if (target[0] == 0x48 && target[1] == 0xB8) {
            std::memcpy(&abs, target + 2, 8);
            if (abs == _ourHookAddr) ok = true;
        }
    }
    dag::log::Writef(
        "CallSiteCheck[%s]: CALL at %p -> %p (ours=%p) %s",
        when, _callSite, target, _ourHookAddr,
        ok ? "OK (still ours)" : "DIFFERENT (re-patched?)");
}

// Returns true if the probe found a live source matching ground truth.
bool CalibrateCam(CamStats* stat, float gx, float gy, float gz, char* out, size_t cap)
{
    int w = 0;

    // 1. Try behavior offsets first (lerp target is at 0x30 — zero-lag).
    if (stat->behavior) {
        for (uint32_t off : kBehaviorProbes) {
            float p[3] = {};
            if (dag::safemem::ReadFloat3(stat->behavior, off, p)) {
                w += std::snprintf(out + w, cap - w,
                    " beh[0x%X]=(%.2f,%.2f,%.2f)", off, p[0], p[1], p[2]);
                if (Match(p, gx, gy, gz, kCalibTolerance)) {
                    stat->kind          = ProbeKind::Behavior;
                    stat->winningOffset = off;
                    stat->lastCharX = p[0]; stat->lastCharY = p[1]; stat->lastCharZ = p[2];
                    return true;
                }
            }
        }
    }
    // 2. Fall back to the cam struct itself (second-level deref).
    if (stat->cam) {
        for (uint32_t off : kCamStructProbes) {
            float p[3] = {};
            if (dag::safemem::ReadFloat3(stat->cam, off, p)) {
                w += std::snprintf(out + w, cap - w,
                    " cam[0x%X]=(%.2f,%.2f,%.2f)", off, p[0], p[1], p[2]);
                if (Match(p, gx, gy, gz, kCalibTolerance)) {
                    stat->kind          = ProbeKind::CamStruct;
                    stat->winningOffset = off;
                    stat->lastCharX = p[0]; stat->lastCharY = p[1]; stat->lastCharZ = p[2];
                    return true;
                }
            }
        }
    }
    stat->kind = ProbeKind::Failed;
    return false;
}

bool ReadLiveCharPos(CamStats* stat, float out[3]) {
    void* base = (stat->kind == ProbeKind::Behavior) ? stat->behavior : stat->cam;
    if (!base) return false;
    return dag::safemem::ReadFloat3(base, stat->winningOffset, out);
}

// Phase B: identify which cameraSlot[N] holds the GameCameraBehavior
// pointer by probing cameraSlot[N]+0x30 (TargetDestinationHigh) for a
// float[3] that matches Lua ground truth within 0.05 m. Cached across
// frames via static state. Once identified, the pre-hook writes our
// desired position to that slot's +0x30 BEFORE calling the engine
// UpdateCamera, so the engine's LERP + vt[0x58] commit publish our
// value to InvViewMatrix.
constexpr size_t kBehaviorSlotProbeMax = 16;

bool IdentifyBehaviorSlot(void** cameraSlot, float gx, float gy, float gz,
                          char* out, size_t cap)
{
    int w = 0;
    for (size_t i = 0; i < kBehaviorSlotProbeMax; ++i) {
        void* candidate = nullptr;
        // Guard against unreadable slot (unlikely for a stack-like array,
        // but cheap). SEH wrap via SafeMem.
        if (!dag::safemem::ReadBytes(cameraSlot + i, &candidate, sizeof(candidate))) continue;
        if (!candidate) continue;
        float p[3] = {};
        if (!dag::safemem::ReadFloat3(candidate, 0x30, p)) continue;
        if (std::fabs(p[0]) > 1e6f || std::fabs(p[2]) > 1e6f) continue;  // skip garbage
        if (w + 60 < static_cast<int>(cap)) {
            w += std::snprintf(out + w, cap - w, " [%zu]+0x30=(%.2f,%.2f,%.2f)",
                               i, p[0], p[1], p[2]);
        }
        if (std::fabs(p[0] - gx) < 0.05f &&
            std::fabs(p[1] - gy) < 0.05f &&
            std::fabs(p[2] - gz) < 0.05f) {
            _behaviorSlotIdx = static_cast<int>(i);
            _behaviorPtr     = candidate;
            return true;
        }
    }
    return false;
}

void Hook_UpdateCamera(void* scene, void** ctx,
                       uintptr_t frameInfo, void** cameraSlot)
{
    const DWORD now = GetTickCount();
    if (now - _lastConfigPollMs > 1000) {
        _lastConfigPollMs = now;
        dag::config::PollAndReload();
        dag::groundtruth::Poll();
    }

    const auto& cfg = dag::config::Get();
    const auto  gt  = dag::groundtruth::Get();
    const bool gtOk = gt.active && !gt.stale;

    // Phase D: install vt[0x58] hook on first call, then set the
    // thread-shared desired position so the vt[0x58] intercept
    // overwrites the eye position in flight.
    //
    // Source: cam[0xC4] = the engine's look-at TARGET for this frame
    // (= controlled char + ~1.6 m head offset). It is updated zero-lag
    // every frame by the engine's follow logic. We use it as the base
    // because: (a) no lag, (b) no file dependency, (c) baked-in head
    // offset means debug_lift_m stacks on head height, not feet.
    //
    // The eye is normally computed as eye = target - forward * distance
    // (vanilla ~12 m behind, ~8 m up). vt[0x58] receives the final eye;
    // our hook substitutes it with (target.x, target.y + h, target.z)
    // so the camera sits AT the look-at target plus h.
    TryInstallVt58(scene);

    float* cam_pre = nullptr;
    if (cameraSlot) {
        cam_pre = reinterpret_cast<float*>(cameraSlot[6]);
    }
    g_desiredSet = false;
    if (cfg.camera.enabled && gtOk && cam_pre) {
        float lookAt[3] = {};
        if (dag::safemem::ReadFloat3(cam_pre, dag::offsets::kCamLookAtTargetPos, lookAt)) {
            const bool sane = (std::fabs(lookAt[0]) > 0.1f || std::fabs(lookAt[2]) > 0.1f)
                              && std::fabs(lookAt[1]) < 10000.0f;
            if (sane) {
                const float h = (cfg.camera.debug_lift_m > 0.0f)
                                ? cfg.camera.debug_lift_m
                                : cfg.camera.eye_height;
                g_desiredPos[0] = lookAt[0];
                g_desiredPos[1] = lookAt[1] + h;
                g_desiredPos[2] = lookAt[2];
                g_desiredSet    = true;
            }
        }
    }

    if (_UpdateCamera) {
        _UpdateCamera(scene, ctx, frameInfo, cameraSlot);
    }
    // Reset after chain so an unrelated call through vt[0x58] (e.g.
    // dialogue cam flipping in mid-frame) doesn't inherit our value.
    g_desiredSet = false;

    void*  behavior = cameraSlot;  // the 4th arg itself may be the behavior
    float* cam = nullptr;
    float  xEng = 0, yEng = 0, zEng = 0;
    if (cameraSlot) {
        cam = reinterpret_cast<float*>(cameraSlot[6]);
    }
    if (cam) {
        dag::safemem::ReadFloat(cam, dag::offsets::kCamWorldPosX, xEng);
        dag::safemem::ReadFloat(cam, dag::offsets::kCamWorldPosY, yEng);
        dag::safemem::ReadFloat(cam, dag::offsets::kCamWorldPosZ, zEng);
    }

    CamStats* stat = cam ? FindOrAdd(cam, behavior) : nullptr;

    // Calibrate: once per cam while active+non-stale. Also recalibrate
    // if a previous probe diverges by more than 1 m from ground truth.
    if (stat && gtOk) {
        bool needCalibrate = (stat->kind == ProbeKind::Unprobed) ||
                             (stat->kind == ProbeKind::Failed);
        if (!needCalibrate &&
            (stat->kind == ProbeKind::Behavior || stat->kind == ProbeKind::CamStruct)) {
            float live[3] = {};
            if (ReadLiveCharPos(stat, live)) {
                if (!Match(live, gt.x, gt.y, gt.z, kDivergeTolerance)) {
                    // Diverged — likely cam switched char or latch stale.
                    if (now - stat->lastDivergeLogMs > 2000) {
                        dag::log::Writef(
                            "Camera: cam=%p diverged live=(%.2f,%.2f,%.2f) gt=(%.2f,%.2f,%.2f) — relatching",
                            cam, live[0], live[1], live[2], gt.x, gt.y, gt.z);
                        stat->lastDivergeLogMs = now;
                    }
                    needCalibrate = true;
                }
            }
        }
        if (needCalibrate) {
            char probeLog[512];
            probeLog[0] = 0;
            bool ok = CalibrateCam(stat, gt.x, gt.y, gt.z, probeLog, sizeof(probeLog));
            dag::log::Writef(
                "Camera: cam=%p behavior=%p gt=(%.2f,%.2f,%.2f) -> %s%s%s",
                cam, behavior, gt.x, gt.y, gt.z,
                ok ? (stat->kind == ProbeKind::Behavior ? "BEHAVIOR" : "CAMSTRUCT") : "NO MATCH",
                (ok ? " @ 0x" : ""), probeLog);
            if (ok) {
                dag::log::Writef("  winOff=0x%X", stat->winningOffset);
            }
        }
    }

    // STEP-C-STYLE WRITE (debug): Y += lift on every cam while gameplay
    // active. Isolates "does cam+0x4c Y write still affect rendering?".
    // Absolute pin + per-cam gating are temporarily disabled while we
    // verify the write path.
    bool wrote = false;
    float wx = xEng, wy = yEng, wz = zEng;
    if (cfg.camera.enabled && gtOk && cam) {
        const float h = (cfg.camera.debug_lift_m > 0.0f)
                        ? cfg.camera.debug_lift_m
                        : cfg.camera.eye_height;
        wy = yEng + h;
        std::memcpy(reinterpret_cast<uint8_t*>(cam) + dag::offsets::kCamWorldPosY, &wy, 4);
        wrote = true;
        if (stat) {
            // Still track live char pos for diagnostics when latch succeeded.
            float live[3] = {};
            if ((stat->kind == ProbeKind::Behavior || stat->kind == ProbeKind::CamStruct) &&
                ReadLiveCharPos(stat, live)) {
                stat->lastCharX = live[0];
                stat->lastCharY = live[1];
                stat->lastCharZ = live[2];
            }
        }
    }

    // Mouselook: pump the SDL-polling tick first (so dx/dy for this
    // frame are accumulated into our yaw/pitch), then rotate cam forward.
    dag::hooks::mouselook::Tick();
    dag::hooks::mouselook::MaybeWriteYawForLua();
    dag::hooks::stubs::Tick();

    // Rotate cam forward vector per accumulated deltas.
    // Only when gameplay cam is pinned and mouselook enabled + unpaused.
    if (cfg.mouselook.enabled && gtOk && wrote && cam) {
        float yaw   = dag::hooks::mouselook::GetYawRad();
        float pitch = dag::hooks::mouselook::GetPitchRad();
        // Build forward from yaw/pitch (Y-up, right-handed).
        float cp = std::cos(pitch), sp = std::sin(pitch);
        float cy = std::cos(yaw),   sy = std::sin(yaw);
        float fx = sy * cp;
        float fy = -sp;
        float fz = cy * cp;
        std::memcpy(reinterpret_cast<uint8_t*>(cam) + dag::offsets::kCamForwardX, &fx, 4);
        std::memcpy(reinterpret_cast<uint8_t*>(cam) + dag::offsets::kCamForwardY, &fy, 4);
        std::memcpy(reinterpret_cast<uint8_t*>(cam) + dag::offsets::kCamForwardZ, &fz, 4);
        std::memcpy(reinterpret_cast<uint8_t*>(cam) + dag::offsets::kCamPitch,    &pitch, 4);
    }

    // Bookkeeping.
    ++_totalCalls;
    if (stat) {
        ++stat->count;
        stat->lastEngX     = xEng;    stat->lastEngY     = yEng;    stat->lastEngZ     = zEng;
        stat->lastWrittenX = wx;      stat->lastWrittenY = wy;      stat->lastWrittenZ = wz;
        stat->wroteLast    = wrote;
    }

    // Write the per-write status file for the "best" cam we have —
    // use the one with the most calls, which is the gameplay cam by
    // dominant-presence (even if calibration didn't latch it).
    if (_numCams > 0) {
        CamStats* best = &_cams[0];
        for (size_t i = 1; i < _numCams; ++i) {
            if (_cams[i].count > best->count) best = &_cams[i];
        }
        WriteStatusFile(*best);
    }

    if (!_checked5s  && now - _installTickMs > 5000)  { CheckCallSiteStillOurs("5s");  _checked5s  = true; }
    if (!_checked20s && now - _installTickMs > 20000) { CheckCallSiteStillOurs("20s"); _checked20s = true; }

    if (now - _lastTickLogMs > 5000) {
        _lastTickLogMs = now;
        size_t pinned = 0;
        for (size_t i = 0; i < _numCams; ++i) {
            if (_cams[i].kind == ProbeKind::Behavior || _cams[i].kind == ProbeKind::CamStruct) ++pinned;
        }
        dag::log::Writef(
            "Camera: tick total=%llu cams=%zu pinned=%zu gt=active:%d stale:%d (%.2f,%.2f,%.2f)",
            (unsigned long long)_totalCalls, _numCams, pinned,
            gt.active ? 1 : 0, gt.stale ? 1 : 0, gt.x, gt.y, gt.z);
        // Dump ALL cams during this debug round — need to see which one
        // is the actual render target.
        for (size_t i = 0; i < _numCams; ++i) {
            const auto& s = _cams[i];
            dag::log::Writef(
                "  cam[%zu]=%p calls=%llu src=%s off=0x%X char=(%.2f,%.2f,%.2f) eng=(%.2f,%.2f,%.2f) wrote=(%.2f,%.2f,%.2f) w=%d",
                i, s.cam, (unsigned long long)s.count,
                s.kind == ProbeKind::Behavior ? "beh" : "cam",
                s.winningOffset,
                s.lastCharX,    s.lastCharY,    s.lastCharZ,
                s.lastEngX,     s.lastEngY,     s.lastEngZ,
                s.lastWrittenX, s.lastWrittenY, s.lastWrittenZ,
                s.wroteLast ? 1 : 0);
        }
    }
}

}  // namespace

bool Install()
{
    uint8_t* anchor = dag::patternscan::Find(
        nullptr, dag::offsets::kUpdateCameraAnchorPattern);
    if (!anchor) {
        dag::log::Writef("Camera: UpdateCamera anchor pattern not found");
        return false;
    }
    uint8_t* callSite = anchor + dag::offsets::kUpdateCameraCallOffsetFromAnchor;
    if (callSite[0] != 0xE8) {
        dag::log::Writef(
            "Camera: anchor found but preceding byte is %02X, not E8 -- abort",
            callSite[0]);
        return false;
    }

    uint8_t* current = dag::patternscan::DecodeRelCallTarget(callSite);
    dag::log::Writef(
        "Camera: anchor at %p, CALL at %p -> current target %p",
        anchor, callSite, current);

    {
        char buf[80]; int off = 0;
        for (int i = 0; i < 16 && off + 4 < static_cast<int>(sizeof(buf)); ++i) {
            off += std::snprintf(buf + off, sizeof(buf) - off, "%02X ", current[i]);
        }
        dag::log::Writef("Camera: bytes @ current target: %s", buf);
    }

    uint8_t* previous = dag::patternscan::InstallFarCall5(
        callSite, reinterpret_cast<void*>(&Hook_UpdateCamera));
    if (!previous) {
        dag::log::Writef("Camera: InstallFarCall5 failed");
        return false;
    }
    _UpdateCamera  = reinterpret_cast<UpdateCameraFn>(previous);
    _callSite      = callSite;
    _ourHookAddr   = reinterpret_cast<void*>(&Hook_UpdateCamera);
    _installTickMs = GetTickCount();

    auto resolveModuleName = [](uint8_t* addr, char* out, size_t cap) -> HMODULE {
        HMODULE mod = nullptr;
        GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(addr), &mod);
        if (!mod) { out[0] = 0; return nullptr; }
        wchar_t wname[MAX_PATH] = {};
        GetModuleFileNameW(mod, wname, MAX_PATH);
        const wchar_t* base = wname;
        for (const wchar_t* p = wname; *p; ++p) if (*p == L'\\' || *p == L'/') base = p + 1;
        WideCharToMultiByte(CP_UTF8, 0, base, -1, out, static_cast<int>(cap), nullptr, nullptr);
        return mod;
    };

    uint8_t* trampTarget = previous;
    char     firstName[MAX_PATH] = {};
    char     finalName[MAX_PATH] = {};
    HMODULE  firstMod = resolveModuleName(previous, firstName, sizeof(firstName));

    if (!firstMod) {
        uint8_t* abs = nullptr;
        if (previous[0] == 0x48 && previous[1] == 0xB8 &&
            previous[10] == 0xFF && previous[11] == 0xE0) {
            void* a = nullptr; std::memcpy(&a, previous + 2, sizeof(a));
            abs = static_cast<uint8_t*>(a);
        } else if (previous[0] == 0xFF && previous[1] == 0x25) {
            int32_t disp = 0; std::memcpy(&disp, previous + 2, 4);
            uint8_t* iatSlot = previous + 6 + disp;
            void* a = nullptr;
            if (dag::safemem::ReadBytes(iatSlot, &a, sizeof(a))) abs = static_cast<uint8_t*>(a);
        }
        if (abs) trampTarget = abs;
    }
    HMODULE  finalMod = resolveModuleName(trampTarget, finalName, sizeof(finalName));
    HMODULE  mainExe  = GetModuleHandleW(nullptr);
    const bool chained = (finalMod && finalMod != mainExe);
    const char* via = finalName[0] ? finalName
                      : (firstName[0] ? firstName : "<trampoline, module unresolved>");
    dag::log::Writef(
        "Camera: hook installed. _UpdateCamera -> %p (%s via %s)",
        _UpdateCamera,
        chained ? "chained" : (finalMod ? "direct engine target" : "unresolved"),
        via);
    return true;
}

}  // namespace dag::hooks::camera
