// SPDX-License-Identifier: GPL-3.0-or-later
//
// All byte patterns and resolved addresses live here.
// If a Ghidra pass changes a pattern, this is the one file that needs
// updating. Every pattern is cross-checked against bg3.exe Patch 8 via
// GhidraMCP; see docs/spikes/m1a-camera-follow.md for the chain of
// confidence.
//
// Image base of bg3.exe (per Ghidra): 0x140000000. Patterns here are
// matched against the running module base (GetModuleHandle(nullptr)).

#pragma once

#include <cstdint>
#include <string_view>

namespace dag::offsets {

// -----------------------------------------------------------------------
// Camera hook anchors (NCT's set; all unique one-hits in Patch 8 bg3.exe).
// -----------------------------------------------------------------------

// The 5-byte CALL immediately preceding `48 8D 8D F8 04 00 00 ...` is the
// UpdateCamera call-site. DKUtil-style scan: match the LEA + CALL + JMP
// shape, then the hook target is the first `E8 ?? ?? ?? ??` at offset -5.
constexpr std::string_view kUpdateCameraAnchorPattern =
    "48 8D 8D F8 04 00 00 E8 ?? ?? ?? ?? E9 AF FD FF FF";
constexpr int kUpdateCameraCallOffsetFromAnchor = -5;  // bytes

// Secondary anchors — for logging + sanity, not hooked by M1a:
constexpr std::string_view kHandleCameraInputPattern =
    "E8 ?? ?? ?? ?? 0F B7 08 66 89 0B 80 3B 00";
constexpr std::string_view kCalculateCameraPitchPattern =
    "E8 ?? ?? ?? ?? 80 BF 4C 01 00 00 00";
constexpr std::string_view kUpdateCameraPitchPattern =
    "E8 ?? ?? ?? ?? 48 8B 46 70 4C 8D 45 90 0F 28 46 30";
constexpr std::string_view kAfterUpdateCameraZoomPattern =
    "E8 ?? ?? ?? ?? 80 BF 54 02 00 00 00";
constexpr std::string_view kGetCurrentCameraDefinitionPattern =
    "48 8B 05 ?? ?? ?? ?? 80 B8 32 13 00 00 00 74 07";

// -----------------------------------------------------------------------
// Camera object field offsets (bytes from the camera object pointer that
// UpdateCamera writes to). Treated as floats unless stated otherwise.
//
// Confirmed in docs/spikes/m1a-camera-follow.md against FUN_141e0f110's
// final virtual call `(sys, slotTok, &newPos, cam+0x48)` and the SLERP
// code that renormalizes cam+0x70.
// -----------------------------------------------------------------------

constexpr uint32_t kCamWorldPosX  = 0x48;  // float (Y-up world)
constexpr uint32_t kCamWorldPosY  = 0x4c;  // float — this is HEIGHT
constexpr uint32_t kCamWorldPosZ  = 0x50;  // float
constexpr uint32_t kCamPitch      = 0x5c;  // float, radians
constexpr uint32_t kCamForwardX   = 0x70;  // float (unit vec x)
constexpr uint32_t kCamForwardY   = 0x74;  // float (unit vec y)
constexpr uint32_t kCamForwardZ   = 0x78;  // float (unit vec z)
constexpr uint32_t kCamSlerpTgtX  = 0x7c;  // float (SLERP destination)
constexpr uint32_t kCamSlerpTgtY  = 0x80;
constexpr uint32_t kCamSlerpTgtZ  = 0x84;
constexpr uint32_t kCamModeFlags  = 0xa8;  // byte flags, bit0 = combat

// Character pointer carried by the camera. From FUN_141e0f110's SLERP
// branch (`*(longlong **)(pfVar22 + 0x44)` where pfVar22 is float*,
// so byte offset = 0x44 * sizeof(float) = 0x110). The engine's own
// "camera follows this character" state.
constexpr uint32_t kCamActiveCharPtr = 0x110;  // void*
// Secondary slot the SLERP branch tries first; usually null unless a
// look-at target is active. Keep for completeness.
constexpr uint32_t kCamLookAtTargetPtr = 0x120;  // void*

// -----------------------------------------------------------------------
// Character / Visual offsets — PLACEHOLDERS, confirm at implementation.
// `.VisualTransform` / `.VisualTransform3D` strings exist in bg3.exe at
// 0x14531c7b8 / 0x14531c7d0 (reflection); the component layout isn't
// decoded yet. See docs/spikes/m1a-camera-follow.md "Character position
// source".
// -----------------------------------------------------------------------

// Placeholder: offset from character ptr to VisualComponent*. Likely
// close to the Visual field we care about, but needs a one-decomp pass.
constexpr uint32_t kCharVisualComponentPtr = 0x0;  // TODO

// Placeholder: offset from VisualComponent to the vec3 render-interp
// world position (`.VisualTransform.pos`).
constexpr uint32_t kVisualTransformPos = 0x0;      // TODO

}  // namespace dag::offsets
