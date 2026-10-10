// SPDX-License-Identifier: GPL-3.0-or-later
//
// Freeze watchdog. See Watchdog.h.

#include "Watchdog.h"

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cwchar>

#include "Log.h"

namespace dag::watchdog {

namespace {

std::atomic<DWORD>       g_frameThread{ 0 };
std::atomic<ULONGLONG>   g_lastFrame{ 0 };
std::atomic<const char*> g_stage{ "none" };
std::atomic<bool>        g_started{ false };

constexpr ULONGLONG kFreezeMs = 5000;

// "module+0xRVA" for an address, or "?" if it isn't in a module.
void Describe(uintptr_t a, char* out, size_t cap)
{
    HMODULE m = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            reinterpret_cast<LPCWSTR>(a), &m) || !m) {
        std::snprintf(out, cap, "%p(?)", reinterpret_cast<void*>(a));
        return;
    }
    wchar_t path[MAX_PATH];
    const DWORD n = GetModuleFileNameW(m, path, MAX_PATH);
    const wchar_t* name = path;
    for (DWORD i = 0; i < n; ++i) if (path[i] == L'\\' || path[i] == L'/') name = path + i + 1;
    std::snprintf(out, cap, "%ls+0x%llX", n ? name : L"?",
                  static_cast<unsigned long long>(a - reinterpret_cast<uintptr_t>(m)));
}

bool IsCode(uintptr_t a)
{
    MEMORY_BASIC_INFORMATION mbi{};
    if (!VirtualQuery(reinterpret_cast<void*>(a), &mbi, sizeof(mbi))) return false;
    if (mbi.State != MEM_COMMIT || mbi.Type != MEM_IMAGE) return false;
    return (mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)) != 0;
}

void SampleThread(DWORD tid, const char* label)
{
    if (!tid || tid == GetCurrentThreadId()) return;
    HANDLE h = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, tid);
    if (!h) { dag::log::Writef("FREEZE: %s thread %lu: OpenThread failed (%lu)", label, tid, GetLastError()); return; }
    for (int s = 0; s < 3; ++s) {
        if (SuspendThread(h) == static_cast<DWORD>(-1)) break;
        CONTEXT ctx{};
        ctx.ContextFlags = CONTEXT_CONTROL | CONTEXT_INTEGER;
        char rip[160] = "?";
        char stack[1200] = "";
        int sl = 0;
        if (GetThreadContext(h, &ctx)) {
            Describe(ctx.Rip, rip, sizeof(rip));
            // Code addresses near the top of the stack (a rough backtrace).
            int found = 0;
            for (int i = 0; i < 256 && found < 10; ++i) {
                uintptr_t v = 0;
                SIZE_T got = 0;
                if (!ReadProcessMemory(GetCurrentProcess(), reinterpret_cast<void*>(ctx.Rsp + i * 8), &v, sizeof(v), &got) || got != sizeof(v)) break;
                if (v > 0x10000 && IsCode(v)) {
                    char d[160];
                    Describe(v, d, sizeof(d));
                    if (sl < static_cast<int>(sizeof(stack)) - 170) sl += std::snprintf(stack + sl, sizeof(stack) - sl, " %s", d);
                    ++found;
                }
            }
        }
        ResumeThread(h);
        dag::log::Writef("FREEZE: %s thread %lu sample %d rip=%s stack:%s", label, tid, s + 1, rip, stack);
        Sleep(300);
    }
    CloseHandle(h);
}

// The game's main window thread (owns the message loop the OS checks for
// "Not responding").
struct WinFind { DWORD pid; HWND hwnd; };
BOOL CALLBACK EnumCb(HWND w, LPARAM lp)
{
    auto* f = reinterpret_cast<WinFind*>(lp);
    DWORD pid = 0;
    GetWindowThreadProcessId(w, &pid);
    if (pid == f->pid && IsWindowVisible(w) && GetWindow(w, GW_OWNER) == nullptr) {
        RECT r{};
        GetWindowRect(w, &r);
        if (r.right - r.left > 400) { f->hwnd = w; return FALSE; }
    }
    return TRUE;
}

DWORD WINAPI Run(LPVOID)
{
    bool reported = false;
    HWND win = nullptr;
    for (;;) {
        Sleep(1000);
        const ULONGLONG last = g_lastFrame.load();
        if (last == 0) continue;   // no frame yet (menus before the camera hook runs)
        if (!win || !IsWindow(win)) {
            WinFind f{ GetCurrentProcessId(), nullptr };
            EnumWindows(EnumCb, reinterpret_cast<LPARAM>(&f));
            win = f.hwnd;
        }
        const ULONGLONG gap = GetTickCount64() - last;
        const bool hungWin = win && IsHungAppWindow(win);
        if ((gap >= kFreezeMs || hungWin) && !reported) {
            reported = true;
            const DWORD winTid = win ? GetWindowThreadProcessId(win, nullptr) : 0;
            dag::log::Writef("FREEZE: no frame for %llu ms, window hung=%d, our last stage=%s (frame thread %lu, window thread %lu)",
                             gap, hungWin ? 1 : 0, g_stage.load(), g_frameThread.load(), winTid);
            SampleThread(g_frameThread.load(), "frame");
            if (winTid && winTid != g_frameThread.load()) SampleThread(winTid, "window");
        } else if (reported && gap < 1000 && !hungWin) {
            reported = false;
            dag::log::Writef("FREEZE: frames are back");
        }
    }
}

}  // namespace

void Start()
{
    bool expected = false;
    if (!g_started.compare_exchange_strong(expected, true)) return;
    HANDLE t = CreateThread(nullptr, 0, &Run, nullptr, 0, nullptr);
    if (t) CloseHandle(t);
    dag::log::Writef("Watchdog: freeze reporter started (logs FREEZE: lines if frames stop for %llu ms)", kFreezeMs);
}

void Frame()
{
    g_frameThread.store(GetCurrentThreadId(), std::memory_order_relaxed);
    g_lastFrame.store(GetTickCount64(), std::memory_order_relaxed);
}

void Stage(const char* stage) { g_stage.store(stage, std::memory_order_relaxed); }

}  // namespace dag::watchdog
