// SPDX-License-Identifier: GPL-3.0-or-later

#include "PatternScan.h"

#include <windows.h>

#include <cctype>
#include <cstdlib>
#include <cstring>
#include <intrin.h>
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

uint8_t* AllocNear(void* nearAddr, size_t size)
{
    return AllocNearRWX(nearAddr, size);
}

bool PatchCode(uint8_t* at, const uint8_t* bytes, size_t n)
{
    if (!at || !bytes || n == 0 || n > 8) return false;
    uint8_t* blk = reinterpret_cast<uint8_t*>(reinterpret_cast<uintptr_t>(at) & ~uintptr_t(7));
    const size_t off = static_cast<size_t>(at - blk);
    DWORD old = 0;
    if (!VirtualProtect(blk, 16, PAGE_EXECUTE_READWRITE, &old)) return false;
    if (off + n <= 8) {
        // One aligned 8-byte store: a thread running that code sees the old
        // or the new instruction, never half of each.
        uint64_t cur = 0;
        std::memcpy(&cur, blk, 8);
        std::memcpy(reinterpret_cast<uint8_t*>(&cur) + off, bytes, n);
        _InterlockedExchange64(reinterpret_cast<volatile long long*>(blk), static_cast<long long>(cur));
    } else {
        std::memcpy(at, bytes, n);
    }
    DWORD tmp = 0;
    VirtualProtect(blk, 16, old, &tmp);
    FlushInstructionCache(GetCurrentProcess(), blk, 16);
    return true;
}

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

uint8_t* InstallFarJmp5(uint8_t* jmpSite, void* newTarget)
{
    if (!jmpSite || jmpSite[0] != 0xE9) return nullptr;
    int32_t oldDisp;
    std::memcpy(&oldDisp, jmpSite + 1, sizeof(oldDisp));
    uint8_t* oldTarget = jmpSite + 5 + oldDisp;

    // Same 12-byte MOV RAX / JMP RAX stub as InstallFarCall5. RAX is
    // volatile at a tail jump, so clobbering it is safe.
    void* reach = newTarget;
    const ptrdiff_t direct = reinterpret_cast<uint8_t*>(newTarget) - (jmpSite + 5);
    if (direct > INT32_MAX || direct < INT32_MIN) {
        constexpr size_t kStubSize = 16;
        uint8_t* stub = AllocNearRWX(jmpSite, kStubSize);
        if (!stub) return nullptr;
        stub[0] = 0x48;
        stub[1] = 0xB8;
        std::memcpy(stub + 2, &newTarget, sizeof(void*));
        stub[10] = 0xFF;
        stub[11] = 0xE0;
        std::memset(stub + 12, 0xCC, kStubSize - 12);
        FlushInstructionCache(GetCurrentProcess(), stub, kStubSize);
        reach = stub;
    }

    const int32_t disp32 =
        static_cast<int32_t>(reinterpret_cast<uint8_t*>(reach) - (jmpSite + 5));
    DWORD oldProtect = 0;
    if (!VirtualProtect(jmpSite, 5, PAGE_EXECUTE_READWRITE, &oldProtect)) return nullptr;
    std::memcpy(jmpSite + 1, &disp32, sizeof(disp32));
    DWORD tmp = 0;
    VirtualProtect(jmpSite, 5, oldProtect, &tmp);
    FlushInstructionCache(GetCurrentProcess(), jmpSite, 5);
    return oldTarget;
}

bool InstallEntryDetour(uint8_t* fn, const uint8_t* expected, size_t stolenLen, void* hook,
                        void* volatile* trampolineOut)
{
    if (!fn || !expected || !hook || !trampolineOut || stolenLen < 5 || stolenLen > 8) return false;
    if (std::memcmp(fn, expected, stolenLen) != 0) return false;  // someone patched it, or another build

    // Layout of the 64-byte block (one allocation, near fn):
    //   +0x00 trampoline: <stolen bytes> FF 25 00 00 00 00 <abs64 fn+stolenLen>
    //   +0x20 hook stub:  48 B8 <abs64 hook> FF E0
    constexpr size_t kBlock = 64;
    uint8_t* block = AllocNearRWX(fn, kBlock);
    if (!block) return false;
    std::memset(block, 0xCC, kBlock);
    uint8_t* tramp = block;
    std::memcpy(tramp, fn, stolenLen);
    tramp[stolenLen + 0] = 0xFF;
    tramp[stolenLen + 1] = 0x25;
    std::memset(tramp + stolenLen + 2, 0, 4);
    const uint64_t resume = reinterpret_cast<uint64_t>(fn + stolenLen);
    std::memcpy(tramp + stolenLen + 6, &resume, sizeof(resume));
    uint8_t* stub = block + 0x20;
    stub[0] = 0x48;
    stub[1] = 0xB8;
    std::memcpy(stub + 2, &hook, sizeof(void*));
    stub[10] = 0xFF;
    stub[11] = 0xE0;
    FlushInstructionCache(GetCurrentProcess(), block, kBlock);
    *trampolineOut = tramp;
    MemoryBarrier();

    // New first 8 bytes: E9 rel32 to the stub, NOPs over the rest of the
    // stolen bytes, original bytes after them.
    uint8_t patch[8];
    std::memcpy(patch, fn, 8);
    const int32_t disp = static_cast<int32_t>(stub - (fn + 5));
    patch[0] = 0xE9;
    std::memcpy(patch + 1, &disp, sizeof(disp));
    for (size_t i = 5; i < stolenLen; ++i) patch[i] = 0x90;

    DWORD oldProtect = 0;
    if (!VirtualProtect(fn, 8, PAGE_EXECUTE_READWRITE, &oldProtect)) {
        *trampolineOut = nullptr;
        return false;
    }
    if ((reinterpret_cast<uintptr_t>(fn) & 7) == 0) {
        int64_t v;
        std::memcpy(&v, patch, sizeof(v));
        _InterlockedExchange64(reinterpret_cast<volatile long long*>(fn), v);  // no torn instruction
    } else {
        std::memcpy(fn, patch, 8);
    }
    DWORD tmp = 0;
    VirtualProtect(fn, 8, oldProtect, &tmp);
    FlushInstructionCache(GetCurrentProcess(), fn, 8);
    return true;
}

}  // namespace dag::patternscan
