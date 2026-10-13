// SPDX-License-Identifier: GPL-3.0-or-later
//
// Direct WASD movement ("direct" move mode) and movement-feel metrics. See
// docs/spikes/move-feel.md (static RE, bg3_dx11.exe Patch 8).
//
// Direct mode keeps BG3's own controller-mode WASD path (the client
// MoveController that BG3WASD unlocks for the keyboard: MoveTo requests,
// nav-grid targets, walls, ground, the client -> server path sync) and
// takes over how it feels:
//   * the input vector the MoveController reads is ours: the direction from
//     the physical keys on our camera's forward (or BG3's own BG3WASD-fed
//     axes with move_input game), and our own velocity (move.accel_time /
//     decel_time) as its speed, handed to the MoveController through
//     MoveSpeed.cpp's direct speed. BG3's axes still gate it (chat, dialogue)
//     and give walk / run;
//   * its 50 ms start delay and its 16 m/s^2 move-target ramp are switched
//     off (two byte patches, put back in vanilla mode);
//   * the client MoveTo step, and the host server's replay of synced paths,
//     move at the requested speed at once instead of the engine's ramped
//     Movement.Speed (two small stubs behind a flag);
//   * the body turns with BG3's own steering by default (move_turn engine).
//     Instant facing (SetRotation) is still a knob, but BG3's steering keeps
//     its own yaw and writes it back, so the two fight (playtest 2, the
//     "body turned by others" check).
// Vanilla mode leaves BG3WASD's movement exactly as it was.

#pragma once

#include <cstddef>

namespace dag::movefeel {

struct Settings {
    bool  direct = false;      // Lua move_mode == direct
    float accelS = 0.06f;      // seconds from standing to full speed (0 = instant)
    float decelS = 0.04f;      // seconds from full speed to standing (0 = instant)
    float turn = 0.f;          // facing: 0 = BG3's own steering (default), -1 instant, > 0 deg/s
    bool  rawInput = true;     // physical W/A/S/D + our camera yaw instead of BG3's axes' direction
    float strafeSign = -1.f;   // raw input: A/D side (the real jump's sign)
    bool  hold = false;        // input released (menus, dialogue, map, downed)
    bool  metrics = false;     // !dag_move_metrics on
};

// Pattern scans, call-site and vtable hooks, stubs. Call once at DLL load,
// after MoveSpeed (its template hook gives the direct speed to the engine).
void Install();

// Every frame (render thread). povLive = first person on, active, not the
// downed orbit. Direct mode runs only while povLive; the byte patches are
// applied / restored when that changes.
void Configure(const Settings& s, bool povLive);

// Camera forward on the ground plane (unit vector), for raw input and the
// metrics' strafe angles.
void SetCameraForward(float fx, float fz);

// Metrics sampling (render thread, every frame). Logs MOVEFEEL lines.
void Frame();

// Level change / teleport: drop the character pointer.
void ForgetCharacter();

// "direct" | "vanilla" | "failed: ..." for the status line.
const char* State();

// "mf=... mfv=... mftarget=... mfcorr=... mfchk=..." fragment for the status
// line (mfchk = the input-off / body-turned / loco-mid-run check counts).
int Status(char* out, size_t cap);

}  // namespace dag::movefeel
