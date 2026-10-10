// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-character animation play rate. See AnimRate.h and
// docs/spikes/anim-clock.md (static RE, bg3_dx11.exe Patch 8).
//
// GenomeExecutionContext (2nd arg of Execute):
//   +0x08 float dt, +0x18 GenomeBlueprintInstance*, +0x48 u16* socket
//   variable indices of this node, +0x78 / +0x80 u64** variable storage
//   (picked by bit 15 of the index), 16 bytes per variable, value at +0.
// PlayAnimation input socket 2 = PlayRate (Float).

#include "AnimRate.h"

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <cstring>

#include "../Log.h"
#include "../PatternScan.h"

namespace dag::animrate {

namespace {

using ExecFn = void(__fastcall*)(void* node, uint8_t* ctx);

constexpr const char* kExecPattern =
    "48 8B C4 48 89 58 18 55 56 57 41 54 41 55 41 56 41 57 48 8D A8 D8 FD FF FF 48 81 EC F0 02 00 00 "
    "0F 29 70 B8 0F 29 78 A8 44 0F 29 40 98 44 0F 29 48 88 44 0F 29 90 78 FF FF FF 44 0F 29 98 68 FF "
    "FF FF 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 85 80 01 00 00 48 8B F2 48 89 54 24 58 48 8B F9";

constexpr float kFreeze = 0.001f;   // exact 0 is untested in the clip player

ExecFn g_orig = nullptr;
int    g_state = 0;                 // 0 not tried, 1 ok, -1 failed
char   g_why[128] = "not installed";

constexpr int kSlots = 8;
struct Slot {
    std::atomic<uintptr_t> inst{ 0 };
    std::atomic<float>     rate{ 1.f };
};
Slot g_slots[kSlots];
std::atomic<long> g_hits{ 0 };
bool g_hitLogged = false;

bool Lookup(uintptr_t inst, float& r)
{
    for (auto& s : g_slots) {
        if (s.inst.load(std::memory_order_acquire) == inst) { r = s.rate.load(std::memory_order_relaxed); return true; }
    }
    return false;
}

// The PlayRate variable of the node being executed, or nullptr.
float* PlayRateVar(uint8_t* ctx)
{
    __try {
        uint8_t* socks = *reinterpret_cast<uint8_t**>(ctx + 0x48);
        if (!socks) return nullptr;
        const uint16_t idx = *reinterpret_cast<uint16_t*>(socks + 4);
        uint8_t** storePtr = *reinterpret_cast<uint8_t***>(ctx + 0x78 + static_cast<size_t>(idx >> 15) * 8);
        if (!storePtr || !*storePtr) return nullptr;
        float* p = reinterpret_cast<float*>(*storePtr + static_cast<size_t>(idx & 0x7fff) * 16);
        volatile float probe = *p;   // fault here, not later
        (void)probe;
        return p;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return nullptr;
    }
}

void __fastcall HookExec(void* node, uint8_t* ctx)
{
    float r;
    const uintptr_t inst = ctx ? *reinterpret_cast<uintptr_t*>(ctx + 0x18) : 0;
    if (!inst || !Lookup(inst, r)) { g_orig(node, ctx); return; }
    float* p = PlayRateVar(ctx);
    if (!p) { g_orig(node, ctx); return; }
    const float saved = *p;
    *p = saved * (r <= 0.f ? kFreeze : r);
    g_orig(node, ctx);
    *p = saved;
    g_hits.fetch_add(1, std::memory_order_relaxed);
}

bool InModuleRange(uintptr_t a, uintptr_t lo, uintptr_t hi) { return a >= lo && a < hi; }

void Install()
{
    g_state = -1;
    HMODULE mod = GetModuleHandleW(nullptr);
    uint8_t* fn = dag::patternscan::Find(mod, kExecPattern);
    if (!fn) { strcpy_s(g_why, "failed: Execute pattern not found (game patched?)"); dag::log::Writef("RATE: %s", g_why); return; }

    // Patch every .rdata qword that points at Execute (the node vtables).
    const uintptr_t base = reinterpret_cast<uintptr_t>(mod);
    auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    auto* nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    IMAGE_SECTION_HEADER* sec = IMAGE_FIRST_SECTION(nt);
    int patched = 0;
    g_orig = reinterpret_cast<ExecFn>(fn);
    for (int i = 0; i < nt->FileHeader.NumberOfSections; ++i, ++sec) {
        if (std::memcmp(sec->Name, ".rdata", 6) != 0) continue;
        auto* q = reinterpret_cast<uintptr_t*>(base + sec->VirtualAddress);
        const size_t n = sec->Misc.VirtualSize / sizeof(uintptr_t);
        for (size_t k = 0; k < n; ++k) {
            if (q[k] != reinterpret_cast<uintptr_t>(fn)) continue;
            DWORD old = 0;
            if (!VirtualProtect(&q[k], sizeof(uintptr_t), PAGE_READWRITE, &old)) continue;
            q[k] = reinterpret_cast<uintptr_t>(&HookExec);
            DWORD tmp = 0;
            VirtualProtect(&q[k], sizeof(uintptr_t), old, &tmp);
            dag::log::Writef("RATE: patched vtable slot %p (rva 0x%llX)", reinterpret_cast<void*>(&q[k]),
                             static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(&q[k]) - base));
            ++patched;
        }
    }
    if (patched == 0) {
        strcpy_s(g_why, "failed: no vtable slot points at Execute");
        dag::log::Writef("RATE: %s", g_why);
        return;
    }
    g_state = 1;
    std::snprintf(g_why, sizeof(g_why), "ok (%d node vtables)", patched);
    dag::log::Writef("RATE: PlayAnimation Execute at rva 0x%llX hooked, %d slots",
                     static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(fn) - base), patched);
}

}  // namespace

void Set(uintptr_t instance, float rate)
{
    const bool active = instance != 0 && rate != 1.f;
    if (active && g_state == 0) Install();
    // Single active target today (the browsed character); slot 0.
    float old = g_slots[0].rate.load();
    uintptr_t oldInst = g_slots[0].inst.load();
    if (!active) {
        if (oldInst) {
            g_slots[0].inst.store(0, std::memory_order_release);
            dag::log::Writef("RATE: cleared (instance %p back to x1; %ld scaled calls)", reinterpret_cast<void*>(oldInst), g_hits.load());
            g_hits.store(0);
        }
        return;
    }
    if (g_state != 1) return;
    g_slots[0].rate.store(rate, std::memory_order_relaxed);
    g_slots[0].inst.store(instance, std::memory_order_release);
    if (oldInst != instance || old != rate) {
        dag::log::Writef("RATE: instance %p at x%.3f", reinterpret_cast<void*>(instance), rate);
        g_hitLogged = false;
    }
    if (!g_hitLogged && g_hits.load() > 0) {
        g_hitLogged = true;
        dag::log::Writef("RATE: hook is scaling clips on that instance (%ld calls so far)", g_hits.load());
    }
}

const char* State() { return g_why; }

long Hits() { return g_hits.load(); }

}  // namespace dag::animrate
