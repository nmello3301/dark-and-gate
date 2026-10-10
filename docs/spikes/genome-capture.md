# Native capture of the spell animation gameplay event (static RE)

**Status:** static RE + built, not run in-game. **Date:** 2026-10-10 · **Binary:** `bg3_dx11.exe` Patch 8 (image base `0x140000000`) · **SE:** v32 source in `reference/bg3se`.
**Method:** pefile + capstone on the exe bytes and Ghidra decompiles (read-only). Only names, RVAs and byte patterns are recorded here. Follows [spell-anims-native.md](spell-anims-native.md).

Confidence tags: **[H]** instruction- or data-level evidence · **[M]** strong inference · **[L]** hypothesis.

## TL;DR

- The builder `0x144208030` does **not** hand a finished event to `0x144209d60`. That function is the first link of a **tail-call chain of arg fillers** that write the 22 variants back to front (args 20 → 0). Only the last link has the complete event, and it tail-jumps into the blueprint queue. **[H]**
- So the hook is on that final tail **jump** (`E9`) at `0x14420af68`, not on the call at `0x14420879b`: a thunk there sees all 22 args filled. A thunk at `0x14420879b` would see args 0–20 empty before the call and moved-from after it. **[H]**
- The queue is `AnimationBlueprintSystem::QueueGameplayEventToGenome`-equivalent `0x143bd4b90(system, EntityHandle const*, Event*)`. It moves the event into a ring buffer of 0x178-byte `AnimationReceivedGameplayEvent`s under a critical section, exactly SE's `GameplayEventsToGenome`. **[H]**

## The chain

| Step | Address | What it does | Tag |
| --- | --- | --- | --- |
| Builder | `0x144208030` | Builds the event object on its stack at `rbp+0x160`: `Event` FS (from global `0x145EED6AC`, `ba293d56…`) at +0, `GenomeParametrizedEventArgs` at +8 | [H] |
| Call site | `0x14420879b` `call 0x144209d60` | `rcx` = `[rbp+0x20]` (builder's 2nd arg = system), `rdx` = `[rbp+0x18]` (pointer to the caster's `EntityHandle`), **`r8` = `&event` (rbp+0x160)**, `r9` = the spell animation request (`rsi`) | [H] |
| Filler 1 | `0x144209d60` | `r9` struct → args 20 (`[r9]`, FS moved out), 19 (`[r9+4]`, FS moved out), 18 (`[r9+8]`, u32 Enum). Then → `0x14420a2e0` | [H] |
| Fillers 2–6 | `0x14420a2e0` (17–15) → `0x14420a640` (14–12) → `0x14420a800` (11–9) → `0x14420a9d0` (8–6) → `0x14420abd0` (5–3) → `0x14420adb0` (2–0) | Each writes three variants and tail-calls the next with the same 4 args. Type descs come from `[system+0x290]` (type registry, hashed by a per-type id) | [H] |
| Queue | `0x14420af68` `jmp 0x143bd4b90` | `rcx` = system, `rdx` = `EntityHandle*`, `r8` = event. Copies the handle, moves the FS (sets source to -1), move-constructs the args, pushes a 0x178-byte element into the ring at `system+0xd8` (buf, +0xe0 cap, +0xe4 count, +0xe8 head, +0xec tail), lock at `system+0xf0` | [H] |

The variant offsets the fillers write (`event+0x10 + i*0x10`) confirm the layout: arg 20 at +0x150, 19 at +0x140, 18 at +0x130, …, 0 at +0x10. **[H]**

Correction to spell-anims-native.md: `r9` of `0x144209d60` is the animation request, not the event name, and `+0x130/+0x140/+0x150` are args 18–20 of the event object, not a hash map. **[H]**

## Layouts

