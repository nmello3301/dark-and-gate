// SPDX-License-Identifier: GPL-3.0-or-later
//
// Mouselook accumulator. Owns the authoritative yaw/pitch in RADIANS
// that Camera.cpp reads each frame.
//
// First commit is a scaffold: GetYaw / GetPitch return 0, Install() is
// a no-op. The real hook (SDL relative mode + game mouse-delta ingest)
// lands after Camera.cpp proves the camera-pin path works in-game. See
// docs/spikes/m1a-camera-follow.md § Mouselook for the scope.

#pragma once

namespace dag::hooks::mouselook {

bool Install();

// Called once per UpdateCamera invocation from Camera.cpp. Owns relative-
// mode toggling + delta accumulation.
void Tick();

// Snapshot engine's current forward direction and convert to yaw/pitch,
// but only if we haven't initialised since last disable. Called from
// Camera.cpp pre-chain to avoid camera snap when mouselook turns on.
void MaybeInitFromForward(float fx, float fy, float fz);

// True once MaybeInitFromForward has run since last disable. Used by
// Camera.cpp to decide whether to override look-at target.
bool IsInitialised();

// If character_facing enabled, writes current yaw to a file that Lua
// polls to call Ext.Entity.SetRotation. Throttled internally.
void MaybeWriteYawForLua();

// Current yaw/pitch in radians. Y-up world. Yaw unbounded; pitch
// clamped to ±89° when the mouse hook is live. In the scaffold both
// return 0.
float GetYawRad();
float GetPitchRad();

// Pause / resume the mouselook accumulator. Called from the UI-state
// hook (BG3WASD-style) when a modal panel or dialogue opens. Mouselook
// is a no-op while paused; the camera hook still runs.
void SetPaused(bool paused);
bool IsPaused();

// GetTickCount() of the last Tick() whose SDL relative-mouse delta was not
// zero (0 = never). Pov.cpp's foreign-camera follow uses it, with its own
// SDL motion-event time, to tell your mouse turns from BG3's own.
unsigned long LastMoveTick();

}  // namespace dag::hooks::mouselook
