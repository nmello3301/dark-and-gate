// SPDX-License-Identifier: GPL-3.0-or-later
//
// Visual-only body lift for the first-person jump.
// See docs/spikes/m1b-visual-lift.md.
//
// The player's rf Visual gets its world position from the engine through
// vtable slots 2 (SetWorldTranslate), 5 (SetWorldTransform(Transform)) and
// 6 (SetWorldTransform(t, r, s)); each pushes the transform down to every
// renderable and attachment. We patch those slots on the player Visual's
// vtable and add the lift to Y when `this` is the player Visual, so the
// engine's own write carries the lift whatever order systems run in.
// While the engine is not writing (standing still), Refresh() re-applies
// base + lift once per frame from the camera hook.
//
// Client-side and cosmetic only: server, physics and pathing never read
// the client Visual. Other players don't see the lift.

#pragma once

#include <cstdint>

namespace dag::visuallift {

// Lua's Visual address (0 = none). Validates and patches the vtable the
// first time a given vtable is seen. Cheap to call every frame.
void SetVisual(uintptr_t visual);

// Lift in metres for this frame (0 = none).
void SetLift(float lift);

// Called once per frame from the camera hook, after SetLift.
void Refresh();

// 2026-10-09: while walking the engine writes the Visual through our hook
// (lift added) yet the mesh stayed down. Force = also re-apply the lift in
// Refresh right after an engine write (Pov.cpp turns it on when it sees
// the mesh not following).
void SetForce(bool on);
bool Forced();

// True when the vtable hooks are live on the current Visual, i.e. the
// whole body (and so the head bone) carries the lift.
bool BodyLiftActive();

// Short state for the status line: "body", "camera-only" or "off".
const char* Mode();

// Lift actually on the player Visual right now (its Y minus the engine's
// unlifted Y). The camera adds (wanted - applied) so it always rises the
// full amount, even on frames where the body lift was overwritten.
float AppliedLift();

// Per-jump counters, logged by Pov at jump end, then reset:
//   hook     engine writes that went through our vtable hooks (lifted)
//   refresh  writes we made from the camera hook (standing still)
//   ext      frames where the Visual held a value nobody wrote through
//            our hooks -- an engine path that bypasses them (re-lifted)
void TakeStats(int& hook, int& refresh, int& ext);

}  // namespace dag::visuallift
