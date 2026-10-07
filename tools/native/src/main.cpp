// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dark and Gate native plugin — entry point.
//
// M1a scaffold: on DLL load, write a version line to the Script Extender
// output folder so the Lua side can confirm the native plugin is present
// without us having to build a real Lua↔DLL bridge first.
//
// Path: %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\
//       DarkAndGate\native-version.txt
//
// The Lua side (Shared/NativeBridge.lua) reads this file via
// Ext.IO.LoadFile() on SessionLoaded, logs the version, and exposes
// `!dag_native_version` from the SE console.
//
// Hooks (camera follow + mouselook, bone reads, SetAnimPlaySpeed,
// CancelAnim, RaycastHitNormal) land in follow-up commits once the
// bridge-less architecture is OK'd and we've picked a hooking toolkit
// (DKUtil, matching NCT and BG3WASD).

#include <windows.h>

#include <filesystem>
#include <fstream>
#include <string>

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
    }
    return TRUE;
}
