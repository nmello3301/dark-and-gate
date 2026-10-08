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

// Convert (yaw, pitch) in RADIANS to a right-handed Y-up forward unit
// vector. Yaw=0 means +Z (into the screen for the default BG3 camera);
// yaw=+pi/2 means +X (east). Pitch=+pi/2 means looking straight up.
//
// If BG3 turns out to be left-handed Y-up (DirectX convention), flip
// the Z sign; captured as a TODO in offsets.h once we read a known
// camera forward from a frozen scene.
struct Vec3 { float x, y, z; };

Vec3 YawPitchToForwardYUp(float yawRad, float pitchRad)
{
    const float cp = std::cos(pitchRad);
    const float sp = std::sin(pitchRad);
    const float cy = std::cos(yawRad);
    const float sy = std::sin(yawRad);
    return { cp * sy, sp, cp * cy };
}

// Read the character's render-interpolated position. STUB for the first
// compile — returns false so the hook no-ops safely until the offsets
// land (see Offsets.h "PLACEHOLDERS").
bool ReadCharVisualPos(void* /*character*/, Vec3* /*out*/)
{
    // TODO: resolve kCharVisualComponentPtr + kVisualTransformPos via a
    // targeted Ghidra pass; replace this stub with the real reads.
    return false;
}

// Overwrite cam[] with our pin values. Y-up: y receives the eye offset.
void WriteCameraPin(float* cam, const Vec3& charPos, float eyeHeight,
                    const Vec3& fwd, float pitchRad)
{
    using namespace dag::offsets;

    auto writeFloat = [cam](uint32_t off, float f) {
        std::memcpy(reinterpret_cast<uint8_t*>(cam) + off, &f, sizeof(f));
    };

    writeFloat(kCamWorldPosX, charPos.x);
    writeFloat(kCamWorldPosY, charPos.y + eyeHeight);  // Y is up
    writeFloat(kCamWorldPosZ, charPos.z);

    writeFloat(kCamForwardX, fwd.x);
    writeFloat(kCamForwardY, fwd.y);
    writeFloat(kCamForwardZ, fwd.z);

    // Pin SLERP target to the same vector so the next frame doesn't
    // drift back toward the engine's own camera forward.
    writeFloat(kCamSlerpTgtX, fwd.x);
    writeFloat(kCamSlerpTgtY, fwd.y);
    writeFloat(kCamSlerpTgtZ, fwd.z);

    writeFloat(kCamPitch, pitchRad);
}

// Optionally re-commit the camera transform via the CameraSystem's
// vt[0x58]. Belt-and-braces for the mirror-cache case documented in
// m1a-camera-follow.md § Commit timing. First compile: STUB.
void RecommitCameraSlot(void* /*scene*/, void** /*cameraSlot*/, float* /*cam*/)
{
    // TODO: reconstruct the SlotToken and invoke vt[0x58]. Needs a
    // decomp of the scene vtable; harmless to omit for the first
    // smoke test — if a mirror exists, the camera will lag one frame
    // and that tells us to flip this on.
}

void Hook_UpdateCamera(void* scene, void** ctx,
                       uintptr_t frameInfo, void** cameraSlot)
{
    // 1. Let the engine (and NCT, if present) do their work. This also
    //    advances the engine's own camera state the game relies on
    //    (sound listener, companion placement, HUD anchors).
    if (_UpdateCamera) {
        _UpdateCamera(scene, ctx, frameInfo, cameraSlot);
    }

    const auto& cfg = dag::config::Get();
    if (!cfg.camera.enabled) return;

    if (!cameraSlot) return;
    auto* cam = reinterpret_cast<float*>(cameraSlot[6]);
    if (!cam) return;

    void* character = *reinterpret_cast<void**>(
        reinterpret_cast<uint8_t*>(cam) + dag::offsets::kCamActiveCharPtr);
    if (!character) return;

    Vec3 charPos{};
    if (!ReadCharVisualPos(character, &charPos)) return;  // stub says no

    const float eyeHeight = cfg.camera.eye_height_default;  // race lookup TODO

    const float yaw   = dag::hooks::mouselook::GetYawRad();
    const float pitch = dag::hooks::mouselook::GetPitchRad();
    const Vec3 fwd    = YawPitchToForwardYUp(yaw, pitch);

    WriteCameraPin(cam, charPos, eyeHeight, fwd, pitch);

    if (cfg.camera.recommit_vt58) {
        RecommitCameraSlot(scene, cameraSlot, cam);
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
