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
#include "Pov.h"
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

// Instant-follow: resolved once at install. GetCurrentCameraDefinition
// is the function NCT uses to find the active CameraDefinition (which
// toggles between combat/exploration/cutscene variants). We call it
// each frame to write the follow damping fields.
using GetCamDefFn = void*(*)(void* /*CameraObject*/);
GetCamDefFn _GetCurrentCameraDefinition = nullptr;

// Thread-local would be nice but x64 __fastcall imposes no reentrancy
// here — UpdateCamera is called single-threaded from the render path.
float g_desiredPos[3]     = { 0, 0, 0 };
float g_desiredForward[3] = { 0, 0, 1 };   // world-space unit vec
bool  g_desiredSet        = false;

// Diagnostic snapshot shared with WriteStatusFile so dag_camcheck can
// print cam fields alongside InvViewMatrix for convention ground-truth.
struct CamDiag {
    float engEye[3];        // cam[0x48..0x50] — engine pivot
    float dist;             // cam[0x54]
    float basis[3];         // cam[0x70..0x78] — pivot->eye direction (= -forward_world)
    float lookAt[3];        // cam[0xC4..0xD0]
    bool  present;
};
CamDiag _lastDiag = {};

// Gameplay cam identity. Set when cam[0xC4] matches gt within 0.05 m
// (ONCE at calibration); only commits for this cam get our override.
// Pointer changes trigger re-identification; every other commit passes
// through untouched. headOff = cam[0xC4].y - gt.y measured at calibration,
// so eye.y = cam[0xC4].y - headOff + eye_height — live, zero-lag.
void* _gameplayCamPtr   = nullptr;
bool  _gameplayValid    = false;
float _headOff          = 0.0f;
DWORD _lastDriftLogMs   = 0;

