// SPDX-License-Identifier: GPL-3.0-or-later
//
// Spell animation gameplay event capture. See GenomeCapture.h and
// docs/spikes/genome-capture.md (static RE, bg3_dx11.exe Patch 8).
//
// The spell genome event builder (rva 0x4208030) fills a stack object
//   +0x00 FixedString Event, +0x08 GenomeParametrizedEventArgs (vtable),
//   +0x10 GenomeVariant[22] { void* Value; GenomeVarTypeDesc* Type; }
// through a chain of tail-called fillers (args 20..0, back to front). The
// last filler tail-jumps into the AnimationBlueprintSystem queue
//   void Queue(AnimationBlueprintSystem*, EntityHandle const*, Event*)
// which moves the event into GameplayEventsToGenome under its lock. The
// queue has ~110 callers (every client gameplay event for the blueprint),
// so we detour its entry: the first instruction `mov [rsp+10h], rbx` (5
// bytes, not RIP-relative, not a branch) is stolen into a trampoline.
// Every queued event is logged with the caller's return address, then
// the original runs unchanged. Nothing is written to the event. If the
// entry bytes differ we fall back to the old single-site hook on the spell
// builder's tail jump.

#include "GenomeCapture.h"

#include <windows.h>

#include <atomic>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <intrin.h>

#include "../Log.h"
#include "../PatternScan.h"
#include "AnimRate.h"

