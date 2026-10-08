// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reads native-config.toml from the Script Extender output folder.
// We ship a hand-rolled parser for the small schema below — avoids
// pulling in a TOML dep for one file.
//
// Supported subset:
//   # comments
//   [section]
//   key = true
//   key = 1.5
//   key = -3
//   key = "quoted string"
//
// No arrays, no multiline, no nested tables. If we grow past that, swap
// in tomlplusplus; the Config struct stays the same shape.

#pragma once

#include <string>

namespace dag::config {

struct CameraConfig {
    bool  enabled           = false;   // off by default
    bool  recommit_vt58     = true;    // belt-and-braces zero-frame-lag
    float eye_height_default = 1.65f;  // metres, Y-up
    // Per-race heights live in the file as `eye_height_dwarf` etc.;
    // the camera looks them up by race-tag at hook time. For M1a we
    // read a flat key per race, no fancy lookup.
    float eye_height_human     = 1.68f;
    float eye_height_elf       = 1.75f;
    float eye_height_dragonborn = 1.90f;
    float eye_height_halforc   = 1.80f;
    float eye_height_githyanki = 1.78f;
    float eye_height_dwarf     = 1.12f;
    float eye_height_halfling  = 0.90f;
    float eye_height_gnome     = 0.88f;
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
