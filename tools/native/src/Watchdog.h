// SPDX-License-Identifier: GPL-3.0-or-later
//
// Freeze watchdog (diagnostics only). A background thread of our own DLL
// notices when the frame hook stops being called (or the game window stops
// answering) for a few seconds and logs where the stuck threads are: a few
// samples of each thread's instruction pointer and the module+offset it
// falls in, plus code addresses found near the top of its stack. In-process
// only (SuspendThread / GetThreadContext on the game's own threads from our
// own thread); no debugger, nothing attached from outside.

#pragma once

namespace dag::watchdog {

// Start the thread once (DLL load).
void Start();

// Called from the per-frame hook: records the frame thread and the time.
// `stage` names what our code is doing (for the freeze report).
void Frame();
void Stage(const char* stage);

}  // namespace dag::watchdog
