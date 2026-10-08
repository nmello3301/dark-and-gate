// SPDX-License-Identifier: GPL-3.0-or-later
//
// Memory-probe helpers used by the camera hook when it dereferences
// pointers from unknown structs (candidate character pointers, etc.).
//
// Uses __try/__except (SEH) rather than IsBadReadPtr. SEH actually
// catches the access violation; IsBadReadPtr is advisory and racy.
//
// SEH requires the surrounding function to have no C++ objects with
// non-trivial destructors in scope at the __try block, hence these
// are plain free functions with POD arguments only.

#pragma once

#include <windows.h>
#include <cstdint>
#include <cstring>

namespace dag::safemem {

inline bool ReadBytes(const void* addr, void* out, size_t n)
{
    if (!addr) return false;
    __try {
        std::memcpy(out, addr, n);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

inline bool ReadPtr(const void* base, uint32_t off, void*& out)
{
    if (!base) return false;
    const void* addr = reinterpret_cast<const uint8_t*>(base) + off;
    return ReadBytes(addr, &out, sizeof(void*));
}

inline bool ReadFloat3(const void* base, uint32_t off, float out[3])
{
    if (!base) return false;
    const void* addr = reinterpret_cast<const uint8_t*>(base) + off;
    if (!ReadBytes(addr, out, sizeof(float) * 3)) return false;
    // Reject NaN/Inf without pulling in <cmath>'s isfinite (keeps header light).
    for (int i = 0; i < 3; ++i) {
        uint32_t bits;
        std::memcpy(&bits, &out[i], 4);
        const uint32_t exp = (bits >> 23) & 0xFF;
        if (exp == 0xFF) return false;  // Inf or NaN
    }
    return true;
}

inline bool ReadFloat(const void* base, uint32_t off, float& out)
{
    if (!base) return false;
    const void* addr = reinterpret_cast<const uint8_t*>(base) + off;
    return ReadBytes(addr, &out, sizeof(float));
}

}  // namespace dag::safemem