void __fastcall HookCommit(void* self, void* slotToken, float* newPos, float* outPos)
{
    // Full POV (dag_full_pov) owns the gameplay camera's commit when on.
    if (dag::pov::HandleCommit(self, slotToken, newPos, outPos,
                               reinterpret_cast<dag::pov::CommitFn>(_OriginalCommit))) {
        return;
    }

    // All work happens inside this hook — no cross-frame state. That
    // way nothing we write can persist to the next frame and feed back
    // into our computation. Previous attempts split state across
    // Hook_UpdateCamera (pre-chain) and HookCommit (per-call) and drifted
    // because something outside our save/restore window (BG3WASD's
    // post-chain work is the leading suspect) could re-write cam[0xC4]
    // after our restore but before next frame's pre-hook read.
    //
    // Strategy (2026-10-08): ENGINE owns yaw, WE own pitch and position.
    // Rationale: writes to cam[0x70..0x78] / cam[0xC4] produced
    // inconsistent rendered-forward results, suggesting the engine's
    // ViewMatrix construction doesn't use cam[0xC4] directly or uses
    // a basis with convention we haven't ground-truthed. The engine
    // already turns mouse X into camera yaw (visible: minimap rotates).
    // We leverage that: read the engine's current look direction from
    // (cam[0xC4] - cam[0x48..0x50]) in XZ, extract yaw, replace pitch
    // with our accumulated mouse-Y, rebuild lookAt. Eye stays at
    // char + eye_height.

    const auto& cfg  = dag::config::Get();
    const auto  gt   = dag::groundtruth::Get();
    const bool  gtOk = gt.active && !gt.stale;

    uint8_t* cam = outPos ? (reinterpret_cast<uint8_t*>(outPos) - 0x48) : nullptr;

    // Always-on diagnostic snapshot for whichever cam this commit is on,
    // so dag_camcheck's convention table reflects live engine state.
    if (cam) {
        CamDiag d = {};
        d.present = dag::safemem::ReadFloat3(cam, 0x48, d.engEye);
        (void)dag::safemem::ReadFloat (cam, 0x54, d.dist);
        (void)dag::safemem::ReadFloat3(cam, 0x70, d.basis);
        (void)dag::safemem::ReadFloat3(cam, 0xC4, d.lookAt);
        _lastDiag = d;
    }

    // Phase A gate: vt[0x58] eye/target substitution is parked. We keep
    // the hook installed (needed for other diagnostics and for future
    // activation) but bypass the override block when vt58_override is
    // false. Everything just passes through.
    if (!cfg.camera.enabled || !cfg.camera.vt58_override || !cam || !newPos || !outPos) {
        if (_OriginalCommit) _OriginalCommit(self, slotToken, newPos, outPos);
        return;
    }

    float lookAt[3] = {};
    if (!dag::safemem::ReadFloat3(cam, 0xC4, lookAt)) {
        if (_OriginalCommit) _OriginalCommit(self, slotToken, newPos, outPos);
        return;
    }

    // Identity gate: only override commits for the gameplay cam we've
    // identified. Everything else (minimap, UI, dialog, cutscene, etc.)
    // passes through untouched. Re-resolve on pointer change.
    const bool isOurCam = _gameplayValid && (cam == _gameplayCamPtr);
    if (!isOurCam) {
        // Try to (re-)identify: this cam's live cam[0xC4] must match
        // Lua gt (controlled char Translate) within 5 cm.
        if (!gtOk) {
            if (_OriginalCommit) _OriginalCommit(self, slotToken, newPos, outPos);
            return;
        }
        const float dx = lookAt[0] - gt.x;
        const float dz = lookAt[2] - gt.z;
        const float distXZ = std::sqrt(dx * dx + dz * dz);
        if (distXZ > 0.05f) {
            // Not a plausible match for the controlled char — pass through.
            if (_OriginalCommit) _OriginalCommit(self, slotToken, newPos, outPos);
            return;
        }
        _gameplayCamPtr = cam;
        _headOff        = lookAt[1] - gt.y;
        _gameplayValid  = true;
        dag::log::Writef(
            "HookCommit: identified gameplay cam=%p headOff=%.3f (lookAt.y=%.3f gt.y=%.3f)",
            cam, _headOff, lookAt[1], gt.y);
        // fall through and override this call
    }

    // Drift guard on the identified cam: if cam[0xC4] has moved more
    // than 2 m from gt horizontally (char switched, cam mode changed),
    // unlatch and pass this call through. Re-identify on next match.
    if (gtOk) {
        const float dx = lookAt[0] - gt.x;
        const float dz = lookAt[2] - gt.z;
        const float distXZ = std::sqrt(dx * dx + dz * dz);
        if (distXZ > 2.0f) {
            const DWORD now = GetTickCount();
            if (now - _lastDriftLogMs > 2000) {
                _lastDriftLogMs = now;
                dag::log::Writef(
                    "HookCommit: gameplay cam[0xC4] drifted %.2f m -- unlatching",
                    distXZ);
            }
            _gameplayValid = false;
            if (_OriginalCommit) _OriginalCommit(self, slotToken, newPos, outPos);
            return;
        }
    }

    // Eye: live, zero-lag. cam[0xC4].y - headOff = char feet; add eye_height.
    const float h = (cfg.camera.debug_lift_m > 0.0f)
                    ? cfg.camera.debug_lift_m
                    : cfg.camera.eye_height;
    const float myEye[3] = {
        lookAt[0],
        lookAt[1] - _headOff + h,
        lookAt[2],
    };

    // Horizontal forward from the engine's own basis (cam[0x70..0x78]).
    // Per LERP formula local_508 = cam[0x48] + cam[0x54] * cam[0x70],
    // basis points pivot -> eye, i.e. away from where the camera looks.
    // World forward = -basis. Flatten to XZ and renormalize (pitch=0
    // this build; mouse pitch comes once this horizontal pin confirms).
    float basis[3] = {};
    (void)dag::safemem::ReadFloat3(cam, 0x70, basis);
    float fx = -basis[0], fz = -basis[2];
    const float fh = std::sqrt(fx * fx + fz * fz);
    if (fh > 1e-4f) { fx /= fh; fz /= fh; }
    else            { fx = 0.0f; fz = 1.0f; }

    const float myTarget[3] = {
        myEye[0] + fx,
        myEye[1],
        myEye[2] + fz,
    };

    // Diagnostics
    g_desiredPos[0] = myEye[0];
    g_desiredPos[1] = myEye[1];
    g_desiredPos[2] = myEye[2];
    g_desiredForward[0] = fx;
    g_desiredForward[1] = 0.0f;
    g_desiredForward[2] = fz;
    g_desiredSet = true;

    // Pass our OWN local buffers as the eye and target args. No writes
    // to cam memory. _OriginalCommit builds InvViewMatrix from
    // lookAt(myEye, myTarget) and publishes it; our buffers are
    // discarded on return.
    float eyeBuf[3]    = { myEye[0], myEye[1], myEye[2] };
    float targetBuf[3] = { myTarget[0], myTarget[1], myTarget[2] };
    if (_OriginalCommit) {
        _OriginalCommit(self, slotToken, eyeBuf, targetBuf);
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

    char line[1024];
    const int len = std::snprintf(line, sizeof(line),
        "cam=%p calls=%llu "
        "engEye=%.3f,%.3f,%.3f dist=%.3f basis=%.3f,%.3f,%.3f lookAt=%.3f,%.3f,%.3f "
        "ourEye=%.3f,%.3f,%.3f ourFwd=%.3f,%.3f,%.3f "
        "pitch=%.3f t=%u\n",
        s.cam, (unsigned long long)s.count,
        _lastDiag.engEye[0], _lastDiag.engEye[1], _lastDiag.engEye[2],
        _lastDiag.dist,
        _lastDiag.basis[0],  _lastDiag.basis[1],  _lastDiag.basis[2],
        _lastDiag.lookAt[0], _lastDiag.lookAt[1], _lastDiag.lookAt[2],
        g_desiredPos[0], g_desiredPos[1], g_desiredPos[2],
        g_desiredForward[0], g_desiredForward[1], g_desiredForward[2],
        dag::hooks::mouselook::GetPitchRad(),
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

    // Phase D (consolidated): install the vt[0x58] hook once. All pin
    // logic now lives in HookCommit so no state crosses frames here.
    TryInstallVt58(scene);
    dag::pov::OnFrame(cameraSlot ? cameraSlot[6] : nullptr);

    // Instant-follow: write large values to the CameraDefinition's
    // follow-damping fields so the engine's `pos += damp*dt*(target-pos)`
    // lerp converges in one frame. Save/restore around the chain so
    // NCT and anything else downstream sees vanilla values.
    const auto&  cfg_pre      = dag::config::Get();
    float        origDamp[3]  = { 0, 0, 0 };
    void*        camDef       = nullptr;
    const bool   doInstantFollow =
        cfg_pre.camera.enabled && cfg_pre.camera.instant_follow &&
        _GetCurrentCameraDefinition && cameraSlot && cameraSlot[6];
    if (doInstantFollow) {
        __try {
            camDef = _GetCurrentCameraDefinition(cameraSlot[6]);
        } __except (EXCEPTION_EXECUTE_HANDLER) { camDef = nullptr; }
    }
    if (camDef) {
        auto* d = reinterpret_cast<uint8_t*>(camDef);
        std::memcpy(&origDamp[0], d + dag::offsets::kCamDefFollowDamp0, 4);
        std::memcpy(&origDamp[1], d + dag::offsets::kCamDefFollowDamp1, 4);
        std::memcpy(&origDamp[2], d + dag::offsets::kCamDefFollowDamp2, 4);
        const float big = 100000.f;
        std::memcpy(d + dag::offsets::kCamDefFollowDamp0, &big, 4);
        std::memcpy(d + dag::offsets::kCamDefFollowDamp1, &big, 4);
        std::memcpy(d + dag::offsets::kCamDefFollowDamp2, &big, 4);
    }

    if (_UpdateCamera) {
        _UpdateCamera(scene, ctx, frameInfo, cameraSlot);
    }

    // Restore damping values so NCT's own hooks (and the next frame's
    // vanilla state) see unchanged CameraDefinition.
    if (camDef) {
        auto* d = reinterpret_cast<uint8_t*>(camDef);
        std::memcpy(d + dag::offsets::kCamDefFollowDamp0, &origDamp[0], 4);
        std::memcpy(d + dag::offsets::kCamDefFollowDamp1, &origDamp[1], 4);
        std::memcpy(d + dag::offsets::kCamDefFollowDamp2, &origDamp[2], 4);
    }

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

    // LEGACY STEP-C-STYLE WRITE — parked (Phase 0).
    //
    // Writes Y + eye_height into kCamWorldPosY = 0x4c. Per NCT's
    // CameraObject layout (reference/BG3_NativeCameraTweaks/src/RE/
    // Camera.h), offset 0x4c is `currentZoomB` (a zoom scalar), NOT the
    // Y of the camera world position. This write modifies zoom, which
    // is why the previous session's "wrote=(x, char.y+4, z)" never
    // moved InvViewMatrix. Gated behind cfg.camera.legacy_y_write
    // (default false) so a stale TOML can't silently turn it back on.
    bool wrote = false;
    float wx = xEng, wy = yEng, wz = zEng;
    if (cfg.camera.enabled && cfg.camera.legacy_y_write && gtOk && cam) {
        const float h = (cfg.camera.debug_lift_m > 0.0f)
                        ? cfg.camera.debug_lift_m
                        : cfg.camera.eye_height;
        wy = yEng + h;
        std::memcpy(reinterpret_cast<uint8_t*>(cam) + dag::offsets::kCamWorldPosY, &wy, 4);
        wrote = true;
        if (stat) {
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

    // LEGACY MOUSELOOK FORWARD WRITE — parked (Phase 0).
    //
    // Writes to kCamForward{X,Y,Z} = 0x70/0x74/0x78. Per NCT's layout,
    // 0x70 is `fltmax_70` (a sentinel float) and `cameraRotation` is a
    // Vector3 starting at 0x74. So this write puts fx into the sentinel,
    // fy into cameraRotation.x, fz into cameraRotation.y — the Z of the
    // rotation never gets touched. Mouselook via this path can't aim
    // correctly. Gated behind cfg.camera.legacy_forward_write (default
    // false). Phase 1 picks fresh offsets.
    if (cfg.mouselook.enabled && cfg.camera.legacy_forward_write &&
        gtOk && wrote && cam) {
        float yaw   = dag::hooks::mouselook::GetYawRad();
        float pitch = dag::hooks::mouselook::GetPitchRad();
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

    // ---------------- Phase 1 read-only probe (2026-10-08) ----------------
    //
    // Logs cam[0x18], cam[0x24], cam[0x74..0x7F] (cameraRotation) and
    // cam[0xC4] alongside Lua ground truth. Read-only. Fires every ~50 ms
    // (small enough to catch a sub-frame lerp if it exists) and also
    // whenever root/desired diverge by > 5 cm (so the exact moment of
    // divergence lands in the log even if we never fire on a slow tick).
    //
    // Hypotheses from NCT's RE/Camera.h:
    //   - cam[0x18] = cameraRootPos         (the LERPED pivot)
    //   - cam[0x24] = desiredCameraRootPos  (pre-lerp target)
    //   - cam[0x74] = cameraRotation        (direction from pivot to eye)
    //   - cam[0xC4] = cameraPos             (final rendered eye)   -- but
    //     the first probe pass showed cam[0xC4] = char.Translate (feet
    //     level, no eye-height offset), so cam[0xC4] is really the look-at
    //     TARGET. Keep probing it alongside the others as a sanity check.
    //
    // At zoom = 0 (NCT ExplorationZoomMin = 0.0) the rendered eye =
    // cam[0x18] exactly (confirmed by the first probe round). Writing
    // cam[0x18] therefore moves the rendered eye deterministically —
    // that's the write path Phase 1 will use.
    //
    // What we're trying to answer this round:
    //   1. Do cam[0x18] and cam[0x24] ever differ during motion? If yes,
    //      cam[0x24] is the pre-lerp target and we have to inject BOTH
    //      cam[0x18] and cam[0x24] post-chain to keep our offset.
    //   2. If no (they're always identical), the follow lag lives in a
    //      different field — probably on the character or a per-tick
    //      blended buffer the engine reads instead of either of these.
    static DWORD _lastProbeLogMs      = 0;
    static float _lastRoot[3]         = { 0, 0, 0 };
    static float _lastDesired[3]      = { 0, 0, 0 };
    if (cam) {
        float root[3]    = {};
        float desired[3] = {};
        float rot[3]     = {};
        float eye[3]     = {};
        const bool rOk = dag::safemem::ReadFloat3(cam, 0x18, root);
        const bool dOk = dag::safemem::ReadFloat3(cam, 0x24, desired);
        const bool wOk = dag::safemem::ReadFloat3(cam, 0x74, rot);
        const bool eOk = dag::safemem::ReadFloat3(cam, 0xC4, eye);
        // Divergence between root and desired (XZ only — Y is the eye
        // height which is static per character). If > 5 cm, log loud.
        float divXZ = 0.0f;
        if (rOk && dOk) {
            const float dx = root[0] - desired[0];
            const float dz = root[2] - desired[2];
            divXZ = std::sqrt(dx * dx + dz * dz);
        }
        const bool divergent = (divXZ > 0.05f);
        const bool dueByTime = (now - _lastProbeLogMs) >= 5000;  // was 50 ms: log spam
        if (dueByTime) {
            _lastProbeLogMs = now;
            dag::log::Writef(
                "PhaseProbe cam=%p root=(%.3f,%.3f,%.3f)%s desired=(%.3f,%.3f,%.3f)%s rot=(%.3f,%.3f,%.3f)%s eye[0xC4]=(%.3f,%.3f,%.3f)%s gt=(%.3f,%.3f,%.3f) %s divXZ=%.3f%s",
                cam,
                root[0], root[1], root[2],         rOk ? "" : "?",
                desired[0], desired[1], desired[2], dOk ? "" : "?",
                rot[0], rot[1], rot[2],             wOk ? "" : "?",
                eye[0], eye[1], eye[2],             eOk ? "" : "?",
                gt.x, gt.y, gt.z,
                gtOk ? "gtOK" : "gtSTALE",
                divXZ, divergent ? " DIVERGENT" : "");
            // Also update the probe status file so Lua !dag_camcheck can
            // pull the latest line without parsing native.log.
            wchar_t base[MAX_PATH];
            const DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH);
            if (n > 0 && n < MAX_PATH) {
                wchar_t full[MAX_PATH * 2];
                swprintf_s(full, L"%s\\Larian Studios\\Baldur's Gate 3\\Script Extender\\DarkAndGate\\native-phase-probe.txt", base);
                char line[768];
                const int len = std::snprintf(line, sizeof(line),
                    "cam=%p root=%.3f,%.3f,%.3f desired=%.3f,%.3f,%.3f rot=%.3f,%.3f,%.3f eye=%.3f,%.3f,%.3f gt=%.3f,%.3f,%.3f gtOk=%d divXZ=%.3f t=%u\n",
                    cam, root[0], root[1], root[2],
                    desired[0], desired[1], desired[2],
                    rot[0], rot[1], rot[2],
                    eye[0], eye[1], eye[2],
                    gt.x, gt.y, gt.z,
                    gtOk ? 1 : 0, divXZ, (unsigned)now);
                HANDLE h = CreateFileW(full, GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                                       CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
                if (h != INVALID_HANDLE_VALUE) {
                    DWORD written = 0;
                    WriteFile(h, line, len, &written, nullptr);
                    CloseHandle(h);
                }
            }
        }
        if (rOk) { _lastRoot[0]    = root[0];    _lastRoot[1]    = root[1];    _lastRoot[2]    = root[2]; }
        if (dOk) { _lastDesired[0] = desired[0]; _lastDesired[1] = desired[1]; _lastDesired[2] = desired[2]; }
    }
    // ---------------- end Phase 1 read-only probe ----------------

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

    // Resolve GetCurrentCameraDefinition for instant_follow (NCT's path).
    if (uint8_t* gcd = dag::patternscan::Find(nullptr,
            dag::offsets::kGetCurrentCameraDefinitionPattern)) {
        _GetCurrentCameraDefinition = reinterpret_cast<GetCamDefFn>(gcd);
        dag::log::Writef("InstantFollow: GetCurrentCameraDefinition at %p", gcd);
    } else {
        dag::log::Writef(
            "InstantFollow: GetCurrentCameraDefinition pattern not found -- feature disabled");
    }

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
