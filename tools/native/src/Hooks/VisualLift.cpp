// SPDX-License-Identifier: GPL-3.0-or-later
//
// Visual-only body lift. See VisualLift.h and docs/spikes/m1b-visual-lift.md.
//
// rf Visual layout used (bg3se Render.h, confirmed in the spike):
//   +0x08 WorldTransform { quat +0x08, Translate +0x18, Scale +0x24 }
//   Transform (by value) = quat[4] (+0x00), Translate[3] (+0x10), Scale[3] (+0x1C)
// vtable (MoveableObject order): [0] GetRTTI (returns 0x1001 for Visual),
//   [2] SetWorldTranslate(vec3 const&), [5] SetWorldTransform(Transform const&),
//   [6] SetWorldTransform(vec3 const&, quat const&, vec3 const&).

#include "VisualLift.h"

#include <windows.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>

#include "../Log.h"
#include "../SafeMem.h"

namespace dag::visuallift {

namespace {

using TranslateFn = void(__fastcall*)(void* self, const float* t);
using TransformFn = void(__fastcall*)(void* self, const float* tr);
using TrsFn       = void(__fastcall*)(void* self, const float* t, const float* r, const float* s);

TranslateFn g_origT   = nullptr;
TransformFn g_origTr  = nullptr;
TrsFn       g_origTrs = nullptr;

constexpr int kMaxVt = 6;
uintptr_t g_patched[kMaxVt] = {};
int       g_numPatched = 0;
uintptr_t g_failed[kMaxVt] = {};
int       g_numFailed = 0;

std::atomic<uintptr_t> g_visual{ 0 };
std::atomic<float>     g_lift{ 0.f };
std::atomic<uint32_t>  g_frame{ 0 };
std::atomic<uint32_t>  g_writeFrame{ 0 };
std::atomic<bool>      g_baseOk{ false };
float                  g_base[3] = {};     // engine's unlifted translate
float                  g_lastApplied = 0;  // lift currently on the Visual
float                  g_lastWritten[3] = {};  // translate we know is on the Visual
bool                   g_haveWritten = false;
int                    g_statHook = 0, g_statRefresh = 0, g_statExt = 0;
bool                   g_engineWrote = false;
bool                   g_loggedEngineThread = false;
bool                   g_loggedRefreshThread = false;
thread_local int       t_depth = 0;
bool                   g_force = false;

// Render objects of the player's meshes (SetObjects).
constexpr int kMaxObj = 24;
struct LiftObj {
    uintptr_t p = 0;
    float base[3] = {};
    float written[3] = {};
    bool  have = false;
    float applied = 0;
};
LiftObj g_objs[kMaxObj];
int     g_numObjs = 0;
bool    g_objEnabled = true;
int     g_objWrites = 0, g_objExt = 0;
uintptr_t g_objVtLogged[8] = {};
int     g_objVtLoggedN = 0;

bool                   g_flip = false;

bool Contains(const uintptr_t* list, int n, uintptr_t v)
{
    for (int i = 0; i < n; ++i) if (list[i] == v) return true;
    return false;
}

// Pattern with -1 as wildcard.
bool CodeMatches(uintptr_t fn, const int* pat, int n)
{
    uint8_t b[32];
    if (n > 32 || !dag::safemem::ReadBytes(reinterpret_cast<void*>(fn), b, n)) return false;
    for (int i = 0; i < n; ++i) if (pat[i] >= 0 && b[i] != static_cast<uint8_t>(pat[i])) return false;
    return true;
}

bool InModule(uintptr_t p)
{
    static uintptr_t base = 0, end = 0;
    if (!base) {
        HMODULE m = GetModuleHandleW(nullptr);
        base = reinterpret_cast<uintptr_t>(m);
        auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(m);
        auto* nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
        end = base + nt->OptionalHeader.SizeOfImage;
    }
    return p >= base && p < end;
}

void NoteEngineWrite(const float* t)
{
    g_base[0] = t[0]; g_base[1] = t[1]; g_base[2] = t[2];
    g_baseOk.store(true);
    g_writeFrame.store(g_frame.load());
    g_engineWrote = true;
    if (!g_loggedEngineThread) {
        g_loggedEngineThread = true;
        dag::log::Writef("LIFT: engine writes player Visual on thread %lu (frame %u)",
                         GetCurrentThreadId(), g_frame.load());
    }
}

void __fastcall HookTranslate(void* self, const float* t)
{
    if (reinterpret_cast<uintptr_t>(self) != g_visual.load() || t_depth > 0 || !t) {
        g_origT(self, t);
        return;
    }
    ++t_depth;
    NoteEngineWrite(t);
    const float lift = g_lift.load();
    g_lastApplied = lift;
    const float c[3] = { t[0], t[1] + lift, t[2] };
    g_origT(self, lift == 0.f ? t : c);
    std::memcpy(g_lastWritten, c, sizeof(c)); g_haveWritten = true;
    if (lift != 0.f) ++g_statHook;
    --t_depth;
}

void __fastcall HookTransform(void* self, const float* tr)
{
    if (reinterpret_cast<uintptr_t>(self) != g_visual.load() || t_depth > 0 || !tr) {
        g_origTr(self, tr);
        return;
    }
    ++t_depth;
    NoteEngineWrite(tr + 4);
    const float lift = g_lift.load();
    g_lastApplied = lift;
    float c[10];
    std::memcpy(c, tr, sizeof(c));
    c[5] += lift;
    g_origTr(self, lift == 0.f ? tr : c);
    std::memcpy(g_lastWritten, c + 4, sizeof(float) * 3); g_haveWritten = true;
    if (lift != 0.f) ++g_statHook;
    --t_depth;
}

void __fastcall HookTrs(void* self, const float* t, const float* r, const float* s)
{
    if (reinterpret_cast<uintptr_t>(self) != g_visual.load() || t_depth > 0 || !t) {
        g_origTrs(self, t, r, s);
        return;
    }
    ++t_depth;
    NoteEngineWrite(t);
    const float lift = g_lift.load();
    g_lastApplied = lift;
    const float c[3] = { t[0], t[1] + lift, t[2] };
    g_origTrs(self, lift == 0.f ? t : c, r, s);
    std::memcpy(g_lastWritten, c, sizeof(c)); g_haveWritten = true;
    if (lift != 0.f) ++g_statHook;
    --t_depth;
}

bool PatchVtable(uintptr_t vt)
{
    uintptr_t slots[7] = {};
    if (!dag::safemem::ReadBytes(reinterpret_cast<void*>(vt), slots, sizeof(slots))) return false;

    static const int kRtti[] = { 0xB8, 0x01, 0x10, 0x00, 0x00, 0xC3 };
    static const int kSlot2[] = { 0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x6C, 0x24, 0x10, 0x48, 0x89,
                                  0x74, 0x24, 0x18, 0x57, 0x48, 0x83, 0xEC, 0x20, 0xF2, 0x0F, 0x10, 0x02 };
    static const int kSlot5[] = { 0x48, 0x89, 0x6C, 0x24, 0x20, 0x56, 0x48, 0x83, 0xEC, 0x20, 0xF3, 0x0F,
                                  0x10, 0x15, -1, -1, -1, -1, 0x48, 0x8B, 0xEA, 0x48, 0x8D, 0x51 };
    const bool okR = CodeMatches(slots[0], kRtti, 6);
    const bool ok2 = CodeMatches(slots[2], kSlot2, 24);
    const bool ok5 = CodeMatches(slots[5], kSlot5, 24);
    const bool ok6 = InModule(slots[6]);
    if (!okR || !ok2 || !ok5 || !ok6) {
        dag::log::Writef("LIFT: vtable %p failed validation (rtti=%d slot2=%d slot5=%d slot6=%d) -> camera-only jump",
                         reinterpret_cast<void*>(vt), okR, ok2, ok5, ok6);
        return false;
    }
    // The three slot functions are shared between the Visual vtables; one
    // set of originals serves every patched vtable.
    if (g_origT) {
        if (slots[2] != reinterpret_cast<uintptr_t>(g_origT) || slots[5] != reinterpret_cast<uintptr_t>(g_origTr) ||
            slots[6] != reinterpret_cast<uintptr_t>(g_origTrs)) {
            dag::log::Writef("LIFT: vtable %p has different slot functions -> not patched", reinterpret_cast<void*>(vt));
            return false;
        }
    } else {
        g_origT   = reinterpret_cast<TranslateFn>(slots[2]);
        g_origTr  = reinterpret_cast<TransformFn>(slots[5]);
        g_origTrs = reinterpret_cast<TrsFn>(slots[6]);
    }

    void** vslots = reinterpret_cast<void**>(vt);
    DWORD old = 0;
    if (!VirtualProtect(&vslots[2], sizeof(void*) * 5, PAGE_READWRITE, &old)) {
        dag::log::Writef("LIFT: VirtualProtect failed (%lu) -> camera-only jump", GetLastError());
        return false;
    }
    vslots[2] = reinterpret_cast<void*>(&HookTranslate);
    vslots[5] = reinterpret_cast<void*>(&HookTransform);
    vslots[6] = reinterpret_cast<void*>(&HookTrs);
    DWORD tmp = 0;
    VirtualProtect(&vslots[2], sizeof(void*) * 5, old, &tmp);
    FlushInstructionCache(GetCurrentProcess(), nullptr, 0);

    const uintptr_t mod = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
    dag::log::Writef("LIFT: patched Visual vtable %p (rva 0x%llX) slots 2/5/6 (orig rva 0x%llX 0x%llX 0x%llX)",
                     reinterpret_cast<void*>(vt), static_cast<unsigned long long>(vt - mod),
                     static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(g_origT) - mod),
                     static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(g_origTr) - mod),
                     static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(g_origTrs) - mod));
    return true;
}

