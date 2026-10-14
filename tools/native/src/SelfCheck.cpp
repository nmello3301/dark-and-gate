// SPDX-License-Identifier: GPL-3.0-or-later

#include "SelfCheck.h"

#include <windows.h>
#include <bcrypt.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <string>
#include <vector>

#include "Log.h"
#include "PatternScan.h"
#include "build_info.h"

#pragma comment(lib, "bcrypt.lib")

namespace dag::selfcheck {

namespace {

// The exe builds this DLL was made for (Patch 8, Steam, installed
// 2026-10-07). Size + SHA-256 of the file.
struct KnownExe { const wchar_t* name; uint64_t size; const char* sha256; };
constexpr KnownExe kVanilla[] = {
    { L"bg3_dx11.exe", 104354368ull, "6fa3cd43e1ade63c49d7ab9d82231f6e60ff5fc906db62c1be76cd926f37af00" },
    { L"bg3.exe",      107018304ull, "e37dacd2fe5e9b781e44de7220266b9228f23f52c20f73099e9facb2e62ecda0" },
};

// Party Limit Begone's multiplayer patch (Nexus 327, "Multiplayer Patch
// v1.6": XVI32 runs PatchFiles/PLB-MP-Patch.xsc on the exe). Its find /
// replace pairs go here once the .xsc has been read (it isn't published;
// docs/design/multiplayer.md "Party Limit Begone"). Empty = unknown: the
// check says so instead of guessing.
struct PlbPair { const char* find; const char* replace; };
constexpr PlbPair kPlb[] = {
    { nullptr, nullptr },   // placeholder, skipped
};

// RVAs the DLL validates objects against (VtIs) or writes through.
struct VtRva { const char* name; uintptr_t rva; bool vtable; };
constexpr VtRva kRvas[] = {
    { "ecl::Character vtable", 0x56576A0, true },
    { "MSFalling vtable", 0x564F770, true },
    { "steering look-at vtable", 0x56508A0, true },
    { "genome SetFs vtable", 0x564F008, true },
    { "movement transaction counter", 0x5ED576C, false },
};

struct Section { uint32_t va = 0, vsize = 0, raw = 0, rawSize = 0, chars = 0; };

bool FindSection(const IMAGE_NT_HEADERS* nt, const char* name, Section& out)
{
    const IMAGE_SECTION_HEADER* s = IMAGE_FIRST_SECTION(nt);
    for (WORD i = 0; i < nt->FileHeader.NumberOfSections; ++i, ++s) {
        if (std::strncmp(reinterpret_cast<const char*>(s->Name), name, 8) == 0) {
            out = { s->VirtualAddress, s->Misc.VirtualSize, s->PointerToRawData, s->SizeOfRawData, s->Characteristics };
            return true;
        }
    }
    return false;
}

bool Sha256(const uint8_t* data, size_t size, char hex[65])
{
    BCRYPT_ALG_HANDLE alg = nullptr;
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0) return false;
    uint8_t digest[32] = {};
    BCRYPT_HASH_HANDLE h = nullptr;
    bool ok = BCryptCreateHash(alg, &h, nullptr, 0, nullptr, 0, 0) == 0;
    // BCryptHashData takes a ULONG: feed it in chunks.
    for (size_t off = 0; ok && off < size; off += 0x10000000) {
        const size_t n = (size - off) < 0x10000000 ? (size - off) : 0x10000000;
        ok = BCryptHashData(h, const_cast<PUCHAR>(data + off), static_cast<ULONG>(n), 0) == 0;
    }
    if (ok) ok = BCryptFinishHash(h, digest, sizeof(digest), 0) == 0;
    if (h) BCryptDestroyHash(h);
    BCryptCloseAlgorithmProvider(alg, 0);
    if (!ok) return false;
    for (int i = 0; i < 32; ++i) std::snprintf(hex + i * 2, 3, "%02x", digest[i]);
    return true;
}

std::wstring ExeName(const wchar_t* path)
{
    const wchar_t* slash = std::wcsrchr(path, L'\\');
    return slash ? slash + 1 : path;
}

void WriteResult(const char* line)
{
    wchar_t buf[MAX_PATH];
    const DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return;
    std::wstring p = std::wstring(buf) + L"\\Larian Studios\\Baldur's Gate 3\\Script Extender\\DarkAndGate\\native-selfcheck.txt";
    HANDLE f = CreateFileW(p.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    DWORD w = 0;
    WriteFile(f, line, static_cast<DWORD>(std::strlen(line)), &w, nullptr);
    CloseHandle(f);
}

DWORD WINAPI Run(void*)
{
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
    const DWORD t0 = GetTickCount();
    wchar_t path[MAX_PATH * 2] = {};
    GetModuleFileNameW(nullptr, path, MAX_PATH * 2);
    const std::wstring name = ExeName(path);
    char nameA[64] = {};
    WideCharToMultiByte(CP_UTF8, 0, name.c_str(), -1, nameA, sizeof(nameA) - 1, nullptr, nullptr);

    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        dag::log::Writef("SELFCHECK: can't open the exe file (%lu)", GetLastError());
        return 0;
    }
    LARGE_INTEGER fsize = {};
    GetFileSizeEx(file, &fsize);
    HANDLE map = CreateFileMappingW(file, nullptr, PAGE_READONLY, 0, 0, nullptr);
    const uint8_t* img = map ? static_cast<const uint8_t*>(MapViewOfFile(map, FILE_MAP_READ, 0, 0, 0)) : nullptr;
    if (!img) {
        dag::log::Writef("SELFCHECK: can't map the exe file (%lu)", GetLastError());
        if (map) CloseHandle(map);
        CloseHandle(file);
        return 0;
    }
    const size_t size = static_cast<size_t>(fsize.QuadPart);

    // 1. Which exe.
    char sha[65] = "?";
    Sha256(img, size, sha);
    const char* kind = "unknown";
    for (const auto& k : kVanilla)
        if (_wcsicmp(k.name, name.c_str()) == 0 && k.size == size && std::strcmp(k.sha256, sha) == 0) kind = "vanilla";

    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(img);
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(img + dos->e_lfanew);
    Section text;
    const bool haveText = dos->e_magic == IMAGE_DOS_SIGNATURE && nt->Signature == IMAGE_NT_SIGNATURE && FindSection(nt, ".text", text);
    const uint8_t* code = haveText ? img + text.raw : nullptr;
    const size_t codeSize = haveText ? (text.rawSize < text.vsize ? text.rawSize : text.vsize) : 0;

    // PLB: every pair's replace bytes present (and its find bytes gone) = patched.
    int plbPairs = 0, plbPatched = 0, plbVanilla = 0;
    struct Range { uintptr_t rva; size_t len; };
    std::vector<Range> plbRanges;
    for (const auto& p : kPlb) {
        if (!p.find || !p.replace || !code) continue;
        ++plbPairs;
        size_t off = 0;
        if (dag::patternscan::CountMatches(code, codeSize, p.replace, &off, 2) >= 1) {
            ++plbPatched;
            plbRanges.push_back({ text.va + off, (std::strlen(p.replace) + 1) / 3 });
        } else if (dag::patternscan::CountMatches(code, codeSize, p.find, &off, 2) >= 1) {
            ++plbVanilla;
            plbRanges.push_back({ text.va + off, (std::strlen(p.find) + 1) / 3 });
        }
    }
    if (plbPairs > 0 && plbPatched == plbPairs) kind = "plb";
    dag::log::Writef("SELFCHECK: exe %s, %llu bytes, sha256 %.16s... -> %s%s", nameA, static_cast<unsigned long long>(size), sha,
                     std::strcmp(kind, "vanilla") == 0 ? "vanilla (the Patch 8 build this DLL was made for)"
                     : std::strcmp(kind, "plb") == 0   ? "patched (PLB multiplayer patch)"
                                                       : "UNKNOWN build (not the vanilla Patch 8 exe; patterns below say what still resolves)",
                     plbPairs == 0 ? "; PLB patch bytes not known yet (docs/design/multiplayer.md)" : "");
    if (plbPairs > 0)
        dag::log::Writef("SELFCHECK: PLB multiplayer patch: %d of %d changes present, %d still vanilla", plbPatched, plbPairs, plbVanilla);

    // 2. Every pattern the DLL scanned for, in the file.
    const auto scans = dag::patternscan::ScanRecords();
    int found = 0, unique = 0, same = 0, overlap = 0, bad = 0;
    for (const auto& s : scans) {
        size_t off = 0;
        const int n = code ? dag::patternscan::CountMatches(code, codeSize, s.pattern, &off, 3) : -1;
        const uintptr_t fileRva = n > 0 ? text.va + off : 0;
        if (s.rva) ++found;
        if (n == 1) ++unique;
        if (s.rva && fileRva == s.rva) ++same;
        const size_t len = (s.pattern.size() + 1) / 3;
        bool hitsPlb = false;
        for (const auto& r : plbRanges)
            if (fileRva && fileRva < r.rva + r.len && r.rva < fileRva + len) hitsPlb = true;
        if (hitsPlb) ++overlap;
        const bool ok = s.rva && n == 1 && fileRva == s.rva && !hitsPlb;
        if (!ok) {
            ++bad;
            dag::log::Writef("SELFCHECK: pattern %.47s... memory rva 0x%llX, file: %d match(es) at 0x%llX%s%s", s.pattern.c_str(),
                             static_cast<unsigned long long>(s.rva), n, static_cast<unsigned long long>(fileRva),
                             !s.rva ? " -- NOT FOUND in memory" : (n == 0 ? " -- in memory only (another mod patched the file's bytes?)" : ""),
                             hitsPlb ? " -- OVERLAPS a PLB change" : "");
        }
    }
    dag::log::Writef("SELFCHECK: %zu patterns: %d found in memory, %d unique in the exe file, %d at the same address, %d overlap PLB's changes",
                     scans.size(), found, unique, same, overlap);

    // 3. Patch sites against PLB's changes.
    const auto patches = dag::patternscan::PatchRecords();
    int patchOverlap = 0;
    for (const auto& p : patches)
        for (const auto& r : plbRanges)
            if (p.rva < r.rva + r.len && r.rva < p.rva + p.len) {
                ++patchOverlap;
                dag::log::Writef("SELFCHECK: patch site 0x%llX (%s, %zu bytes) OVERLAPS a PLB change at 0x%llX",
                                 static_cast<unsigned long long>(p.rva), p.kind, p.len, static_cast<unsigned long long>(r.rva));
            }
    dag::log::Writef("SELFCHECK: %zu code patch sites so far, %d overlap PLB's changes%s", patches.size(), patchOverlap,
                     plbRanges.empty() ? " (PLB's changes not known yet)" : "");

    // 4. RVAs, checked in memory: a vtable's first slot must point into code.
    const auto base = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
    const auto* mnt = reinterpret_cast<const IMAGE_NT_HEADERS*>(base + reinterpret_cast<const IMAGE_DOS_HEADER*>(base)->e_lfanew);
    Section mtext;
    FindSection(mnt, ".text", mtext);
    int rvaOk = 0;
    for (const auto& v : kRvas) {
        bool ok = false;
        if (v.rva < mnt->OptionalHeader.SizeOfImage) {
            if (v.vtable) {
                uintptr_t slot0 = 0;
                std::memcpy(&slot0, reinterpret_cast<const void*>(base + v.rva), sizeof(slot0));
                ok = slot0 >= base + mtext.va && slot0 < base + mtext.va + mtext.vsize;
            } else {
                ok = true;   // a data address: in the image is all we can say
            }
        }
        if (ok) ++rvaOk;
        else dag::log::Writef("SELFCHECK: %s rva 0x%llX doesn't look right -- the exe build differs", v.name, static_cast<unsigned long long>(v.rva));
    }
    dag::log::Writef("SELFCHECK: %d of %zu fixed RVAs look right; done in %lu ms", rvaOk, sizeof(kRvas) / sizeof(kRvas[0]), GetTickCount() - t0);

    char line[512];
    std::snprintf(line, sizeof(line),
                  "exe=%s exe_name=%s exe_sha=%.12s dll_build=%s patterns=%zu found=%d unique=%d same=%d plb_overlap=%d patch_overlap=%d rvas=%d/%zu plb_known=%d t=%lu\n",
                  kind, nameA, sha, DllBuild(), scans.size(), found, unique, same, overlap, patchOverlap, rvaOk,
                  sizeof(kRvas) / sizeof(kRvas[0]), plbPairs > 0 ? 1 : 0, GetTickCount());
    WriteResult(line);

    UnmapViewOfFile(img);
    CloseHandle(map);
    CloseHandle(file);
    return 0;
}

}  // namespace

const char* DllBuild() { return DAG_DLL_BUILD; }

void Start()
{
    HANDLE t = CreateThread(nullptr, 0, &Run, nullptr, 0, nullptr);
    if (t) CloseHandle(t);
    else dag::log::Writef("SELFCHECK: couldn't start its thread (%lu)", GetLastError());
}

}  // namespace dag::selfcheck