- **Event object** (as passed in `r8`): `+0x00 FixedString Event`, `+0x08 vtable 0x1458df288`, `+0x10 GenomeVariant[22]`. Queued element adds `EntityHandle` in front: `{EntityHandle +0, FixedString +8, Args +0x10}`, size 0x178 = SE `AnimationReceivedGameplayEvent`. **[H]**
- **`GenomeParametrizedEventArgs`**: vtable + `std::array<GenomeVariant, 22>` **inline** (no pointer, no count). An unset slot has `Type == nullptr`. **[H]**
- **`GenomeVariant`** `{ void* Value; GenomeVarTypeDesc* Type; }`. Small types are stored **inline in `Value`**: Enum and u32 are written as a dword at `+0`, Bool as a byte at `+0`. FixedString / AnimationSimpleName go through an assign helper (`0x141bc72a0`) and are probably the FS id in the low 32 bits **[M]**. ShortNameSet uses another helper (`0x141bc53c0`) and is probably a heap pointer **[L]**.
- `GenomeVarTypeDesc::TypeName` (FS) at `+0x50`. **[H]** from SE, not re-checked in the binary.

## Hook

- Pattern (1 hit in `.text`, `E9` at +61 = rva `0x420af68`):
  `48 8B 52 10 E9 ?? ?? ?? ?? 48 8B 5A 10 4C 8D 44 24 70 48 8B D3 49 8D 4E 10 E8 ?? ?? ?? ?? 4D 8B C6 49 8B D4 49 8B CF 48 8B 5C 24 58 48 8B 6C 24 60 48 83 C4 20 41 5F 41 5E 41 5C 5F 5E E9`
  Without the leading `48 8B 52 10 E9` it has 3 hits (two sibling fillers at `0x141bc7273`, `0x14420a613` end the same way).
- The jump target is checked against the queue prologue (1 hit): `48 89 5C 24 10 56 57 41 56 48 81 EC C0 01 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 84 24 B0 01 00 00`. If they differ nothing is patched.
- `dag::patternscan::InstallFarJmp5` (new, the `E9` twin of `InstallFarCall5`) rewires the jump through a near `mov rax, imm64; jmp rax` stub to `QueueThunk(system, entity, event)`, which logs and then calls the original queue. The event is never modified.
- Thread: whichever thread runs the client spell-cast system. File writes are under an SRW lock; summaries for `native.log` are buffered and written on the frame thread (`dag::log::Writef` is not thread-safe).

## Other events

- `0x143bd4b90` has ~110 `E8`/`E9` xrefs, so it is the general client gameplay-event queue. The spell builder's side events (`0x144209660`, `0x144209520`, `0x144209360` in the doc) call it directly: `E8` sites at `0x144208e20`, `0x144209120`, `0x14420948e`, `0x14420995e` **[M]** which call is which. They are **not** captured.
- The sibling chain ending at `0x14420a63b` (`jmp 0x143bd4b90`) is another event with the same tail shape, possibly `e8545375…` (9 args). **[L]** Not captured.
- Capturing everything would need a prologue detour of `0x143bd4b90`; not done.

## Use

`!dag_genome_events on` (client) also sets `genome_capture=1` in `native-pov.txt`; `off` clears it. While on, each queued event through the hook is one line in `Script Extender\DarkAndGate\native-genome-capture.txt` (file truncated on ON) plus a `GENOME:` summary in `native.log`.

Line format: `t=<ms> #<n> [SPELL] ev=<event text> (0x<fs id>) ent=0x<handle> args=<set slots> | <i> <TypeName> v=0x<raw Value> lo=<low 32 bits as FS> [deref=<*Value as FS>] [q=[8 qwords at Value] fs0=[FS array at q0]] | …`

What to look for:

1. `[SPELL]` lines when Fire Bolt is cast vanilla; `args` should be 21.
2. Args 0–5 and 9–11 (`AnimationSimpleName`): does `lo=` print the mapping GUIDs (`3ff87abf…` prepare, `d8925ce4…` loop, …)? Then Value is the inline FS id. If only `deref=` decodes, Value is a pointer. Record which arg index holds which mapping id.
3. Args 6–8 (`ShortNameSet`): `q=` / `fs0=` show the set's storage; note which qword is the element pointer and which is the count.
4. Args 12–18: raw `v=` for Bool/Enum values. Arg 19 `lo=` should be the spell-cast UUID; arg 20 the AnimationSetID.
5. Compare with the Lua poll of `AnimationGameplayEventsSingleton` (`genome-spell-template.txt`) to see if both show the same args.
