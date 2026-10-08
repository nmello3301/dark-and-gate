// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dark and Gate native plugin — entry point.
//
// Writes a one-line version file to the Script Extender output folder
// so Shared/NativeBridge.lua can confirm the DLL loaded. Then installs
// the camera-follow + mouselook hooks (both off by default; flip in
// native-config.toml).

#include <windows.h>

#include <filesystem>
#include <fstream>
#include <string>

#include "Config.h"
#include "Hooks/Camera.h"
#include "Hooks/Mouselook.h"
#include "Log.h"

namespace {

constexpr const char* kPluginName    = "DarkAndGate";
constexpr const char* kPluginVersion = "0.1.0";
constexpr const char* kBuildKind     = "scaffold";

// Returns %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\DarkAndGate\
// Creates the directory if it doesn't exist. Returns empty path on error.
std::filesystem::path OutputDir()
{
    wchar_t buf[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) {
        return {};
    }
    std::filesystem::path p = buf;
    p /= L"Larian Studios";
    p /= L"Baldur's Gate 3";
    p /= L"Script Extender";
    p /= L"DarkAndGate";

    std::error_code ec;
    std::filesystem::create_directories(p, ec);
    if (ec) {
        return {};
    }
    return p;
}

void WriteVersionFile()
{
    auto dir = OutputDir();
    if (dir.empty()) {
        return;
    }
    auto path = dir / L"native-version.txt";

    std::ofstream out(path, std::ios::out | std::ios::trunc);
    if (!out) {
        return;
    }

    // One line, machine-parseable, Lua-side splits on spaces.
    //   DarkAndGate <version> <build-kind> <pid> <monotonic-ms>
    out << kPluginName << " " << kPluginVersion << " " << kBuildKind
        << " pid=" << GetCurrentProcessId()
        << " t=" << GetTickCount64()
        << "\n";
}

}  // namespace

BOOL APIENTRY DllMain(HMODULE /*module*/, DWORD reason, LPVOID /*reserved*/)
{
    if (reason == DLL_PROCESS_ATTACH) {
        WriteVersionFile();
        dag::log::Init();
        dag::log::Writef("Native: Dark and Gate %s %s loaded",
                         kPluginVersion, kBuildKind);

        // Loads native-config.toml and caches it.
        (void)dag::config::Get();

        // Install hooks. They're always installed; the enabled flags in
        // native-config.toml decide whether they override the engine's
        // behaviour. Install failure logs and leaves the game running
        // vanilla — no crash path on load.
        dag::hooks::camera::Install();
        dag::hooks::mouselook::Install();
    } else if (reason == DLL_PROCESS_DETACH) {
        dag::log::Shutdown();
    }
    return TRUE;
}
