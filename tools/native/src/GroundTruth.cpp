// SPDX-License-Identifier: GPL-3.0-or-later

#include "GroundTruth.h"

#include <windows.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <shared_mutex>
#include <string>

#include "Log.h"

namespace dag::groundtruth {

namespace {

std::filesystem::path FilePath()
{
    wchar_t buf[MAX_PATH];
    const DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return {};
    std::filesystem::path p = buf;
    p /= L"Larian Studios";
    p /= L"Baldur's Gate 3";
    p /= L"Script Extender";
    p /= L"DarkAndGate";
    p /= L"native-char-pos.txt";
    return p;
}

std::shared_mutex g_lock;
Snapshot          g_snap;
FILETIME          g_lastMtime  = {};
DWORD             g_lastPollMs = 0;
bool              g_everLogged = false;

Snapshot ParseLine(const std::string& line, uint64_t loadedAt)
{
    Snapshot s;
    s.loadedAt_ms = loadedAt;
    // Expected: active=<0|1> x=<f> y=<f> z=<f> t=<ms>
    // Hand-parse; keep it allocation-free.
    const char* p = line.c_str();
    while (*p) {
        while (*p == ' ' || *p == '\t') ++p;
        if (!*p) break;
        const char* key = p;
        while (*p && *p != '=' && *p != ' ') ++p;
        if (*p != '=') { while (*p && *p != ' ') ++p; continue; }
        const size_t keyLen = p - key;
        ++p;  // skip '='
        const char* val = p;
        while (*p && *p != ' ' && *p != '\n' && *p != '\r') ++p;
        std::string vs(val, p - val);
        if      (keyLen == 6 && std::memcmp(key, "active", 6) == 0) {
            s.active = (vs == "1" || vs == "true");
        } else if (keyLen == 1 && key[0] == 'x') {
            s.x = std::strtof(vs.c_str(), nullptr);
        } else if (keyLen == 1 && key[0] == 'y') {
            s.y = std::strtof(vs.c_str(), nullptr);
        } else if (keyLen == 1 && key[0] == 'z') {
            s.z = std::strtof(vs.c_str(), nullptr);
        } else if (keyLen == 1 && key[0] == 't') {
            s.t_ms = std::strtoull(vs.c_str(), nullptr, 10);
        }
    }
    return s;
}

bool StatMtime(const std::filesystem::path& p, FILETIME& out)
{
    WIN32_FILE_ATTRIBUTE_DATA fad = {};
    if (!GetFileAttributesExW(p.c_str(), GetFileExInfoStandard, &fad)) return false;
    out = fad.ftLastWriteTime;
    return true;
}

}  // namespace

void Poll()
{
    const DWORD now = GetTickCount();
    {
        std::shared_lock<std::shared_mutex> rl(g_lock);
        if (g_lastPollMs != 0 && now - g_lastPollMs < 500) return;
    }
    auto path = FilePath();
    FILETIME mt = {};
    if (!StatMtime(path, mt)) {
        std::unique_lock<std::shared_mutex> wl(g_lock);
        g_lastPollMs = now;
        g_snap.stale = true;
        g_snap.active = false;
        if (!g_everLogged) {
            dag::log::Writef("GroundTruth: %ls not found yet", path.c_str());
            g_everLogged = true;
        }
        return;
    }
    {
        std::shared_lock<std::shared_mutex> rl(g_lock);
        if (CompareFileTime(&mt, &g_lastMtime) == 0) {
            // Not changed — still refresh stale flag below.
        }
    }
    std::ifstream f(path);
    if (!f) {
        std::unique_lock<std::shared_mutex> wl(g_lock);
        g_lastPollMs = now;
        g_snap.stale = true;
        return;
    }
    std::string line;
    std::getline(f, line);
    Snapshot s = ParseLine(line, static_cast<uint64_t>(now));

    const bool stale = (s.t_ms == 0) ||
                       (now > static_cast<DWORD>(s.t_ms) &&
                        (now - static_cast<DWORD>(s.t_ms)) > 2000);
    s.stale = stale;

    {
        std::unique_lock<std::shared_mutex> wl(g_lock);
        g_snap        = s;
        g_lastMtime   = mt;
        g_lastPollMs  = now;
    }

    if (!g_everLogged) {
        dag::log::Writef(
            "GroundTruth: first read active=%d pos=(%.3f,%.3f,%.3f) stale=%d",
            s.active ? 1 : 0, s.x, s.y, s.z, s.stale ? 1 : 0);
        g_everLogged = true;
    }
}

Snapshot Get()
{
    std::shared_lock<std::shared_mutex> rl(g_lock);
    return g_snap;
}

}  // namespace dag::groundtruth
