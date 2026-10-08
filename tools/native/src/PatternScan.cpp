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

namespace {

// Find a RWX page within ±2GB of `nearAddr` and allocate `size` bytes
// on it. Returns nullptr if nothing in range is free.
//
// Why ±2GB: our 5-byte CALL carries a 32-bit relative displacement.
// Call-site + 5 ± INT32_MAX = ± ~2.14 GB. Caller must land in that
// window so WriteCall5 can reach it.
uint8_t* AllocNearRWX(void* nearAddr, size_t size)
{
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    const uintptr_t gran = si.dwAllocationGranularity;
    const uintptr_t anchor = reinterpret_cast<uintptr_t>(nearAddr);
    const uintptr_t rangeHi = 0x7FFF0000ULL;  // leave ~64KB headroom under INT32_MAX
    const uintptr_t minAddr = (anchor > rangeHi) ? anchor - rangeHi : 0;
    const uintptr_t maxAddr = anchor + rangeHi;

    auto tryAlloc = [&](uintptr_t probe) -> uint8_t* {
        if (probe < minAddr || probe > maxAddr) return nullptr;
        MEMORY_BASIC_INFORMATION mbi{};
        if (!VirtualQuery(reinterpret_cast<void*>(probe), &mbi, sizeof(mbi))) {
            return nullptr;
        }
        if (mbi.State != MEM_FREE) return nullptr;
        // VirtualAlloc requires granularity-aligned base when a specific
        // address is requested.
        const uintptr_t base = (reinterpret_cast<uintptr_t>(mbi.BaseAddress) + gran - 1) & ~(gran - 1);
        if (base < probe) {
            // Already past probe, nothing to do.
        }
        void* alloc = VirtualAlloc(
            reinterpret_cast<void*>(base),
            size,
            MEM_COMMIT | MEM_RESERVE,
            PAGE_EXECUTE_READWRITE);
        return reinterpret_cast<uint8_t*>(alloc);
    };

    // Sweep upward from the anchor first (common case: anchor is in
    // bg3.exe, free pages above it in user-mode space).
    const uintptr_t startUp = ((anchor + gran) / gran) * gran;
    for (uintptr_t p = startUp; p <= maxAddr; p += gran) {
        if (uint8_t* r = tryAlloc(p)) return r;
    }
    // Then downward.
    uintptr_t p = (anchor / gran) * gran;
    while (p >= minAddr && p >= gran) {
        p -= gran;
        if (uint8_t* r = tryAlloc(p)) return r;
    }
    return nullptr;
}

}  // namespace

uint8_t* InstallFarCall5(uint8_t* callSite, void* newTarget)
{
    if (!callSite || callSite[0] != 0xE8) return nullptr;

    // Fast path: if the target is already in range, use the simple hook.
    const ptrdiff_t direct =
        reinterpret_cast<uint8_t*>(newTarget) - (callSite + 5);
    if (direct <= INT32_MAX && direct >= INT32_MIN) {
        return WriteCall5(callSite, newTarget);
    }

    // Allocate 16-byte stub (12 bytes of code + room for alignment)
    // within ±2GB of the call-site.
    constexpr size_t kStubSize = 16;
    uint8_t* stub = AllocNearRWX(callSite, kStubSize);
    if (!stub) return nullptr;

    // Fill stub with: 48 B8 <abs64> FF E0
    //   MOV RAX, imm64
    //   JMP RAX
    stub[0] = 0x48;
    stub[1] = 0xB8;
    std::memcpy(stub + 2, &newTarget, sizeof(void*));
    stub[10] = 0xFF;
    stub[11] = 0xE0;
    std::memset(stub + 12, 0xCC, kStubSize - 12);  // INT3 padding
    FlushInstructionCache(GetCurrentProcess(), stub, kStubSize);

    return WriteCall5(callSite, stub);
}

}  // namespace dag::patternscan
