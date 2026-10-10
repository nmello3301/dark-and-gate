# Native capture of the spell animation gameplay event (static RE)

**Status:** round 1 run in-game (tail-jump hook); round 2 (queue entry detour, all events, ShortNameSet decode) run in-game 2026-10-10: select, cancel and cast layouts captured (see Round 2 result). **Date:** 2026-10-10 · **Binary:** `bg3_dx11.exe` Patch 8 (image base `0x140000000`) · **SE:** v32 source in `reference/bg3se`.
**Method:** pefile + capstone on the exe bytes and Ghidra decompiles (read-only). Only names, RVAs and byte patterns are recorded here. Follows [spell-anims-native.md](spell-anims-native.md).

Confidence tags: **[H]** instruction- or data-level evidence · **[M]** strong inference · **[L]** hypothesis.

## TL;DR

- The builder `0x144208030` does **not** hand a finished event to `0x144209d60`. That function is the first link of a **tail-call chain of arg fillers** that write the 22 variants back to front (args 20 → 0). Only the last link has the complete event, and it tail-jumps into the blueprint queue. **[H]**
- So the hook is on that final tail **jump** (`E9`) at `0x14420af68`, not on the call at `0x14420879b`: a thunk there sees all 22 args filled. A thunk at `0x14420879b` would see args 0–20 empty before the call and moved-from after it. **[H]**
- The queue is `AnimationBlueprintSystem::QueueGameplayEventToGenome`-equivalent `0x143bd4b90(system, EntityHandle const*, Event*)`. It moves the event into a ring buffer of 0x178-byte `AnimationReceivedGameplayEvent`s under a critical section, exactly SE's `GameplayEventsToGenome`. **[H]**

