// SPDX-License-Identifier: GPL-3.0-or-later
//
// Minimal byte-pattern scanner. Takes IDA-style "48 8D ?? ..." strings
// where ?? is a wildcard. Scans the loaded bg3.exe .text section.
//
// Enough for M1a. If we need more hook sites later, swap for DKUtil.

#pragma once

#include <cstddef>
#include <cstdint>
#include <string_view>

namespace dag::patternscan {

// Finds the first occurrence of `patternIdaStyle` inside `module`.
// Returns nullptr if not found or if the pattern string is malformed.
//
// `module` is the module base (e.g. GetModuleHandleW(L"bg3.exe")); the
// scanner finds its .text section itself. If `module` is null, uses
// the main EXE module.
uint8_t* Find(void* module, std::string_view patternIdaStyle);

// Decodes a 5-byte `E8 xx xx xx xx` CALL at `callSite` and returns the
// absolute address of the target. Returns nullptr if the opcode at
// `callSite` isn't `E8`.
uint8_t* DecodeRelCallTarget(uint8_t* callSite);

// Writes a new 5-byte `E8` CALL at `callSite` targeting `newTarget`.
// Returns the OLD target address (which may itself be a trampoline from
// another mod — chain through it).
//
// `callSite[0]` must be `0xE8` or the function returns nullptr.
// Handles VirtualProtect page toggles. Not thread-safe; call during DLL
// load before the game's own threads touch this code.
uint8_t* WriteCall5(uint8_t* callSite, void* newTarget);

}  // namespace dag::patternscan