namespace dag::genomecapture {

namespace {

// End of the last arg filler (rva 0x420adb0): ... lea rcx,[r14+0x10];
// call <assign>; mov r8,r14; mov rdx,r12; mov rcx,r15; <epilogue>;
// jmp <queue>. The leading `mov rdx,[rdx+0x10]; jmp rel32` makes it
// unique in .text (two sibling fillers end in the same bytes after a
// short jmp). The E9 sits at +61 (rva 0x420af68).
constexpr const char* kJmpPattern =
    "48 8B 52 10 E9 ?? ?? ?? ?? 48 8B 5A 10 4C 8D 44 24 70 48 8B D3 "
    "49 8D 4E 10 E8 ?? ?? ?? ?? 4D 8B C6 49 8B D4 49 8B CF "
    "48 8B 5C 24 58 48 8B 6C 24 60 48 83 C4 20 41 5F 41 5E 41 5C 5F 5E E9";
constexpr size_t kJmpOffset = 61;

// Prologue of the queue (rva 0x3bd4b90, unique). The jump target must be
// this function or we leave the code alone.
constexpr const char* kQueuePattern =
    "48 89 5C 24 10 56 57 41 56 48 81 EC C0 01 00 00 48 8B 05 ?? ?? ?? ?? "
    "48 33 C4 48 89 84 24 B0 01 00 00";

// First instruction of the queue, stolen by the entry detour.
constexpr uint8_t kQueueEntry[5] = {0x48, 0x89, 0x5C, 0x24, 0x10};  // mov [rsp+10h], rbx

// Spell-area events queued by the client spell code (static RE, see
// docs/spikes/genome-capture.md), matched on the first 8 hex digits.
struct KnownEvent { const char* prefix; const char* tag; };
constexpr KnownEvent kKnownEvents[] = {
    {"ba293d56", " [SPELL]"},       // cast/recover, 22 args (builder 0x4208030)
    {"e8545375", " [SPELL-PREP]"},  // prepare/loop, 9 args (builder 0x4207c40)
    {"43b4462a", " [SPELL-SIDE]"},  // 0x4209360, after both builders
    {"96516143", " [SPELL-SIDE]"},  // 0x4209520 chain, 3 args
    {"0df4bd9f", " [SPELL-SIDE]"},  // 0x4209660 chain, 4 args
    {"c7bf6c94", " [SPELL-SIDE]"},  // 0x4208d60
    {"4694fea0", " [SPELL-SIDE]"},  // 0x4209060
    {"e9db2a81", " [SPELL-SIDE]"},  // 0x4209830, 1 FS arg
};

const char* TagFor(const char* evName)
{
    for (const KnownEvent& k : kKnownEvents) {
        if (std::strncmp(evName, k.prefix, 8) == 0) return k.tag;
    }
    return "";
}

// Distinct event ids announced in native.log (first occurrence each).
constexpr int kMaxSeen = 128;

constexpr int    kNumArgs     = 22;
constexpr size_t kArgsOff     = 0x10;  // first GenomeVariant in the event object
constexpr size_t kVarSize     = 0x10;
constexpr size_t kTypeNameOff = 0x50;  // GenomeVarTypeDesc::TypeName (FixedString)
constexpr uint32_t kSetMax    = 64;    // sanity cap on ShortNameSet size
// vtable of gn::TGenomeSet<FixedString> (rva, Patch 8; logged as a check only).
constexpr unsigned long long kGenomeSetFsVtRva = 0x564F008;

using QueueFn = void(__fastcall*)(void* system, const uint64_t* entity, uint8_t* evt);

QueueFn volatile  g_orig = nullptr;  // trampoline (entry detour) or the queue itself (tail-jump hook)
uintptr_t         g_modBase = 0;
bool              g_entryDetour = false;
uint32_t          g_seen[kMaxSeen];  // guarded by g_lock
int               g_seenCount = 0;
std::atomic<bool> g_on{false};
std::atomic<long> g_count{0};
std::atomic<bool> g_hasPending{false};

SRWLOCK g_lock = SRWLOCK_INIT;
FILE*   g_file = nullptr;           // guarded by g_lock
char    g_pending[4096];            // summaries for native.log, guarded by g_lock
size_t  g_pendingLen = 0;

bool ReadU64(uint64_t addr, uint64_t* out)
{
    __try {
        *out = *reinterpret_cast<const uint64_t*>(addr);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool ReadU32(uint64_t addr, uint32_t* out)
{
    __try {
        *out = *reinterpret_cast<const uint32_t*>(addr);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool PlausiblePtr(uint64_t v) { return v >= 0x10000 && v < 0x00007FFFFFFFFFFFull; }

void Append(char* buf, size_t cap, size_t* len, const char* fmt, ...)
{
    if (*len + 1 >= cap) return;
    va_list ap;
    va_start(ap, fmt);
    const int n = std::vsnprintf(buf + *len, cap - *len, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    *len += (static_cast<size_t>(n) < cap - *len) ? static_cast<size_t>(n) : cap - *len - 1;
}

void FsOrDash(uint32_t id, char* out, size_t cap)
{
    if (!dag::animrate::FsText(id, out, cap)) std::snprintf(out, cap, "-");
}

// One event -> one line for the capture file and a short summary.
// Returns the event's FixedString id (for the native.log first-seen filter).
uint32_t FormatEvent(const uint64_t* entity, const uint8_t* evt, uintptr_t caller, char* line,
                     size_t cap, char* summary, size_t scap)
{
    size_t len = 0;
    const uintptr_t base = reinterpret_cast<uintptr_t>(evt);

    uint32_t evId = 0xffffffffu;
    ReadU32(base, &evId);
    char evName[128];
    FsOrDash(evId, evName, sizeof(evName));
    const char* tag = TagFor(evName);
    const unsigned long long from =
        (caller > g_modBase && g_modBase) ? caller - g_modBase : static_cast<unsigned long long>(caller);

    uint64_t ent = 0;
    ReadU64(reinterpret_cast<uintptr_t>(entity), &ent);

    int typed = 0;
    for (int i = 0; i < kNumArgs; ++i) {
        uint64_t type = 0;
        if (ReadU64(base + kArgsOff + i * kVarSize + 8, &type) && type) ++typed;
    }

    const long n = ++g_count;
    Append(line, cap, &len, "t=%llu #%ld%s ev=%s (0x%08X) from=rva 0x%llX ent=0x%016llX args=%d",
           static_cast<unsigned long long>(GetTickCount64()), n, tag, evName, evId, from,
           static_cast<unsigned long long>(ent), typed);
    std::snprintf(summary, scap, "GENOME: #%ld%s ev=%s from=0x%llX ent=0x%llX args=%d", n, tag,
                  evName, from, static_cast<unsigned long long>(ent), typed);

    for (int i = 0; i < kNumArgs; ++i) {
        const uintptr_t var = base + kArgsOff + i * kVarSize;
        uint64_t value = 0, type = 0;
        if (!ReadU64(var, &value) || !ReadU64(var + 8, &type)) {
            Append(line, cap, &len, " | %d <unreadable>", i);
            continue;
        }
        if (!type) continue;  // unset slot (count above says how many are set)

        uint32_t typeFs = 0xffffffffu;
        char typeName[96];
        if (ReadU32(type + kTypeNameOff, &typeFs)) FsOrDash(typeFs, typeName, sizeof(typeName));
        else std::snprintf(typeName, sizeof(typeName), "-");

        char lo[128];
        FsOrDash(static_cast<uint32_t>(value), lo, sizeof(lo));
        Append(line, cap, &len, " | %d %s v=0x%016llX lo=%s", i, typeName,
               static_cast<unsigned long long>(value), lo);

        // FixedString-like types: Value may be the id itself (lo=) or a
        // pointer to it (deref=).
        if (std::strstr(typeName, "SimpleName") || std::strstr(typeName, "FixedString")) {
            uint32_t inner = 0xffffffffu;
            char deref[128];
            if (PlausiblePtr(value) && ReadU32(value, &inner)) FsOrDash(inner, deref, sizeof(deref));
            else std::snprintf(deref, sizeof(deref), "-");
            Append(line, cap, &len, " deref=%s", deref);
        }

        // Set types (ShortNameSet = gn::TGenomeSet<FixedString>): Value is a
        // heap object { vtable; bool IsOwned @+8; Values* @+0x10 } and
        // Values is { u32* Buf; u32 Capacity @+8; u32 Size @+0xC }. Ids are
        // u32 FixedString indices, 0xFFFFFFFF = null. Read-only, no add-ref.
        if (std::strstr(typeName, "Set") && PlausiblePtr(value)) {
            uint64_t vt = 0, owned = 0, vs = 0;
            ReadU64(value, &vt);
            ReadU64(value + 8, &owned);
            ReadU64(value + 0x10, &vs);
            const unsigned long long vtRva =
                (vt > g_modBase && g_modBase) ? vt - g_modBase : static_cast<unsigned long long>(vt);
            Append(line, cap, &len, " vt=rva 0x%llX%s owned=%u", vtRva,
                   vtRva == kGenomeSetFsVtRva ? "" : "(unexpected)", static_cast<unsigned>(owned & 0xFF));
            uint64_t buf = 0;
            uint32_t capacity = 0, size = 0;
            if (!vs) {
                Append(line, cap, &len, " set=[] (no Values)");
            } else if (!PlausiblePtr(vs) || !ReadU64(vs, &buf) || !ReadU32(vs + 8, &capacity) ||
                       !ReadU32(vs + 0xC, &size)) {
                Append(line, cap, &len, " set=<unreadable Values 0x%llX>", static_cast<unsigned long long>(vs));
            } else if (size > capacity || size > kSetMax || (size && !PlausiblePtr(buf))) {
                Append(line, cap, &len, " set=<implausible n=%u cap=%u buf=0x%llX>", size, capacity,
                       static_cast<unsigned long long>(buf));
            } else {
                Append(line, cap, &len, " n=%u cap=%u set=[", size, capacity);
                for (uint32_t k = 0; k < size; ++k) {
                    uint32_t id = 0xffffffffu;
                    char txt[128];
                    if (!ReadU32(buf + k * 4, &id)) std::snprintf(txt, sizeof(txt), "<unreadable>");
                    else if (id == 0xffffffffu) std::snprintf(txt, sizeof(txt), "null");
                    else FsOrDash(id, txt, sizeof(txt));
                    Append(line, cap, &len, "%s%s", k ? " " : "", txt);
                }
                Append(line, cap, &len, "]");
            }
        }
    }
    return evId;
}

void Capture(const uint64_t* entity, const uint8_t* evt, uintptr_t caller)
{
    char line[12288];
    char summary[256];
    line[0] = 0;
    summary[0] = 0;
    const uint32_t evId = FormatEvent(entity, evt, caller, line, sizeof(line), summary, sizeof(summary));
    const bool spell = std::strstr(summary, "[SPELL") != nullptr;

    AcquireSRWLockExclusive(&g_lock);
    if (g_file) {  // flushed once per frame in DrainPending
        std::fputs(line, g_file);
        std::fputc('\n', g_file);
    }
    // native.log gets spell events and the first occurrence of every other
    // event id; the capture file has everything.
    bool announce = spell;
    if (!announce) {
        bool seen = false;
        for (int i = 0; i < g_seenCount && !seen; ++i) seen = g_seen[i] == evId;
        if (!seen && g_seenCount < kMaxSeen) {
            g_seen[g_seenCount++] = evId;
            announce = true;
        }
    }
    const size_t sl = std::strlen(summary);
    if (announce && g_pendingLen + sl + 2 < sizeof(g_pending)) {
        std::memcpy(g_pending + g_pendingLen, summary, sl);
        g_pendingLen += sl;
        g_pending[g_pendingLen++] = '\n';
        g_pending[g_pendingLen] = 0;
        g_hasPending.store(true, std::memory_order_release);
    }
    ReleaseSRWLockExclusive(&g_lock);
}

// Entry detour: runs instead of the queue for every caller. The return
// address is the caller's (the stub reached us with a jmp), or for a
// tail-jumping caller the caller's caller.
__declspec(noinline) void __fastcall QueueDetour(void* system, const uint64_t* entity, uint8_t* evt)
{
    if (g_on.load(std::memory_order_relaxed) && entity && evt) {
        Capture(entity, evt, reinterpret_cast<uintptr_t>(_ReturnAddress()));
    }
    g_orig(system, entity, evt);
}

// Fallback: runs as the queue itself, reached from the spell builder's
// patched tail jump only.
__declspec(noinline) void __fastcall QueueThunk(void* system, const uint64_t* entity, uint8_t* evt)
{
    if (g_on.load(std::memory_order_relaxed) && entity && evt) {
        Capture(entity, evt, reinterpret_cast<uintptr_t>(_ReturnAddress()));
    }
    g_orig(system, entity, evt);
}

FILE* OpenCaptureFile()
{
    wchar_t dir[MAX_PATH];
    const DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", dir, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return nullptr;
    wchar_t path[MAX_PATH * 2];
    swprintf_s(path, MAX_PATH * 2,
               L"%s\\Larian Studios\\Baldur's Gate 3\\Script Extender\\DarkAndGate\\native-genome-capture.txt",
               dir);
    FILE* f = nullptr;
    if (_wfopen_s(&f, path, L"w") != 0) return nullptr;
    return f;
}

void DrainPending()
{
    if (g_on.load(std::memory_order_relaxed)) {
        AcquireSRWLockExclusive(&g_lock);
        if (g_file) std::fflush(g_file);
        ReleaseSRWLockExclusive(&g_lock);
    }
    if (!g_hasPending.load(std::memory_order_acquire)) return;
    char local[sizeof(g_pending)];
    AcquireSRWLockExclusive(&g_lock);
    std::memcpy(local, g_pending, g_pendingLen + 1);
    g_pendingLen = 0;
    g_pending[0] = 0;
    g_hasPending.store(false, std::memory_order_relaxed);
    ReleaseSRWLockExclusive(&g_lock);

    char* ctx = nullptr;
    for (char* tok = strtok_s(local, "\n", &ctx); tok; tok = strtok_s(nullptr, "\n", &ctx)) {
        dag::log::Writef("%s", tok);
    }
}

bool g_wasOn = false;  // frame thread only

}  // namespace

namespace {

// Old single-site hook: the spell builder's tail jump into the queue.
bool InstallTailJump(HMODULE mod, uint8_t* queue)
{
    uint8_t* p = dag::patternscan::Find(mod, kJmpPattern);
    if (!p) {
        dag::log::Writef("GENOME: tail-jump pattern not found (capture unavailable)");
        return false;
    }
    uint8_t* site = p + kJmpOffset;
    int32_t disp = 0;
    std::memcpy(&disp, site + 1, sizeof(disp));
    uint8_t* target = site + 5 + disp;
    if (target != queue) {
        dag::log::Writef("GENOME: tail jump does not target the queue (rva 0x%llX), not patched",
                         static_cast<unsigned long long>(target - reinterpret_cast<uint8_t*>(mod)));
        return false;
    }
    g_orig = reinterpret_cast<QueueFn>(target);  // set before the patch goes live
    if (!dag::patternscan::InstallFarJmp5(site, reinterpret_cast<void*>(&QueueThunk))) {
        g_orig = nullptr;
        dag::log::Writef("GENOME: tail-jump patch failed (no near stub), capture unavailable");
        return false;
    }
    dag::log::Writef("GENOME: fallback hook on the spell tail jump at rva 0x%llX (spell events only)",
                     static_cast<unsigned long long>(site - reinterpret_cast<uint8_t*>(mod)));
    return true;
}

}  // namespace

void Install()
{
    HMODULE mod = GetModuleHandleW(nullptr);
    g_modBase = reinterpret_cast<uintptr_t>(mod);
    uint8_t* queue = dag::patternscan::Find(mod, kQueuePattern);
    if (!queue) {
        dag::log::Writef("GENOME: blueprint queue prologue not found (capture unavailable)");
        return;
    }
    // Entry detour first; it sees every caller, so the tail-jump hook is
    // not installed with it (no double logging).
    // g_orig is written by the helper before the entry is patched.
    if (dag::patternscan::InstallEntryDetour(queue, kQueueEntry, sizeof(kQueueEntry),
                                             reinterpret_cast<void*>(&QueueDetour),
                                             reinterpret_cast<void* volatile*>(&g_orig))) {
        g_entryDetour = true;
        dag::log::Writef("GENOME: entry detour on the blueprint queue at rva 0x%llX (all events)",
                         static_cast<unsigned long long>(queue - reinterpret_cast<uint8_t*>(mod)));
        return;
    }
    dag::log::Writef("GENOME: entry detour refused (prologue bytes differ or no near memory)");
    InstallTailJump(mod, queue);
}

void SetCapture(bool on)
{
    if (on != g_wasOn) {
        g_wasOn = on;
        if (on) {
            char warm[8];
            dag::animrate::FsText(0xffffffffu, warm, sizeof(warm));  // find the string table here, not on a worker
            FILE* f = OpenCaptureFile();
            AcquireSRWLockExclusive(&g_lock);
            g_file = f;
            ReleaseSRWLockExclusive(&g_lock);
            g_count = 0;
            AcquireSRWLockExclusive(&g_lock);
            g_seenCount = 0;
            ReleaseSRWLockExclusive(&g_lock);
            g_on = (f != nullptr) && g_orig != nullptr;
            dag::log::Writef("GENOME: capture ON (%s, %s)", !g_orig ? "hook not installed"
                             : f ? "native-genome-capture.txt" : "could not open file",
                             g_entryDetour ? "all events via queue entry detour" : "spell tail jump only");
        } else {
            g_on = false;
            AcquireSRWLockExclusive(&g_lock);
            FILE* f = g_file;
            g_file = nullptr;
            ReleaseSRWLockExclusive(&g_lock);
            if (f) std::fclose(f);
            dag::log::Writef("GENOME: capture OFF (%ld events)", g_count.load());
        }
    }
    DrainPending();
}

}  // namespace dag::genomecapture
