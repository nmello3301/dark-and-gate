// SPDX-License-Identifier: GPL-3.0-or-later

#include "PatternScan.h"

#include <windows.h>

#include <cctype>
#include <cstdlib>
#include <vector>

namespace dag::patternscan {

namespace {

struct Compiled {
    std::vector<uint8_t> bytes;
    std::vector<bool>    mask;  // true = exact match, false = wildcard
};

bool CompilePattern(std::string_view s, Compiled& out)
{
    out.bytes.clear();
    out.mask.clear();
    size_t i = 0;
    while (i < s.size()) {
        while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i]))) ++i;
        if (i >= s.size()) break;
        if (i + 1 >= s.size()) return false;

        char c0 = s[i], c1 = s[i + 1];
        if (c0 == '?' && c1 == '?') {
            out.bytes.push_back(0);
            out.mask.push_back(false);
        } else {
            auto hexVal = [](char c) -> int {
                if (c >= '0' && c <= '9') return c - '0';
                if (c >= 'a' && c <= 'f') return 10 + (c - 'a');
                if (c >= 'A' && c <= 'F') return 10 + (c - 'A');
                return -1;
            };
            int h = hexVal(c0), l = hexVal(c1);
            if (h < 0 || l < 0) return false;
            out.bytes.push_back(static_cast<uint8_t>((h << 4) | l));
            out.mask.push_back(true);
        }
        i += 2;
    }
    return !out.bytes.empty();
}

// Grabs the .text (code) section of the module.
bool GetTextSection(void* module, uint8_t** base, size_t* size)
{
    auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(module);
    if (!dos || dos->e_magic != IMAGE_DOS_SIGNATURE) return false;

    auto* nt = reinterpret_cast<IMAGE_NT_HEADERS*>(
        reinterpret_cast<uint8_t*>(module) + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return false;

    auto* section = IMAGE_FIRST_SECTION(nt);
    for (WORD i = 0; i < nt->FileHeader.NumberOfSections; ++i, ++section) {
        if (memcmp(section->Name, ".text", 5) == 0) {
            *base = reinterpret_cast<uint8_t*>(module) + section->VirtualAddress;
            *size = section->Misc.VirtualSize;
            return true;
        }
    }
    return false;
}

}  // namespace

uint8_t* Find(void* module, std::string_view patternIdaStyle)
{
    if (!module) module = GetModuleHandleW(nullptr);

    Compiled c;
    if (!CompilePattern(patternIdaStyle, c)) return nullptr;

    uint8_t* base = nullptr;
    size_t   size = 0;
    if (!GetTextSection(module, &base, &size)) return nullptr;
    if (c.bytes.size() > size) return nullptr;

    const size_t last = size - c.bytes.size();
    for (size_t i = 0; i <= last; ++i) {
        bool ok = true;
        for (size_t j = 0; j < c.bytes.size(); ++j) {
            if (c.mask[j] && base[i + j] != c.bytes[j]) { ok = false; break; }
        }
        if (ok) return base + i;
    }
    return nullptr;
}

uint8_t* DecodeRelCallTarget(uint8_t* callSite)
{
    if (!callSite || callSite[0] != 0xE8) return nullptr;
    int32_t disp;
    std::memcpy(&disp, callSite + 1, sizeof(disp));
    return callSite + 5 + disp;
}

uint8_t* WriteCall5(uint8_t* callSite, void* newTarget)
{
    if (!callSite || callSite[0] != 0xE8) return nullptr;
    uint8_t* oldTarget = DecodeRelCallTarget(callSite);
    if (!oldTarget) return nullptr;

    const ptrdiff_t newDisp =
        reinterpret_cast<uint8_t*>(newTarget) - (callSite + 5);
    if (newDisp > INT32_MAX || newDisp < INT32_MIN) return nullptr;
    const int32_t disp32 = static_cast<int32_t>(newDisp);

    DWORD oldProtect = 0;
    if (!VirtualProtect(callSite, 5, PAGE_EXECUTE_READWRITE, &oldProtect)) {
        return nullptr;
    }
    std::memcpy(callSite + 1, &disp32, sizeof(disp32));
    DWORD tmp = 0;
    VirtualProtect(callSite, 5, oldProtect, &tmp);
    FlushInstructionCache(GetCurrentProcess(), callSite, 5);

    return oldTarget;
}

}  // namespace dag::patternscan
