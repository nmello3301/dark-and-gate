// SPDX-License-Identifier: GPL-3.0-or-later
//
// Player WASD ground speed. See MoveSpeed.h and docs/spikes/move-speed.md.
//
// Call site (MoveController per-frame update, Patch 8 0x14425f428):
//   call GetEffectiveTemplate(character, a2, a3, a4, u8 flag)
//   movss xmm14, [rax+0x590]     ; MovementSpeedStroll
//   movss xmm12, [rax+0x5a0]     ; MovementSpeedRun
//   mov   rax, [rsi+0x68]        ; rax is not used again
// The hook calls the original and, when a multiplier is active, returns
// g_block instead: a buffer whose +0x590 / +0x5a0 hold our values.

#include "MoveSpeed.h"

#include <windows.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "../Log.h"
#include "../PatternScan.h"

namespace dag::movespeed {

namespace {

using TmplFn = uint8_t*(__fastcall*)(void* character, void* a2, void* a3, void* a4, uint8_t flag);

constexpr const char* kCallPattern =
    "E8 ?? ?? ?? ?? F3 44 0F 10 B0 90 05 00 00 F3 44 0F 10 A0 A0 05 00 00";
constexpr uintptr_t kStroll = 0x590;
constexpr uintptr_t kRun    = 0x5a0;

TmplFn g_orig = nullptr;
char   g_why[128] = "not installed";

std::atomic<float> g_walk{ 1.f };
std::atomic<float> g_runM{ 1.f };
std::atomic<float> g_tWalk{ 0.25f };   // from BG3WASD's WalkSpeed
std::atomic<long>  g_calls{ 0 };

alignas(16) uint8_t g_block[0x5c0] = {};
float g_lastS = 0, g_lastR = 0, g_lastSo = 0, g_lastRo = 0;
bool  g_clampLogged = false;

bool ReadTemplate(const uint8_t* t, float& s, float& r)
{
    __try {
        s = *reinterpret_cast<const float*>(t + kStroll);
        r = *reinterpret_cast<const float*>(t + kRun);
        return std::isfinite(s) && std::isfinite(r);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

uint8_t* __fastcall Hook(void* character, void* a2, void* a3, void* a4, uint8_t flag)
{
    uint8_t* t = g_orig(character, a2, a3, a4, flag);
    g_calls.fetch_add(1, std::memory_order_relaxed);
    const float wm = g_walk.load(std::memory_order_relaxed);
    const float rm = g_runM.load(std::memory_order_relaxed);
    float S = 0, R = 0;
    if (!t || !ReadTemplate(t, S, R)) return t;
    g_lastS = S; g_lastR = R;
    if ((wm == 1.f && rm == 1.f) || S < 0.f || R < 0.2f || R > 30.f) {
        g_lastSo = S; g_lastRo = R;
        return t;
    }
    const float tw = g_tWalk.load(std::memory_order_relaxed);
    const float Rp = R * rm;
    const float W  = (S + tw * (R - S)) * wm;   // natural walk speed x walkMult
    float Sp = (tw < 0.999f) ? (W - tw * Rp) / (1.f - tw) : S * wm;
    if (Sp < 0.05f) {
        Sp = 0.05f;
        if (!g_clampLogged) {
            g_clampLogged = true;
            dag::log::Writef("MOVE: walk speed limited by the run speed (stroll clamped to 0.05; walk x%.2f run x%.2f)", wm, rm);
        }
    }
    *reinterpret_cast<float*>(g_block + kStroll) = Sp;
    *reinterpret_cast<float*>(g_block + kRun) = Rp;
    g_lastSo = Sp; g_lastRo = Rp;
    return g_block;
}

// BG3WASD's walk input magnitude -> the lerp t its walk lands on.
// <exe dir>\NativeMods\BG3WASD.toml, "WalkSpeed = x" (default 0.3).
std::wstring WasdTomlPath()
{
    wchar_t exe[MAX_PATH];
    const DWORD n = GetModuleFileNameW(nullptr, exe, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return {};
    std::wstring p(exe, n);
    const size_t slash = p.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return {};
    return p.substr(0, slash + 1) + L"NativeMods\\BG3WASD.toml";
}

FILETIME g_tomlTime = {};
DWORD    g_lastTomlCheck = 0;

void ReadWasdWalkSpeed(bool force)
{
    const DWORD now = GetTickCount();
    if (!force && now - g_lastTomlCheck < 5000) return;
    g_lastTomlCheck = now;
    const std::wstring path = WasdTomlPath();
    WIN32_FILE_ATTRIBUTE_DATA fa{};
    if (path.empty() || !GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &fa)) return;
    if (!force && CompareFileTime(&fa.ftLastWriteTime, &g_tomlTime) == 0) return;
    g_tomlTime = fa.ftLastWriteTime;
    FILE* f = nullptr;
    if (_wfopen_s(&f, path.c_str(), L"rb") != 0 || !f) return;
    char line[512];
    float ws = 0.3f;
    bool found = false;
    while (std::fgets(line, sizeof(line), f)) {
        const char* p = line;
        while (*p == ' ' || *p == '\t') ++p;
        if (std::strncmp(p, "WalkSpeed", 9) != 0) continue;
        p += 9;
        while (*p == ' ' || *p == '\t') ++p;
        if (*p != '=') continue;
        ws = static_cast<float>(std::atof(p + 1));
        found = true;
        break;
    }
    std::fclose(f);
    float m = ws < 0.1f ? 0.1f : (ws > 0.9f ? 0.9f : ws);
    const float t = (m - 0.1f) / 0.8f;
    g_tWalk.store(t);
    dag::log::Writef("MOVE: BG3WASD WalkSpeed=%.2f%s -> walk lerp t=%.3f", ws, found ? "" : " (default, not in toml)", t);
}

}  // namespace

void Install()
{
    HMODULE mod = GetModuleHandleW(nullptr);
    uint8_t* site = dag::patternscan::Find(mod, kCallPattern);
    if (!site) {
        strcpy_s(g_why, "failed: template-fetch call pattern not found (game patched?)");
        dag::log::Writef("MOVE: %s", g_why);
        return;
    }
    uint8_t* prev = dag::patternscan::InstallFarCall5(site, reinterpret_cast<void*>(&Hook));
    if (!prev) {
        strcpy_s(g_why, "failed: could not patch the call");
        dag::log::Writef("MOVE: %s", g_why);
        return;
    }
    g_orig = reinterpret_cast<TmplFn>(prev);
    const uintptr_t base = reinterpret_cast<uintptr_t>(mod);
    std::snprintf(g_why, sizeof(g_why), "ok");
    dag::log::Writef("MOVE: WASD template fetch hooked at rva 0x%llX (original rva 0x%llX)",
                     static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(site) - base),
                     static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(prev) - base));
    ReadWasdWalkSpeed(true);
}

void Set(float walkMult, float runMult)
{
    if (!g_orig) return;
    ReadWasdWalkSpeed(false);
    if (!std::isfinite(walkMult) || walkMult <= 0.f) walkMult = 1.f;
    if (!std::isfinite(runMult) || runMult <= 0.f) runMult = 1.f;
    const float ow = g_walk.load(), orr = g_runM.load();
    if (std::fabs(ow - walkMult) > 1e-4f || std::fabs(orr - runMult) > 1e-4f) {
        g_walk.store(walkMult);
        g_runM.store(runMult);
        g_clampLogged = false;
        dag::log::Writef("MOVE: walk x%.3f run x%.3f (template stroll %.2f run %.2f m/s seen, %ld calls)",
                         walkMult, runMult, g_lastS, g_lastR, g_calls.load());
    }
}

const char* State() { return g_why; }

void Read(float& stroll, float& run, float& tWalk, float& strollOut, float& runOut, long& calls)
{
    stroll = g_lastS; run = g_lastR; tWalk = g_tWalk.load();
    strollOut = g_lastSo; runOut = g_lastRo; calls = g_calls.load();
}

}  // namespace dag::movespeed