- **Round 2:** prepare/loop travel on a second event, `e8545375` (builder `0x144207c40`, tail jump `0x14420a63b`), not on `ba293d56`. The capture now detours the queue entry `0x143bd4b90`, so every event is logged with its caller, and ShortNameSets are decoded (`gn::TGenomeSet<FixedString>`, vtable rva `0x564F008`). See the sections below. **[H]**/**[M]**

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

## Round 1 result (in-game, tail-jump hook)

One vanilla Fire Bolt cast plus a select / hold / right-click cancel gave only **two** events, both `ba293d56`, at **cast** time, 78 ms apart, on the caster and a second entity. Every one of the 22 slots was typed except 21 (21 typed args):

- Args 0–5: empty.
- Args 6–8: ShortNameSet pointers.
- Arg 9: `85414f5f…`, the RECOVER mapping id.
- Args 10–11: empty.
- Args 12–17: Bool/Enum 0.
- Arg 18: Enum -1.
- Arg 19: the spell cast uuid.
- Arg 20: empty.

Selecting and cancelling produced **nothing** through that hook. **[H]**

## Where prepare/loop come from (round 2 static RE)

Prepare and loop are **not** carried by `ba293d56`, and they are **not** written into blueprint variables directly. They come from a second event, **`e8545375-1537-4eba-b045-0cee8a0ad64c`** (FS global `0x145EED6B4`, 9 args), which is queued through the sibling tail jump at `0x14420a63b`. **[H]**

- **Builder [H]:** `0x144207c40` loads FS `0x145EED6B4` at `0x144207e88`. It looks up the spell prototype (`0x140ef4560`) and copies `SpellAnimation` (proto+0x198), or `DualWieldingSpellAnimation` (proto+0x210) when a flag is set. Only `Part0[0..2]` (+0x00) and `Part4[0..2]` (+0x18) of the copy are used.
- **Chain [H]:** `call 0x1442099f0` at `0x144207ede` (args 8–6) → `0x14420a110` (5–3) → `0x14420a4a0` (2–0) → `jmp 0x143bd4b90` at `0x14420a63b`.
- **Request to args:** the request is on the builder's stack at `rsp+0x48`. The offsets are **[H]**; reading slot 0 as prepare and slot 4 as loop is **[M]**, from the slot-order work.

  | Request offset | Args | Contents |
  | --- | --- | --- |
  | +0x20 / +0x1C / +0x18 | 0 / 1 / 2 | slot 0 (**Prepare**) |
  | +0x14 / +0x10 / +0x0C | 3 / 4 / 5 | slot 4 (**Loop**) |
  | +0x08 (byte) | 6 | Bool (the builder's 7th argument) |
  | +0x04 | 7 | prototype byte at +0x1c |
  | +0x00 | 8 | prototype byte at +0x19 |

  So for Fire Bolt, arg 0 should be `3ff87abf…` and arg 3 should be `d8925ce4…`. **[M]**
- **Side event [H]:** after queueing, the builder also calls side event `0x144209360` (`43b4462a`) at `0x144207f62`.
- **Callers:**
  - `0x141cecce8` and `0x143438d68` are twin loops over an entity list that call only the prepare builder, so they are probably the prepare/select systems. **[M]**
  - The cast systems `0x141ce8e72` and `0x143435e0c`, plus `0x141b4ff37`, call the cast builder `0x144208030`. That they call it is **[H]**; what they are is **[L]**.
- **Why `ba293d56` args 0–5 were empty [M]:** fillers `0x14420abd0` and `0x14420adb0` read request +0x78…+0x98, which `0x1442070a0` moves in from the builder's locals. The event has slots for prepare/loop, but those travel on `e8545375` instead.

### Every spell-area call into the queue (all [H])

| Site | In function | Event (FS global, id) | Called from |
| --- | --- | --- | --- |
| E8 `0x144208e20` | `0x144208d60` | `…6B0` `c7bf6c94` | `0x141ce8c12`, `0x143435c68` |
| E8 `0x144209120` | `0x144209060` | `…6C4` `4694fea0` | `0x141ce92b6`, `0x143436150` |
| E8 `0x14420948e` | `0x144209360` | `…6C8` `43b4462a` | prepare builder `0x144207f62`, cast builder `0x144208819` |
| E8 `0x14420995e` | `0x144209830` | `…6A8` `e9db2a81` (1 FS arg) | `0x144208ea0` |
| E9 `0x144209d59` | filler `0x144209ba0` (head `0x144209520`) | `…6C0` `96516143` (3 args) | `0x144208188`, `0x144207fe0`, `0x141ce8b8a`, `0x141b50389` |
| E9 `0x14420a0fc` | filler `0x144209f30` (head `0x144209660`) | `…6BC` `0df4bd9f` (4 args) | `0x144208137` |
| E9 `0x14420a63b` | `0x14420a4a0` | `…6B4` `e8545375` (9 args, **prepare/loop**) | prepare builder `0x144207c40` |
| E9 `0x14420af68` | `0x14420adb0` | `…6AC` `ba293d56` (22 args, cast) | cast builder `0x144208030` |

Neither of the alternative hooks below is installed, because the entry detour already sees this event:

- **Tail jump at `0x14420a63b`:** it has no unique pattern. Its 58-byte tail also matches `0x141bc729b`, the identical ending of event `790f725d-cab8-446a-ae51-16f3a2052f71` (FS `0x145EED640`, builders `0x141bc67f0` and `0x14307ad70`).
- **Pre-fill call at `0x144207ede`:** a unique `E8`. Pattern, with the E8 at +25: `4C 8D 4C 24 48 4C 8D 45 00 48 8B 7C 24 70 48 8B D7 48 8B 5C 24 40 48 8B CB E8`.
  - Registers: `rcx` = system, `rdx` = `EntityHandle*`, `r8` = event (FS already set), `r9` = request.
  - The request has to be logged before the call, because the fillers move it out.

## ShortNameSet layout (static RE)

- **Vtable [H]:** the runtime vtable `0x7FF7A94EF008` is rva **`0x564F008`**. That session's base was `0x7FF7A3EA0000`, derived from the camera anchor at rva `0x1e0b661`. There is no RTTI. Its 11 slots match SE's `gn::TGenomeSet<FixedString>` virtuals in order: dtor, AssignReference, Clone, Add, Size, RemoveAt, Clear, SetVariantAt, GetVariantAt, GetTypeHash, Iterate.
- **Assign helper [H]:** `0x141bc53c0` allocates 0x18 bytes, writes that vtable, and moves `IsOwned` and `Values` from the source. Filler `0x14420a9d0` moves them out of the request at +0x38/+0x40 and +0x50/+0x58.
- **Object:**
  - `+0x00` vtable.
  - `+0x08` `bool IsOwned`. Only the low byte is used. The other 7 bytes are uninitialised, which is why round 1 shows `FFFF…01` and `3F800000…01`.
  - `+0x10` `Values*`.

  The 4th qword in the round 1 dump is allocator slack (a 0x18 request rounded up to a 0x20 slot). Layout **[H]**, slack **[M]**.
- **`Values` [H]:** a 0x10-byte heap block, which is why the data pointers are 16 bytes apart.
  - `+0x0` `u32* Buf`.
  - `+0x8` `u32 Capacity`.
  - `+0xC` `u32 Size`.

  Elements are u32 FixedString indices, and `0xFFFFFFFF` means null. `Buf[-8]` holds a u64 copy of the capacity.
- **Read recipe (implemented):**
  1. Check the vtable rva.
  2. Read `Values`.
  3. Require `Size <= Capacity`, `Size <= 64` and a plausible `Buf`.
  4. Read the ids with guarded reads.

  Nothing is add-ref'd or written. This must run before the original queue, because the args are moved-from afterwards.

## Hook (round 2): queue entry detour

- **Prologue [H]:** the queue `0x143bd4b90` starts on a 16-byte boundary, after `C3` + 15×`CC`.
  - `48 89 5C 24 10` (5 bytes, `mov [rsp+10h], rbx`)
  - `56`, `57`, `41 56`
  - `48 81 EC C0 01 00 00`
  - then the RIP-relative cookie load `48 8B 05 …` at +0x10.
- **Safety [H]:** the stolen 5 bytes are one instruction, not RIP-relative and not a branch. No E8/E9/Jcc rel32 in .text lands in `F+1..F+15`, and no short jump within ±140 bytes does either. 82 `E8` and 24 `E9` xrefs hit the entry exactly.
- **Unwind [H]:** version 1, flags 3, prolog 34 bytes. The rbx home-slot save (SAVE_NONVOL at 0x1E8) is tagged prolog offset 16. At `F+5`, rsp is unchanged and rbx is not modified yet, so unwinding stays correct.
- **`dag::patternscan::InstallEntryDetour` (new):**
  1. Checks the 5 bytes.
  2. Allocates a 64-byte block within ±2 GB, holding the trampoline (stolen bytes + `FF 25` → `F+5`) and the stub (`mov rax, hook; jmp rax`).
  3. Stores the trampoline in `g_orig` **before** patching.
  4. Writes `E9 → stub` with one aligned 8-byte interlocked store.

  If the bytes differ it refuses, and `GenomeCapture` falls back to the round 1 tail-jump hook. The two are never installed together, so nothing is logged twice.
- **`from=rva`:** the detour logs `_ReturnAddress()`. That is the caller's return address, or, for a tail-jumping filler, the builder's return address. For example, the prepare event shows its builder's caller in `0x141cec…` / `0x143438…`.

## Use

`!dag_genome_events on` (client) also sets `genome_capture=1` in `native-pov.txt`; `off` clears it. While it is on:

- **Every** queued blueprint gameplay event is one line in `Script Extender\DarkAndGate\native-genome-capture.txt`. The file is truncated on ON and flushed once per frame.
- `native.log` gets a `GENOME:` summary for spell-tagged events and for the first occurrence of each other event id.

Line format: `t=<ms> #<n> [TAG] ev=<event> (0x<fs id>) from=rva 0x<caller> ent=0x<handle> args=<set slots> | <i> <TypeName> v=0x<raw> lo=<low 32 bits as FS> [deref=…] [vt=rva 0x564F008 owned=<0|1> n=<size> cap=<cap> set=[<ids>]] | …`

Tags:

- `[SPELL]`: `ba293d56` (cast).
- `[SPELL-PREP]`: `e8545375` (prepare/loop).
- `[SPELL-SIDE]`: the six side events in the table above.

What to look for (round 2):

1. **Selecting Fire Bolt:** a `[SPELL-PREP]` line with arg 0 `lo=3ff87abf…` and arg 3 `lo=d8925ce4…`. Record args 1, 2, 4, 5 and 6–8.
2. **Casting:** `[SPELL-PREP]` first (unless it was already sent at selection), then `[SPELL]` `ba293d56`.
3. **Cancelling:** is any event queued? If so, which id and which `from=`?
4. **`[SPELL]` args 6–8 `set=[…]`:** which mapping ids they hold. Expected: cast ids such as `38cdb41c…` / `cd5e5d4a…`.
5. **Non-spell events:** volume per second and ids, to decide whether a filter is needed.

## Round 2 result (in-game, queue entry detour)

Vanilla Fire Bolt, normal camera: select, hold, right-click cancel, select again, cast. 763 events; the spell ones are below. Every spell event goes to **two** entities in the same frame (`0x01C0000100000F7B` and `0x02000001000000FE` in that session; only the first also gets the weapon-set events, so it is the character). **[H]**

| Moment | Event | Args |
| --- | --- | --- |
| Select | `e8545375…` (from rva `0x4207EE3`) | 9: `0` ASN `3ff87abf…` (prepare, slot 0), `1–2` null, `3` ASN `d8925ce4…` (loop, slot 4), `4–5` null, `6` Bool false, `7` Enum 0, `8` Enum 0. **Confirms the [M] slot reading.** |
| Select | `43b4462a…` | 1: FixedString, a per-selection uuid |
| Cancel | `e9db2a81…` (from rva `0x4209963`) | 1: ASN `eadedcce…` = **SpellAnimation slot 6**, so slot 6 is the cancel (un-prepare) clip |
| Cast | `ba293d56…` | 21: `0–5` null; `6` ShortNameSet `[38cdb41c…]` (cast); `7`, `8` ShortNameSet `[null]` (one null entry, not empty); `9` ASN `85414f5f…` (recover); `10–11` null; `12–17` Bool/Enum 0; `18` Enum -1; `19` FixedString = the select's uuid; `20` AnimationSetID null |

Empty slots are the null FixedString (`0xFFFFFFFF`), which is what SE makes from an empty Lua string. No prepare event at cast time: the cast event follows the held loop.

Probable cause of the `!dag_genome_try` crash **[L]**: it sent the cast event with empty ShortNameSets, where vanilla always sends one entry.

**Replay** (`Client/Combat/GenomeEvents.lua`): the select event with the spell's own slot 0 / slot 4 ids, and the cancel event with its slot 6 id, queued from Lua with `QueueGameplayEventToGenome` on the controlled character. The cast event is left to the engine.