bool Hooked(uintptr_t visual)
{
    if (!visual) return false;
    void* vt = nullptr;
    if (!dag::safemem::ReadPtr(reinterpret_cast<void*>(visual), 0, vt)) return false;
    return Contains(g_patched, g_numPatched, reinterpret_cast<uintptr_t>(vt));
}

}  // namespace

namespace { void RefreshObjects(float lift); }

void SetVisual(uintptr_t visual)
{
    if (visual == g_visual.load()) return;
    g_baseOk.store(false);
    g_lastApplied = 0;
    g_engineWrote = false;
    g_haveWritten = false;
    if (!visual) { g_visual.store(0); return; }

    void* vtp = nullptr;
    if (!dag::safemem::ReadPtr(reinterpret_cast<void*>(visual), 0, vtp) || !vtp) {
        g_visual.store(0);
        return;
    }
    const uintptr_t vt = reinterpret_cast<uintptr_t>(vtp);
    if (!Contains(g_patched, g_numPatched, vt)) {
        if (Contains(g_failed, g_numFailed, vt)) { g_visual.store(0); return; }
        if (g_numPatched < kMaxVt && PatchVtable(vt)) {
            g_patched[g_numPatched++] = vt;
        } else {
            if (g_numFailed < kMaxVt) g_failed[g_numFailed++] = vt;
            g_visual.store(0);
            return;
        }
    }
    g_visual.store(visual);
    dag::log::Writef("LIFT: player Visual %p (vtable %p)", reinterpret_cast<void*>(visual), vtp);
}

