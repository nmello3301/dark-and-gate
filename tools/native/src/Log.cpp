// SPDX-License-Identifier: GPL-3.0-or-later

#include "Log.h"

#include <windows.h>

#include <cstdarg>
#include <cstdio>
#include <filesystem>
#include <fstream>

namespace dag::log {

namespace {

std::ofstream g_file;

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

    g_file << "[Native] " << buf << "\n";
    g_file.flush();  // small writes, we want them visible immediately
}

void Shutdown()
{
    if (g_file.is_open()) g_file.close();
}

}  // namespace dag::log
