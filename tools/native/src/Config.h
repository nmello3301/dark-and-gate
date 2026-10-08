// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reads native-config.toml from the Script Extender output folder.
// Hand-rolled parser for a small schema; see Config.cpp for details.
//
// Lua owns the per-race / per-character eye-height lookup and writes
// a single `eye_height = <metres>` into this file (data/camera.lua on
// the Lua side). The DLL just reads the number — no race-tag parsing
// in C++. See docs/native-bridge-design.md § Decisions settled.

#pragma once

namespace dag::config {

struct CameraConfig {
    bool  enabled        = false;   // off by default
    bool  recommit_vt58  = true;    // belt-and-braces zero-frame-lag
    float eye_height     = 1.65f;   // metres, Y-up; Lua writes this
};

struct MouselookConfig {
    bool  enabled          = false;    // off by default
    float sensitivity_yaw   = 0.12f;   // degrees per mouse count
    float sensitivity_pitch = 0.12f;
    bool  invert_pitch      = false;
    bool  pause_in_ui       = true;    // pause mouselook while UI open
};

struct AllConfig {
    CameraConfig    camera;
    MouselookConfig mouselook;
};

// Loads native-config.toml from the SE output folder. Returns the
// defaults if the file is missing or unparseable (and logs a line).
AllConfig Load();

// Shared instance, lazily initialised. Hot-reload is a later concern.
const AllConfig& Get();

}  // namespace dag::config
