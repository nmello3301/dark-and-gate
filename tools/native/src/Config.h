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
struct CameraConfig {
    bool  enabled        = false;   // M1a core: pin the gameplay cam
    bool  recommit_vt58  = true;    // belt-and-braces zero-frame-lag
    float eye_height     = 1.65f;   // metres, Y-up; Lua writes this
    float debug_lift_m   = 0.0f;    // if >0, used in place of eye_height
    bool  head_bone      = false;   // pin to head bone instead of char.y+h
                                     // (gated on bone-reads landing real)
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
