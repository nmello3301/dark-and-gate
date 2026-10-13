// SPDX-License-Identifier: GPL-3.0-or-later
//
// Player WASD ground speed. See docs/spikes/move-speed.md (static RE,
// bg3_dx11.exe Patch 8).
//
// The client MoveController's per-frame WASD update fetches the
// character's effective template and reads MovementSpeedStroll (+0x590)
// and MovementSpeedRun (+0x5a0); the ground speed is the lerp
//   speed = Stroll + t * (Run - Stroll),  t = (clamp(mag, 0.1, 0.9) - 0.1) / 0.8
// where mag is the input magnitude (BG3WASD's walk = its WalkSpeed, run =
// 1). We hook that one template-fetch call and hand back a small block
// with our own Stroll / Run, chosen so walking moves at walkMult x the
// natural walk speed and running at runMult x Run. Only the WASD-driven
// character on this client is affected; the shared template is untouched.

#pragma once

namespace dag::movespeed {

// Pattern-scan + call-site patch. Call once at DLL load.
void Install();

// Effective multipliers from Lua (1 = vanilla). Cheap; call every frame.
void Set(float walkMult, float runMult);

// For the status line: "ok" / "failed: ..." / "not installed".
const char* State();

// Direct move mode (MoveFeel.cpp, docs/spikes/move-feel.md): while >= 0 the
// hook hands back Stroll = Run = mps, so the WASD update moves at exactly
// that speed whatever the input magnitude. -1 = off (the multipliers above).
void SetDirectSpeed(float mps);

// The speed vanilla WASD would give with the current multipliers: the walk
// (BG3WASD's walk lerp x walkMult) or the run (Run x runMult), in m/s.
// Human defaults until the hook has seen the character's template.
float NaturalSpeed(bool walking);

// Last values seen in the hook: template Stroll / Run, BG3WASD's walk
// lerp t, our Stroll' / Run', and how many calls since install.
void Read(float& stroll, float& run, float& tWalk, float& strollOut, float& runOut, long& calls);

}  // namespace dag::movespeed
