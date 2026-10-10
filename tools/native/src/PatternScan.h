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
//
// Fails and returns nullptr if `newTarget` is further than ±2GB from
// `callSite + 5`. For that case use `InstallFarCall5` instead.
uint8_t* WriteCall5(uint8_t* callSite, void* newTarget);

// Hook a 5-byte CALL that targets a function possibly out of 32-bit
// relative range (common on x64 when the DLL loads far from the EXE).
// Allocates a 12-byte near-stub within ±2GB of callSite that does
// `MOV RAX, <newTarget>; JMP RAX`, then rewires the CALL to the stub.
//
// Returns the OLD CALL target on success (same semantics as WriteCall5
// — chain through it). Returns nullptr if the stub couldn't be
// allocated near enough or if callSite[0] != 0xE8.
uint8_t* InstallFarCall5(uint8_t* callSite, void* newTarget);

// Same as InstallFarCall5 for a 5-byte `E9` tail JMP. The hook must have
// the target's signature and return the target's result (it runs as the
// callee). Returns the OLD jump target, or nullptr if jmpSite[0] != 0xE9
// or no stub could be allocated in range.
uint8_t* InstallFarJmp5(uint8_t* jmpSite, void* newTarget);

// Inline detour at a function entry. The first `stolenLen` bytes (5..8,
// whole instructions) must equal `expected`; they must not be
// RIP-relative or a branch (the caller proves this statically and passes
// the exact bytes, so a patched or different build is refused). Builds a
// trampoline near `fn` (stolen bytes + `jmp [rip] -> fn+stolenLen`) and a
// `mov rax, hook; jmp rax` stub, then writes `E9 -> stub` (+ NOP pad) at
// `fn` with one aligned 8-byte interlocked store when `fn` is 8-aligned.
// The trampoline (call it as the original function) is stored in
// `*trampolineOut` BEFORE the entry is patched, so a hook running on
// another thread never sees it unset. Returns false (and leaves the code
// alone) if the bytes differ or no memory could be allocated in range.
bool InstallEntryDetour(uint8_t* fn, const uint8_t* expected, size_t stolenLen, void* hook,
                        void* volatile* trampolineOut);

}  // namespace dag::patternscan
