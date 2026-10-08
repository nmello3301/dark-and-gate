// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reads native-config.toml from the Script Extender output folder.
// Hand-rolled parser for a small schema; see Config.cpp for details.
//
// Every feature has its own switch, OFF by default. A crash or bad
// behaviour must be attributable to one switch (user requirement for
// M1a). See docs/native-bridge-design.md § Decisions settled.
//
// Live reload: Load() can be called again at any time; Get() returns
// a const& to a swapped-in copy. Camera.cpp polls mtime once per
// second and triggers reload. Values are plain-old-data so a mid-frame
// swap is torn-value-safe for our use case.

#pragma once

namespace dag::config {

// --- Camera position pin ----------------------------------------------
// Phase 0 (2026-10-08): all overrides parked, defaults false. Takeover
// session is rebuilding the camera from scratch — NCT alone is the
// baseline. Any switch set to true below is either (a) a known-broken
// legacy path from the previous session, kept behind a switch so a
// stale TOML can't silently turn it back on, or (b) a diagnostic that
// doesn't touch rendered state. See docs/spikes/m1a-camera-follow.md.
struct CameraConfig {
    bool  enabled        = false;   // master gate for any camera write
    bool  recommit_vt58  = false;   // legacy: belt-and-braces re-commit
    float eye_height     = 1.65f;   // metres, Y-up; used by future head-anchor
    float debug_lift_m   = 0.0f;    // if >0, used in place of eye_height for A/B
    bool  head_bone      = false;   // pin to head bone (needs bone reads)
    bool  hide_head      = false;   // Spike11 RenderPasses zero (Lua-side)
    // Parked (Phase 0): vt[0x58] eye+target substitution.
    bool  vt58_override  = false;
    // Parked (Phase 0): writes CameraDefinition damping fields to collapse
    // the engine's lerp. Default off — Phase 1 proves anchor injection
    // first; smoothing bypass follows if still needed.
    bool  instant_follow = false;
    // Parked (Phase 0): legacy Step-C style write at kCamWorldPosY. That
    // offset (0x4c) is `currentZoomB` per NCT's CameraObject layout, NOT
    // the Y of the camera world position — writing to it modifies zoom,
    // which is why the previous "wrote=(x, char.y+4, z)" log never moved
    // InvViewMatrix. Kept behind this switch so a stale TOML or forgotten
    // DECISIONS-doc change can't re-enable it silently.
    bool  legacy_y_write = false;
    // Parked (Phase 0): legacy mouselook write to cam[0x70..0x78]. Same
    // offset problem — 0x70 is `fltmax_70`, cameraRotation starts at 0x74.
    bool  legacy_forward_write = false;
};

// --- Mouselook / cursor lock ------------------------------------------
struct MouselookConfig {
    bool  enabled           = false;
    float sensitivity_yaw   = 0.12f;   // degrees per raw mouse count
    float sensitivity_pitch = 0.12f;
    bool  invert_pitch      = false;
    bool  pause_in_ui       = true;    // read Lua active flag; skip while UI
    bool  character_facing  = false;   // let Lua rotate char to our yaw
};

// --- Anim playback speed / cancel / hit-stop --------------------------
struct AnimConfig {
    bool  enabled     = false;   // master switch
    bool  hit_stop    = false;   // sub-feature: brief speed=0 on hit
    int   hit_stop_ms = 100;     // duration of hit stop
};

// --- Bone reads --------------------------------------------------------
struct BoneConfig {
    bool  enabled = false;   // enable GetBoneWorldPos API
};

// --- Raycast with normal ----------------------------------------------
struct RaycastConfig {
    bool  enabled = false;   // enable raycast API
};

struct AllConfig {
    CameraConfig    camera;
    MouselookConfig mouselook;
    AnimConfig      anim;
    BoneConfig      bone;
    RaycastConfig   raycast;
};

// Load from disk. Returns defaults if the file is missing or unparseable.
// Safe to call repeatedly for live-reload.
AllConfig Load();

// Access the shared instance. First call triggers an initial load.
const AllConfig& Get();

// Poll the config file's mtime; if changed, reload. Called from the
// camera hook once per second (cheap FindFirstFile call). Returns true
// if a reload actually happened.
bool PollAndReload();

}  // namespace dag::config
