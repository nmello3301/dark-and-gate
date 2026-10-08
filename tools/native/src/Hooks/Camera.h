// SPDX-License-Identifier: GPL-3.0-or-later
//
// Installs Hook_UpdateCamera on the call-site at bg3.exe +0xe0c9bc.
// See docs/spikes/m1a-camera-follow.md for the design and the
// zero-frame-lag reasoning.
//
// Install flow:
//   1. Pattern-scan to find the anchor (`48 8D 8D F8 04 00 00 E8 ... E9 AF FD FF FF`).
//   2. The CALL is 5 bytes before the anchor.
//   3. Check the current CALL target: if it's not the known-good
//      FUN_141e0f110-reachable code, log that we're chaining through
//      another mod (NCT, typically).
//   4. patternscan::WriteCall5(callSite, Hook_UpdateCamera) rewires the
//      CALL and returns the previous target as _UpdateCamera.

#pragma once

namespace dag::hooks::camera {

// Install the hook. Returns true on success. Must be called once, on
// DLL load, before any game thread has reached the camera call-site.
// Safe to call even when camera.enabled=false in the config — the hook
// no-ops until the config is flipped (so the dev can tune without a
// game restart once hot-reload lands).
bool Install();

// Uninstall is not supported yet; the hook stays until process exit.

}  // namespace dag::hooks::camera