void SetLift(float lift)
{
    g_lift.store(lift);
}

void Refresh()
{
    const uint32_t frame = g_frame.fetch_add(1) + 1;
    RefreshObjects(g_lift.load());
    const uintptr_t v = g_visual.load();
    if (!v || !g_origT) return;
    const float lift = g_lift.load();
    if (lift == 0.f && g_lastApplied == 0.f) return;
    if (!Hooked(v)) return;  // stale pointer or a different object now

    // 2026-10-09 playtest: the jump didn't show while walking. If the
    // Visual holds a value none of our hooks or refreshes wrote, an engine
    // path bypassed the hooks: take it as the new (unlifted) base and
    // re-lift it here.
    float cur[3];
    if (!dag::safemem::ReadFloat3(reinterpret_cast<void*>(v), 0x18, cur)) return;
    const bool external = g_haveWritten &&
        (std::fabs(cur[0] - g_lastWritten[0]) > 1e-4f || std::fabs(cur[1] - g_lastWritten[1]) > 1e-4f ||
         std::fabs(cur[2] - g_lastWritten[2]) > 1e-4f);
    if (external) {
        g_base[0] = cur[0]; g_base[1] = cur[1]; g_base[2] = cur[2];
        g_baseOk.store(true);
        ++g_statExt;
    } else if (g_engineWrote && frame - g_writeFrame.load() < 2 && !g_force) {
        // The engine wrote through our hook within the last frame: that
        // write already carries the lift.
        return;
    }

    if (!g_baseOk.load()) {
        // Not written since we took over: what's there is unlifted
        // (g_lastApplied == 0 here), so it is the base.
        cur[1] -= g_lastApplied;
        g_base[0] = cur[0]; g_base[1] = cur[1]; g_base[2] = cur[2];
        g_baseOk.store(true);
    }
    if (!g_loggedRefreshThread) {
        g_loggedRefreshThread = true;
        dag::log::Writef("LIFT: camera-hook refresh on thread %lu (frame %u, engine thread logged %s)",
                         GetCurrentThreadId(), frame, g_loggedEngineThread ? "yes" : "not yet");
    }
    // Forced re-apply: alternate a 0.1 mm nudge so a setter that skips
    // unchanged values still propagates to the meshes.
    g_flip = !g_flip;
    const float nudge = (g_force && g_flip) ? 1e-4f : 0.f;
    const float c[3] = { g_base[0], g_base[1] + lift + nudge, g_base[2] };
    g_origT(reinterpret_cast<void*>(v), c);
    std::memcpy(g_lastWritten, c, sizeof(c)); g_haveWritten = true;
    g_lastApplied = lift;
    if (!external) ++g_statRefresh;
}

