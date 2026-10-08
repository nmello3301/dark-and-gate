// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reads Lua's periodic snapshot of the controlled character's world
// position and gameplay-active flag. Lua writes
//   %LOCALAPPDATA%\...\Script Extender\DarkAndGate\native-char-pos.txt
// every ~500 ms with a line like:
//   active=1 x=12.34 y=5.67 z=-89.1 t=721840546
//
// This file is calibration + an active flag only. Once a camera's
// gameplay-cam identity is latched (via the camera hook's probe), the
// hook reads the LIVE memory location every frame — never the file —
// so the ~500ms staleness only affects latch-on and dialog pause.

#pragma once

#include <cstdint>

namespace dag::groundtruth {

struct Snapshot {
    bool    active = false;    // true only during real-time gameplay
    float   x = 0.0f;
    float   y = 0.0f;
    float   z = 0.0f;
    uint64_t t_ms = 0;         // Lua's monotonic ms at write time
    uint64_t loadedAt_ms = 0;  // GetTickCount64 when we parsed the file
    bool    stale = true;      // true if file older than 2 s
};

// Poll the file at most once per 500 ms. Thread-safe. Cheap when
// mtime hasn't changed (one GetFileAttributesEx call).
void Poll();

// Thread-safe copy of the most recent snapshot.
Snapshot Get();

}  // namespace dag::groundtruth
