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

constexpr uint32_t kCamStructProbes[] = {
    0x30, 0x60, 0xA0, 0xB0, 0xC0, 0x100, 0x120, 0x160, 0x1A0, 0x200,
};
constexpr uint32_t kBehaviorProbes[] = {
    dag::offsets::kBehaviorTargetDestinationHigh,  // 0x30 — primary
    dag::offsets::kBehaviorTargetDestination,       // 0x24
    dag::offsets::kBehaviorTargetCurrent,           // 0x48
    dag::offsets::kBehaviorTargetCurrentLow,        // 0x3C
};

constexpr float kCalibTolerance = 0.05f;      // match ground truth within 5 cm
constexpr float kDivergeTolerance = 1.00f;    // un-latch if we're off by >1 m

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

void Hook_UpdateCamera(void* scene, void** ctx,
                       uintptr_t frameInfo, void** cameraSlot)
{
    // Config live-reload once per second (cheap mtime stat).
    const DWORD now = GetTickCount();
    if (now - _lastConfigPollMs > 1000) {
        _lastConfigPollMs = now;
        dag::config::PollAndReload();
        dag::groundtruth::Poll();
    }

    if (_UpdateCamera) {
        _UpdateCamera(scene, ctx, frameInfo, cameraSlot);
    }

    const auto& cfg = dag::config::Get();
    const auto  gt  = dag::groundtruth::Get();

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
    const bool gtOk = gt.active && !gt.stale;

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

    // Pin: write cam.x = char.x, cam.y = char.y + eye_height, cam.z = char.z
    // Only for calibrated gameplay cams, only while gt active.
    bool wrote = false;
    float wx = xEng, wy = yEng, wz = zEng;
    if (cfg.camera.enabled && gtOk && stat &&
        (stat->kind == ProbeKind::Behavior || stat->kind == ProbeKind::CamStruct)) {
        float live[3] = {};
        if (ReadLiveCharPos(stat, live)) {
            stat->lastCharX = live[0];
            stat->lastCharY = live[1];
            stat->lastCharZ = live[2];
            const float h = (cfg.camera.debug_lift_m > 0.0f)
                            ? cfg.camera.debug_lift_m
                            : cfg.camera.eye_height;
            wx = live[0];
            wy = live[1] + h;
            wz = live[2];
            if (cam) {
                std::memcpy(reinterpret_cast<uint8_t*>(cam) + dag::offsets::kCamWorldPosX, &wx, 4);
                std::memcpy(reinterpret_cast<uint8_t*>(cam) + dag::offsets::kCamWorldPosY, &wy, 4);
                std::memcpy(reinterpret_cast<uint8_t*>(cam) + dag::offsets::kCamWorldPosZ, &wz, 4);
                wrote = true;
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
        for (size_t i = 0; i < _numCams; ++i) {
            const auto& s = _cams[i];
            if (s.kind != ProbeKind::Behavior && s.kind != ProbeKind::CamStruct) continue;
            dag::log::Writef(
                "  cam[%zu]=%p calls=%llu src=%s off=0x%X char=(%.2f,%.2f,%.2f) eng=(%.2f,%.2f,%.2f) wrote=%d",
                i, s.cam, (unsigned long long)s.count,
                s.kind == ProbeKind::Behavior ? "beh" : "cam",
                s.winningOffset,
                s.lastCharX, s.lastCharY, s.lastCharZ,
                s.lastEngX,  s.lastEngY,  s.lastEngZ,
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
