// SPDX-License-Identifier: GPL-3.0-or-later
//
// Real jump: the controlled character's actual position follows our jump
// curve. See docs/spikes/real-lift.md (static RE, bg3_dx11.exe Patch 8).
//
// We push the client movement machine's Falling state (type 6) the way
// the engine does when you walk off a ledge, then hook its Update: every
// frame, before the original runs, we rewrite its Start / Velocity / t so
// the engine's own integrator lands exactly on our point (height from the
// curve, horizontal from take-off momentum + WASD). The original then
// writes the real TransformComponent, probes the ground and lands the
// character (on a crate, a ledge...) and the client reports the fall to
// the server. After the curve ends we hand the state back to the engine,
// which keeps falling with gravity if we are above the ground.

#pragma once

#include <cstdint>

namespace dag::realjump {

// Pattern scans (GetState, Falling vtable check). Call once at DLL load.
void Install();

// Remember the WASD-driven character (ecl::Character*), validated by vtable.
void NoteCharacter(void* character);

// Per frame: measure the character's horizontal velocity (take-off inertia).
void MeasureFrame();

// +1 / -1: which way A/D steer in the air (checked in-game).
void SetStrafeSign(float s);

// Start a real jump now (game thread). Returns false (and logs why) if the
// engine state couldn't be entered; the caller then falls back to the
// visual lift. curve: y = h * (1 - |2u - 1|^k), u = t / durMs.
bool Start(float durMs, float h, float k, const float camFwdXZ[2], int seq);

// Camera forward (XZ, normalised) for WASD steering; call every frame.
void SetCameraForward(float fx, float fz);

bool Active();
const char* State();

}  // namespace dag::realjump
