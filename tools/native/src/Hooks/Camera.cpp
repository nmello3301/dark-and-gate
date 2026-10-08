// SPDX-License-Identifier: GPL-3.0-or-later

#include "Camera.h"

#include <windows.h>

#include <cmath>
#include <cstdint>

#include "../Config.h"
#include "../Log.h"
#include "../Offsets.h"
#include "../PatternScan.h"
#include "Mouselook.h"

namespace dag::hooks::camera {

namespace {

// Original CALL target captured during Install(). May be NCT's
// trampoline if NCT loaded first; chain through it either way.
using UpdateCameraFn = void (*)(void*, void**, uintptr_t, void**);
UpdateCameraFn _UpdateCamera = nullptr;

void Hook_UpdateCamera(void* scene, void** ctx,
                       uintptr_t frameInfo, void** cameraSlot)
{
    // 1. Let the engine (and NCT, if present) do their work. On exit,
    //    cam[0x48..0x50] holds the engine's answer to "where should the
    //    camera be this frame" -- which, with NCT's offsets zeroed, is
    //    the character's render-interpolated position. See
    //    docs/spikes/m1a-camera-follow.md § "Character position source"
    //    for why we read it this way instead of walking the character's
    //    components ourselves.
    if (_UpdateCamera) {
        _UpdateCamera(scene, ctx, frameInfo, cameraSlot);
    }

    const auto& cfg = dag::config::Get();
    if (!cfg.camera.enabled) return;

    if (!cameraSlot) return;
    auto* cam = reinterpret_cast<float*>(cameraSlot[6]);
    if (!cam) return;

    using namespace dag::offsets;
    auto readFloat = [cam](uint32_t off) {
        float v;
        std::memcpy(&v, reinterpret_cast<uint8_t*>(cam) + off, sizeof(v));
        return v;
    };
    auto writeFloat = [cam](uint32_t off, float v) {
        std::memcpy(reinterpret_cast<uint8_t*>(cam) + off, &v, sizeof(v));
    };

    // 2. Pin Y to eye-height above the engine's chosen base. X and Z
    //    stay what the engine (and whatever's chained before us) picked
    //    for the frame -- that's the lateral camera-follow we want.
    const float baseY = readFloat(kCamWorldPosY);
    writeFloat(kCamWorldPosY, baseY + cfg.camera.eye_height);

    // 3. Forward / pitch override lives in Mouselook; while that's
    //    scaffold (mouselook.enabled=false), we leave the engine's
    //    forward untouched so camera rotation still works via vanilla
    //    middle-mouse-drag or NCT's input binding.

    // 4. Optional re-commit via vt[0x58]: harmless no-op for now (the
    //    helper is still a stub). Flagged off until we have evidence of
    //    a mirror-cache; see spike doc § "Commit timing".
    (void)cfg.camera.recommit_vt58;
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
            "Camera: anchor found but preceding byte is %02X, not E8 — abort",
            callSite[0]);
        return false;
    }

    uint8_t* current = dag::patternscan::DecodeRelCallTarget(callSite);
    dag::log::Writef(
        "Camera: anchor at %p, CALL at %p -> current target %p",
        anchor, callSite, current);

    // Our DLL may be loaded >2GB from bg3.exe, so a plain 5-byte CALL
    // can't reach Hook_UpdateCamera directly. InstallFarCall5 allocates
    // a 12-byte near-stub (MOV RAX, abs64; JMP RAX) within ±2GB of the
    // call-site, then rewrites the CALL to the stub.
    uint8_t* previous = dag::patternscan::InstallFarCall5(
        callSite, reinterpret_cast<void*>(&Hook_UpdateCamera));
    if (!previous) {
        dag::log::Writef("Camera: InstallFarCall5 failed (no free pages within +/- 2GB of callsite?)");
        return false;
    }
    _UpdateCamera = reinterpret_cast<UpdateCameraFn>(previous);

    // Report whether we chained through another mod. The captured
    // target is often a VirtualAlloc'd trampoline (NCT uses the same
    // pattern we do), which won't belong to any module. Follow one
    // absolute-JMP level (48 B8 <abs64> FF E0, exactly the stub shape
    // we also emit) if the first lookup lands on a non-module page.
    auto resolveModuleName = [](uint8_t* addr, char* out, size_t cap) -> HMODULE {
        HMODULE mod = nullptr;
        GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(addr),
            &mod);
        if (!mod) { out[0] = 0; return nullptr; }
        wchar_t wname[MAX_PATH] = {};
        GetModuleFileNameW(mod, wname, MAX_PATH);
        const wchar_t* base = wname;
        for (const wchar_t* p = wname; *p; ++p) {
            if (*p == L'\\' || *p == L'/') base = p + 1;
        }
        WideCharToMultiByte(CP_UTF8, 0, base, -1, out, static_cast<int>(cap), nullptr, nullptr);
        return mod;
    };

    uint8_t*  trampTarget = previous;
    char      firstName[MAX_PATH]  = {};
    char      finalName[MAX_PATH]  = {};
    HMODULE   firstMod  = resolveModuleName(previous, firstName, sizeof(firstName));

    // If first lookup landed on a VirtualAlloc page, try following
    // the 10-byte trampoline shape to the real target.
    if (!firstMod && previous[0] == 0x48 && previous[1] == 0xB8 &&
                     previous[10] == 0xFF && previous[11] == 0xE0) {
        void* abs = nullptr;
        std::memcpy(&abs, previous + 2, sizeof(abs));
        trampTarget = static_cast<uint8_t*>(abs);
    }
    HMODULE finalMod = resolveModuleName(trampTarget, finalName, sizeof(finalName));

    HMODULE   mainExe   = GetModuleHandleW(nullptr);
    const bool chained  = (finalMod && finalMod != mainExe);
    const char* via     = finalName[0] ? finalName
                        : (firstName[0] ? firstName : "<trampoline, module unresolved>");
    dag::log::Writef(
        "Camera: hook installed. _UpdateCamera -> %p (%s via %s)",
        _UpdateCamera,
        chained ? "chained" : (finalMod ? "direct engine target" : "unresolved"),
        via);
    return true;
}

}  // namespace dag::hooks::camera
