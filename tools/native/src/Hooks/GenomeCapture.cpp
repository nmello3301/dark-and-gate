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
// which moves the event into GameplayEventsToGenome under its lock. We
// patch that one tail jump: our thunk sees the fully built event, logs it
// and then calls the queue unchanged. Nothing is written to the event.

#include "GenomeCapture.h"

#include <windows.h>

#include <atomic>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>

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

// Main spell event (blueprint node with 21 outputs, docs/spikes/spell-anims-native.md).
constexpr const char* kSpellEvent = "ba293d56-e14d-4d62-8151-4d63f1257bcd";

constexpr int    kNumArgs     = 22;
constexpr size_t kArgsOff     = 0x10;  // first GenomeVariant in the event object
constexpr size_t kVarSize     = 0x10;
constexpr size_t kTypeNameOff = 0x50;  // GenomeVarTypeDesc::TypeName (FixedString)
constexpr int    kSetDump     = 8;     // qwords dumped behind a set-like Value

using QueueFn = void(__fastcall*)(void* system, const uint64_t* entity, uint8_t* evt);

QueueFn           g_orig = nullptr;
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
void FormatEvent(const uint64_t* entity, const uint8_t* evt, char* line, size_t cap,
                 char* summary, size_t scap)
{
    size_t len = 0;
    const uintptr_t base = reinterpret_cast<uintptr_t>(evt);

    uint32_t evId = 0xffffffffu;
    ReadU32(base, &evId);
    char evName[128];
    FsOrDash(evId, evName, sizeof(evName));
    const bool spell = std::strcmp(evName, kSpellEvent) == 0;

    uint64_t ent = 0;
    ReadU64(reinterpret_cast<uintptr_t>(entity), &ent);

    int typed = 0;
    for (int i = 0; i < kNumArgs; ++i) {
        uint64_t type = 0;
        if (ReadU64(base + kArgsOff + i * kVarSize + 8, &type) && type) ++typed;
    }

    const long n = ++g_count;
    Append(line, cap, &len, "t=%llu #%ld%s ev=%s (0x%08X) ent=0x%016llX args=%d",
           static_cast<unsigned long long>(GetTickCount64()), n, spell ? " [SPELL]" : "",
           evName, evId, static_cast<unsigned long long>(ent), typed);
    std::snprintf(summary, scap, "GENOME: #%ld%s ev=%s ent=0x%llX args=%d", n,
                  spell ? " [SPELL]" : "", evName, static_cast<unsigned long long>(ent), typed);

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

        // Set-like types (ShortNameSet...): dump what Value points at, and
        // try the first qword as an array of FixedStrings.
        if (std::strstr(typeName, "Set") && PlausiblePtr(value)) {
            Append(line, cap, &len, " q=[");
            uint64_t q[kSetDump] = {};
            int got = 0;
            for (; got < kSetDump; ++got) {
                if (!ReadU64(value + got * 8, &q[got])) break;
                Append(line, cap, &len, "%s%llX", got ? " " : "", static_cast<unsigned long long>(q[got]));
            }
            Append(line, cap, &len, "]");
            if (got > 0 && PlausiblePtr(q[0])) {
                Append(line, cap, &len, " fs0=[");
                for (int k = 0; k < kSetDump; ++k) {
                    uint32_t id = 0;
                    if (!ReadU32(q[0] + k * 4, &id)) break;
                    char txt[96];
                    FsOrDash(id, txt, sizeof(txt));
                    Append(line, cap, &len, "%s%s", k ? " " : "", txt);
                }
                Append(line, cap, &len, "]");
            }
        }
    }
}

void Capture(const uint64_t* entity, const uint8_t* evt)
{
    char line[12288];
    char summary[256];
    line[0] = 0;
    summary[0] = 0;
    FormatEvent(entity, evt, line, sizeof(line), summary, sizeof(summary));

    AcquireSRWLockExclusive(&g_lock);
    if (g_file) {
        std::fputs(line, g_file);
        std::fputc('\n', g_file);
        std::fflush(g_file);
    }
    const size_t sl = std::strlen(summary);
    if (g_pendingLen + sl + 2 < sizeof(g_pending)) {
        std::memcpy(g_pending + g_pendingLen, summary, sl);
        g_pendingLen += sl;
        g_pending[g_pendingLen++] = '\n';
        g_pending[g_pendingLen] = 0;
        g_hasPending.store(true, std::memory_order_release);
    }
    ReleaseSRWLockExclusive(&g_lock);
}

// Runs as the queue function itself (the filler tail-jumped here).
void __fastcall QueueThunk(void* system, const uint64_t* entity, uint8_t* evt)
{
    if (g_on.load(std::memory_order_relaxed) && entity && evt) Capture(entity, evt);
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

void Install()
{
    HMODULE mod = GetModuleHandleW(nullptr);
    uint8_t* p = dag::patternscan::Find(mod, kJmpPattern);
    if (!p) {
        dag::log::Writef("GENOME: tail-jump pattern not found (capture unavailable)");
        return;
    }
    uint8_t* site = p + kJmpOffset;
    int32_t disp = 0;
    std::memcpy(&disp, site + 1, sizeof(disp));
    uint8_t* target = site + 5 + disp;
    uint8_t* queue = dag::patternscan::Find(mod, kQueuePattern);
    if (!queue || queue != target) {
        dag::log::Writef("GENOME: jump target is not the blueprint queue (target rva 0x%llX, queue %s), not patched",
                         static_cast<unsigned long long>(target - reinterpret_cast<uint8_t*>(mod)),
                         queue ? "elsewhere" : "not found");
        return;
    }
    g_orig = reinterpret_cast<QueueFn>(target);  // set before the patch goes live
    if (!dag::patternscan::InstallFarJmp5(site, reinterpret_cast<void*>(&QueueThunk))) {
        dag::log::Writef("GENOME: patch failed (no near stub), capture unavailable");
        return;
    }
    dag::log::Writef("GENOME: capture hook at rva 0x%llX -> queue rva 0x%llX",
                     static_cast<unsigned long long>(site - reinterpret_cast<uint8_t*>(mod)),
                     static_cast<unsigned long long>(target - reinterpret_cast<uint8_t*>(mod)));
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
            g_on = (f != nullptr) && g_orig != nullptr;
            dag::log::Writef("GENOME: capture ON (%s)", !g_orig ? "hook not installed"
                             : f ? "native-genome-capture.txt" : "could not open file");
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
