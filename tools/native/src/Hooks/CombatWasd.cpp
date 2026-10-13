// SPDX-License-Identifier: GPL-3.0-or-later
//
// WASD in real-time fights. See CombatWasd.h.

#include "CombatWasd.h"

#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstring>

#include "../Log.h"
#include "../PatternScan.h"

namespace dag::combatwasd {

namespace {

// In 0x14425ec30, right after the participant / FTB component reads:
//   test r12, r12 ; jz +14 ; mov rcx, NULL_HANDLE ; cmp [r12], rcx
//   jnz <return false>          <- +0x13, the combat-handle check
//   mov r12, NULL_HANDLE ; test rbx, rbx   (the force-turn-based check)
// Unique in Patch 8 (checked with a byte search).
constexpr const char* kPattern =
    "4D 85 E4 74 ?? 48 B9 00 00 00 00 00 00 C0 FF 49 39 0C 24 "
    "0F 85 ?? ?? ?? ?? 49 BC 00 00 00 00 00 00 C0 FF 48 85 DB";
constexpr size_t kJnzOffset = 0x13;
constexpr uint8_t kNop6[6] = { 0x66, 0x0F, 0x1F, 0x44, 0x00, 0x00 };

uint8_t* g_site = nullptr;
uint8_t  g_orig[6] = {};
bool     g_on = false;
char     g_state[96] = "not installed";

// Rewrite the 6 instruction bytes. When they sit inside one aligned
// 8-byte block (they do in Patch 8), one interlocked 64-bit store swaps
// them, so a thread running that code sees the old or the new instruction,
// never half of each.
bool Write6(uint8_t* at, const uint8_t* bytes)
{
    uint8_t* blk = reinterpret_cast<uint8_t*>(reinterpret_cast<uintptr_t>(at) & ~uintptr_t(7));
    const size_t off = static_cast<size_t>(at - blk);
    DWORD old = 0;
    if (!VirtualProtect(blk, 16, PAGE_EXECUTE_READWRITE, &old)) return false;
    if (off + 6 <= 8) {
        uint64_t cur = 0;
        std::memcpy(&cur, blk, 8);
        uint64_t next = cur;
        std::memcpy(reinterpret_cast<uint8_t*>(&next) + off, bytes, 6);
        InterlockedExchange64(reinterpret_cast<volatile LONG64*>(blk), static_cast<LONG64>(next));
    } else {
        std::memcpy(at, bytes, 6);
    }
    DWORD tmp = 0;
    VirtualProtect(blk, 16, old, &tmp);
    FlushInstructionCache(GetCurrentProcess(), blk, 16);
    return true;
}

}  // namespace

void Install()
{
    HMODULE mod = GetModuleHandleW(nullptr);
    uint8_t* hit = dag::patternscan::Find(mod, kPattern);
    if (!hit) {
        strcpy_s(g_state, "failed: WASD gate pattern not found (game patched?)");
        dag::log::Writef("COMBATWASD: %s", g_state);
        return;
    }
    uint8_t* site = hit + kJnzOffset;
    if (site[0] != 0x0F || site[1] != 0x85) {
        std::snprintf(g_state, sizeof(g_state), "failed: expected JNZ, found %02X %02X", site[0], site[1]);
        dag::log::Writef("COMBATWASD: %s", g_state);
        return;
    }
    std::memcpy(g_orig, site, sizeof(g_orig));
    g_site = site;
    strcpy_s(g_state, "off");
    const uintptr_t base = reinterpret_cast<uintptr_t>(mod);
    dag::log::Writef("COMBATWASD: the WASD gate's combat check found at rva 0x%llX (skipped while first person is on)",
                     static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(site) - base));
}

void SetEnabled(bool on)
{
    if (!g_site || on == g_on) return;
    if (!Write6(g_site, on ? kNop6 : g_orig)) {
        std::snprintf(g_state, sizeof(g_state), "failed: VirtualProtect (%lu)", GetLastError());
        dag::log::Writef("COMBATWASD: %s", g_state);
        g_site = nullptr;
        return;
    }
    g_on = on;
    strcpy_s(g_state, on ? "on" : "off");
    dag::log::Writef("COMBATWASD: %s", on ? "ON -- WASD moves you in real-time fights"
                                          : "OFF -- BG3's own rule (no WASD while in a fight)");
}

const char* State() { return g_state; }

}  // namespace dag::combatwasd
