// SPDX-License-Identifier: GPL-3.0-or-later

#include "Log.h"

#include <windows.h>

#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>

namespace dag::log {

namespace {

std::ofstream g_file;
SRWLOCK g_lock = SRWLOCK_INIT;   // the startup self-check logs from its own thread
char g_tag[48] = "";             // "u65537 host" once Lua knows (multiplayer logs)

std::filesystem::path LogPath()
{
    wchar_t buf[MAX_PATH];
    const DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return {};
    std::filesystem::path p = buf;
    p /= L"Larian Studios";
    p /= L"Baldur's Gate 3";
    p /= L"Script Extender";
    p /= L"DarkAndGate";
    std::error_code ec;
    std::filesystem::create_directories(p, ec);
    p /= L"native.log";
    return p;
}

}  // namespace

void Init()
{
    const auto p = LogPath();
    if (p.empty()) return;
    g_file.open(p, std::ios::out | std::ios::trunc);
}

void Writef(const char* fmt, ...)
{
    if (!g_file.is_open()) return;

    char   stackBuf[1024];
    char*  buf = stackBuf;
    size_t cap = sizeof(stackBuf);

    va_list ap;
    va_start(ap, fmt);
    int n = std::vsnprintf(buf, cap, fmt, ap);
    va_end(ap);
    if (n < 0) return;

    AcquireSRWLockExclusive(&g_lock);
    if (g_tag[0]) g_file << "[Native " << g_tag << "] " << buf << "\n";
    else          g_file << "[Native] " << buf << "\n";
    g_file.flush();  // small writes, we want them visible immediately
    ReleaseSRWLockExclusive(&g_lock);
}

void SetTag(const char* tag)
{
    char t[sizeof(g_tag)] = "";
    if (tag) strncpy_s(t, tag, _TRUNCATE);
    AcquireSRWLockExclusive(&g_lock);
    const bool changed = std::strcmp(t, g_tag) != 0;
    if (changed) std::memcpy(g_tag, t, sizeof(g_tag));
    ReleaseSRWLockExclusive(&g_lock);
    if (changed && t[0]) Writef("log tag: lines from this machine are tagged [Native %s] (multiplayer)", t);
}

void Shutdown()
{
    if (g_file.is_open()) g_file.close();
}

}  // namespace dag::log
