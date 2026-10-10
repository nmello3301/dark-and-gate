# Per-character animation play rate: native lever (static RE)

**Status:** lever found statically; not yet run in-game. **Confidence:** high on the layouts and hook site (instruction-level); medium-high that scaling PlayRate scales the visible clip (the engine's own PlayRate socket feeds the clip player's rate field, which defaults to 1.0).
**Date:** 2026-10-09 · **Binary:** `bg3_dx11.exe` Patch 8 (image base `0x140000000`) · Ghidra read-only plus capstone/pefile on the exe bytes.

## Summary

All three animation-playing Genome node classes share one Execute function, `0x143a498f0`:

- `GrannyNode_PlayAnimation`
- `GrannyNode_PlayAnimationFromActiveSet`
- `GrannyNode_PlayAnimationFromSpecificSet`

Execute receives the Genome execution context. Every frame it reads its **PlayRate** input from the instance's variable storage and stores it into the clip player's rate field.

A DLL hook on that Execute can do this when the context belongs to the target character's blueprint instance:

1. Multiply the PlayRate variable by our rate.
2. Call the original Execute.
3. Restore the variable.

The effect is per character: everything the target plays through PlayAnimation nodes (scripted `Osi.PlayAnimation` clips, attacks, jump clips) runs at x rate. Other characters are untouched, and no blueprint edit is needed. This makes options (A) and (C) of the spike one solution; (B), crowds pause, was not needed.

## Facts (with evidence)

### Node classes (registration in the node-type table, call `0x1440f7d20` with the type-name FS)

| Node type | FS global | CreateTemplate | CreateNode | Template vtable | Node vtable | Node Execute (vt +0x28) |
| --- | --- | --- | --- | --- | --- | --- |
| GrannyNode_PlayAnimation | `0x145EF1BF4` | `0x143a2b520` | `0x143a2b630` | `0x14588DE80` | `0x145891200` | `0x143a498f0` |
| ..._FromActiveSet | `0x145EF1BEC` | `0x143a2b160` | `0x143a2b270` | `0x14588DA08` | `0x14588DCE0` | `0x143a498f0` |
| ..._FromSpecificSet | `0x145EF1BF0` | `0x143a2b380` | `0x143a2b490` | `0x14588DBA8` | `0x14588DC78` | `0x143a498f0` |

`.rdata` holds six qwords equal to `0x143a498f0`, so three more node classes share the same Execute: `0x14588dca0`, `0x14588dd08`, `0x14588dd70`, `0x14588e048`, `0x14588e180`, `0x145891228`.

### GenomeNodeTemplate vtable (verified on all three templates)

- **slot 5 `GetTypeID`:** `lea rax,[FS global]; ret`. It returns `0x145EF1BF4` = "GrannyNode_PlayAnimation" for the base class. SE also calls this slot.
- **slot 8 `GetInputSocketVariables(int socket, int* count)`:** `0x143fa3f80`, shared by every template. It is a pure getter:
  - `tmpl+0x30` is an `Array<{int start, int count}>`, one entry per input socket, size at `+0x3c`;
  - `tmpl+0x10` is the `u16 VariableIndex` buffer;
  - it returns `&buf[start]`.
- **slot 10 `GetInputSocketPrototypeTypes(uint64& count)`:** `mov rax,[cnt]; mov [rdx],rax; mov rax,[list]; ret`. It returns a static list of 12-byte entries `{FS type, FS name, u32 0x10001}`.

### PlayAnimation input sockets (static list `0x145EF1F50`, init `0x143a49150..0x143a49386`)

| # | Type | Name |
| --- | --- | --- |
| 0 | ? (FS `0x145ef26c4`) | (animation) |
| 1 | Bool | LoopAnimation |
| 2 | **Float** | **PlayRate** (FS global `0x145EF1B30`, registered at `0x143a1b7f2`) |
| 3 | Float | StartOffset |
| 4 | Bool | LoopAnimationAdditive |
| 5 | Bool | (FS `0x145ef270c`) |

### Execution context layout (2nd argument of Execute, `rdx`)

