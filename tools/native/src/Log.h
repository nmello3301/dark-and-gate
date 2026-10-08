// SPDX-License-Identifier: GPL-3.0-or-later
//
// Minimal file logger. Writes one line per call to:
//   %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\
//   DarkAndGate\native.log
//
// Opens the file on first write and keeps it open for the DLL's
// lifetime. Not thread-safe for throughput, but good enough for the
// install-time + per-second logs we emit. Everything is prefixed
// `[Native] `.

#pragma once

#include <string>

namespace dag::log {

void Init();
void Writef(const char* fmt, ...);
void Shutdown();

inline void Write(const std::string& s) { Writef("%s", s.c_str()); }

}  // namespace dag::log
