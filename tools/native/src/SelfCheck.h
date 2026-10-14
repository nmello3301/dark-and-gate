// SPDX-License-Identifier: GPL-3.0-or-later
//
// Startup self-check (multiplayer MP-0, docs/design/multiplayer.md):
//   * which exe this is: the vanilla Patch 8 build the DLL was made for,
//     the same build patched by Party Limit Begone's multiplayer patch, or
//     something else (SHA-256 of the exe file; PLB's find / replace pairs);
//   * every byte pattern the DLL scanned for, re-scanned in the exe FILE
//     (memory can already carry other mods' hooks): found? unique? the
//     same address as in memory?
//   * every code patch site, against PLB's changed bytes;
//   * the vtable / data RVAs the DLL validates objects against.
// Runs once on a background thread after the installs. Logs SELFCHECK
// lines and writes native-selfcheck.txt (one line, key=value) for Lua: the
// version handshake and !dag_mp_status read it.

#pragma once

namespace dag::selfcheck {

// The DLL's build stamp: "<git hash>[+dirty]-<UTC time>" (build_info.h).
const char* DllBuild();

// Start the check (call once from DllMain after every Install()).
void Start();

}  // namespace dag::selfcheck