| Offset | Meaning | Evidence |
| --- | --- | --- |
| `+0x00` | double, current time | compared against the clip-event times |
| `+0x08` | float **dt** | `movss xmm0,[r14+8]` at `0x143a4a027`, added to clocks |
| `+0x10` | u32 frame counter | node reset check `node+0x10 + 1 < ctx+0x10` |
| `+0x18` | **GenomeBlueprintInstance\*** | `mov rax,[rdx+18h]; mov rax,[rax+40h]` (instance→Parent, matches SE's instance layout) |
| `+0x30` | short, current node index | `movsx rcx, word [rdx+30h]` → `Parent->Nodes[idx]` (template) |
| `+0x48` | `u16*` this node's socket variable indices | `0x143a49ba7` |
| `+0x78` / `+0x80` | `u64**` variable storage (selected by bit 15 of the index); each variable is 16 bytes, value at `+0` | `0x143a49bb5..bc7` |

**The PlayRate read** (`0x143a49ba7`–`0x143a49bc7`):

```
idx  = *(u16*)(*(u8**)(ctx+0x48) + 4);              // socket 2 = PlayRate
rate = *(float*)(**(u8***)(ctx + 0x78 + (idx>>15)*8) + (idx & 0x7fff)*16);
...
clipState->rate (+0x2c) = rate;                      // 0x143a49cd4; default 1.0 written at 0x143a499f2
```

### Hook site: Execute `0x143a498f0` (`void __fastcall Execute(GenomeNode* node, GenomeExecutionContext* ctx)`)

Unique pattern (one hit in `.text`; the 4 masked bytes are the security-cookie RIP displacement):

```
48 8B C4 48 89 58 18 55 56 57 41 54 41 55 41 56 41 57 48 8D A8 D8 FD FF FF 48 81 EC F0 02 00 00
0F 29 70 B8 0F 29 78 A8 44 0F 29 40 98 44 0F 29 48 88 44 0F 29 90 78 FF FF FF 44 0F 29 98 68 FF
FF FF 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 85 80 01 00 00 48 8B F2 48 89 54 24 58 48 8B F9
```

The bytes that follow (`45 33 FF 44 89 7D 50 48 8B 42 18 48 8B 40 40 48 0F BF 4A 30 ...`) also confirm `ctx+0x18` → `+0x40` and `ctx+0x30`.

## Hook plan (pseudo-C)

Install by vtable patch, the same technique as `VisualLift.cpp`: no trampoline, chains with nothing.

```c
using ExecFn = void (__fastcall*)(void* node, uint8_t* ctx);
static ExecFn g_origExec;

struct RateSlot { std::atomic<uintptr_t> inst; std::atomic<float> rate; };
static RateSlot g_rates[8];                // written by the camera/Lua-poll thread

static bool LookupRate(uintptr_t inst, float* r) {
    for (auto& s : g_rates) if (s.inst.load(std::memory_order_acquire) == inst) { *r = s.rate.load(); return true; }
    return false;
}

static float* PlayRateVar(uint8_t* ctx) {            // SEH-guarded reads
    uint8_t* socks = *(uint8_t**)(ctx + 0x48);
    uint16_t idx   = *(uint16_t*)(socks + 4);
    uint8_t* store = **(uint8_t***)(ctx + 0x78 + (idx >> 15) * 8);
    return (float*)(store + (size_t)(idx & 0x7fff) * 16);
}

void __fastcall HookExec(void* node, uint8_t* ctx) {
    float r;
    uintptr_t inst = ctx ? *(uintptr_t*)(ctx + 0x18) : 0;
    if (!inst || !LookupRate(inst, &r)) { g_origExec(node, ctx); return; }
    float* p = SafePlayRateVar(ctx);                  // nullptr on any fault
    if (!p) { g_origExec(node, ctx); return; }
    float saved = *p;
    *p = saved * r;                                   // designer rate x ours
    g_origExec(node, ctx);
    *p = saved;                                       // restore: other nodes / frames see the original
}

bool Install() {
    uintptr_t fn = PatternScan(text, kExecPattern);   // must be exactly 1 hit
    g_origExec = (ExecFn)fn;
    for each qword q in .rdata with q == fn:          // 6 vtable slots today
        VirtualProtect + write &HookExec;             // log each patched address
}
```

- **Target identity:**
  - Lua writes `anim_inst=<hex>`, the address from `tostring(ent.AnimationBlueprint.Instance)`, plus `anim_rate=<r>` to `native-pov.txt`.
  - The DLL puts `{inst, rate}` into `g_rates`; rate 1 clears the slot.
  - The instance pointer must be re-sent when it changes (reload, character swap, polymorph); the existing per-tick write covers that.
- **Freeze:** use a tiny rate (`0.001`) at first, and try exactly 0 in the playtest. Nothing in Execute divides by the rate (the one `div` at `0x143a4a714` divides by `ctx+8` as an integer field), but the clip player may.
- **Optional extra:** scale `ctx+8` (dt) the same way during the call, so the node's secondary event clock (`state+0x48 / +0x14,+0x18`) matches the slowed clip. Keep it behind a switch; with PlayRate scaling alone the anim-event timing may drift at extreme rates.

## Threading

Genome instances are updated by the animation jobs, potentially on worker threads, in parallel across characters. One instance's nodes run sequentially within its update, so a save, scale, call, restore of that instance's own variable inside the hook is race-free for that instance.

The hook's lookup must be lock-free: a small fixed array of atomics, read-only on the hot path. The cost for non-target characters is one load plus up to 8 compares per PlayAnimation node per frame.

## Risks

- **Shared constant variable:** PlayRate's variable may be a compiled constant that other sockets of the same instance also read (deduped 1.0). The temporary write is restored before any other node of that instance executes, so the only node that sees it is the one we're scaling.
- **Blueprint graphs** that play clips through other node classes not sharing `0x143a498f0` (blend spaces, locomotion) won't slow. Idle and locomotion may keep normal speed; scripted clips, attacks and jump clips go through PlayAnimation nodes.
- **Patch drift:** the pattern and the `.rdata` scan fail loudly (0 or >1 hits); keep the camera-only fallback.
- **Instance pointer staleness:** compare only (never dereference the Lua-provided pointer in the hook), so a stale pointer just never matches.

## Not needed / parked

- **(B) crowds PlayPause:** not investigated further; PlayRate covers freeze.
- **The Lua-only route** (write `Instance.Variables[idx]` permanently): possible, since a DLL can read `tmpl+0x30` / `+0x10` to get the PlayRate variable index per node. But a permanent write to a deduped constant could slow unrelated sockets. The save-and-restore hook avoids that.
