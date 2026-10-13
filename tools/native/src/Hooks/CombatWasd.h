// SPDX-License-Identifier: GPL-3.0-or-later
//
// WASD in real-time fights (static RE, bg3_dx11.exe Patch 8; see
// docs/spikes/move-speed.md, "WASD in a fight").
//
// BG3's "may WASD move this character now?" check (0x14425ec30, run every
// frame by the WASD update 0x14425f2c0) answers no while the character's
// combat-participant component holds a combat handle, so in any fight WASD
// never starts (clicks still walk: they go through the server). Our fights
// are real time, so while first person is on the DLL skips that one branch
// (a 6-byte JNZ, NOPed); the force-turn-based check right after it (Brawl's
// pause) is left alone. The same kind of patch BG3WASD uses to unlock WASD
// outside controller mode.

#pragma once

namespace dag::combatwasd {

// Pattern scan (call once at DLL load). Nothing is patched yet.
void Install();

// Patch (true) or restore (false) the branch; a no-op when unchanged.
void SetEnabled(bool on);

// "on" | "off" | "failed: ..." for the status line.
const char* State();

}  // namespace dag::combatwasd