void SetObjects(const uintptr_t* objs, int n, bool enabled)
{
    g_objEnabled = enabled;
    if (n > kMaxObj) n = kMaxObj;
    // Keep state for objects that stay in the list.
    LiftObj next[kMaxObj];
    int m = 0;
    for (int i = 0; i < n; ++i) {
        if (!objs[i]) continue;
        bool dup = false;
        for (int j = 0; j < m; ++j) if (next[j].p == objs[i]) dup = true;
        if (dup) continue;
        LiftObj o;
        o.p = objs[i];
        for (int k = 0; k < g_numObjs; ++k) if (g_objs[k].p == objs[i]) o = g_objs[k];
        next[m++] = o;
    }
    for (int i = 0; i < m; ++i) g_objs[i] = next[i];
    g_numObjs = m;
}

void TakeObjectStats(int& writes, int& external, int& objects)
{
    writes = g_objWrites; external = g_objExt; objects = g_numObjs;
    g_objWrites = g_objExt = 0;
}

namespace {
using SetTranslateFn = void(__fastcall*)(void* self, const float* t);

// The object's own SetWorldTranslate (slot 2), if it looks sane.
SetTranslateFn ObjSetter(uintptr_t obj)
{
    void* vt = nullptr;
    if (!dag::safemem::ReadPtr(reinterpret_cast<void*>(obj), 0, vt) || !vt) return nullptr;
    uintptr_t slot2 = 0;
    if (!dag::safemem::ReadBytes(reinterpret_cast<uint8_t*>(vt) + 16, &slot2, sizeof(slot2))) return nullptr;
    if (!InModule(slot2)) return nullptr;
    const uintptr_t v = reinterpret_cast<uintptr_t>(vt);
    bool logged = false;
    for (int i = 0; i < g_objVtLoggedN; ++i) if (g_objVtLogged[i] == v) logged = true;
    if (!logged && g_objVtLoggedN < 8) {
        g_objVtLogged[g_objVtLoggedN++] = v;
        const uintptr_t mod = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
        dag::log::Writef("LIFT: render object vtable rva 0x%llX, SetWorldTranslate rva 0x%llX (%s the Visual's)",
                         static_cast<unsigned long long>(v - mod), static_cast<unsigned long long>(slot2 - mod),
                         slot2 == reinterpret_cast<uintptr_t>(g_origT) ? "same as" : "differs from");
    }
    return reinterpret_cast<SetTranslateFn>(slot2);
}

void RefreshObjects(float lift)
{
    for (int i = 0; i < g_numObjs; ++i) {
        LiftObj& o = g_objs[i];
        float cur[3];
        if (!dag::safemem::ReadFloat3(reinterpret_cast<void*>(o.p), 0x18, cur)) continue;
        const bool want = g_objEnabled && lift != 0.f;
        if (!o.have || o.applied == 0.f) {
            // Not lifted by us: what's there is the engine's position.
            std::memcpy(o.base, cur, sizeof(cur));
            o.have = true;
        } else if (std::fabs(cur[0] - o.written[0]) > 1e-4f || std::fabs(cur[1] - o.written[1]) > 1e-4f ||
                   std::fabs(cur[2] - o.written[2]) > 1e-4f) {
            // The engine moved it since our write: new base.
            std::memcpy(o.base, cur, sizeof(cur));
            ++g_objExt;
        }
        if (!want && o.applied == 0.f) continue;
        SetTranslateFn set = ObjSetter(o.p);
        if (!set) continue;
        const float l = want ? lift : 0.f;
        const float t[3] = { o.base[0], o.base[1] + l, o.base[2] };
        __try { set(reinterpret_cast<void*>(o.p), t); } __except (EXCEPTION_EXECUTE_HANDLER) { continue; }
        std::memcpy(o.written, t, sizeof(t));
        o.applied = l;
        if (l != 0.f) ++g_objWrites;
    }
}
}  // namespace

void SetForce(bool on) { g_force = on; }
bool Forced() { return g_force; }

float AppliedLift()
{
    const uintptr_t v = g_visual.load();
    if (!v || !g_baseOk.load() || !Hooked(v)) return 0.f;
    float cur[3];
    if (!dag::safemem::ReadFloat3(reinterpret_cast<void*>(v), 0x18, cur)) return 0.f;
    return cur[1] - g_base[1];
}

void TakeStats(int& hook, int& refresh, int& ext)
{
    hook = g_statHook; refresh = g_statRefresh; ext = g_statExt;
    g_statHook = g_statRefresh = g_statExt = 0;
}

bool BodyLiftActive()
{
    return Hooked(g_visual.load());
}

const char* Mode()
{
    if (g_numPatched > 0 && g_visual.load()) return "body";
    if (g_numFailed > 0) return "camera-only";
    return "off";
}

}  // namespace dag::visuallift
