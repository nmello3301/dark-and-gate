# M1b Phase 0a: per-character animation playback speed (native lever?)

**Status:** answered partial. There is no clean native lever via Granny. There is one promising lever via the Genome graph, reachable from Lua, which still needs a one-command in-game probe. **Ship the jump on the phase substitute now.**
**Date:** 2026-10-09 · **Binary:** `bg3_dx11.exe` (Patch 8, Ghidra static) · **SE:** v32 source in `reference/bg3se`

## Question

Is there a float we can write, or a function we can call, that scales the playback speed of **one** character's current animation, including speed 0 to hold a pose? It would be used for the floaty jump: stretch the jump clip to the tunable jump duration.

## What we searched

- Granny strings: `granny_controlled_animation.cpp` (3 hits) and `granny_spu_controlled_animation.cpp`. There are no `GrannySetControlSpeed`-style name strings (statically linked, names stripped).
- Larian strings: `AnimationSpeed`, `AnimationPlayRate`, `PlayRate`, `SpeedMultiplier`, `Speed`, `*TimeScale*`, `*PlaybackRate*` (none of the last two exist).
- SE source: `GameDefinitions/Animation.h` (Genome / anim-blueprint runtime), `Components/Visual.h` (`AnimationBlueprintComponent`), `Render.h`.

## Findings

### 1. Granny `granny_control`: a lever exists, but Larian doesn't use it ❌

The Granny control module sits at `0x144a40590`–`0x144a41fd0`. The layout matches Granny 2.12's `control` exactly. Confidence is high, from `GrannyCreateControl` and the trivial getters and setters:

| Offset | Field | Evidence |
| --- | --- | --- |
| `+0x80` | Flags (bit0 active, bit1 kill-on-clock, bit6 …) | `FUN_144a41380` / `FUN_144a41390` |
| `+0x84` | CurrentClock | `CreateControl(clock, dur)` writes it; `SetControlClock` `FUN_144a40960` |
| `+0x88` | dTLocalClockPending | `SetControlClock` accumulates `new - old` |
| `+0x90` | **Speed** (init 1.0) | getter `FUN_144a410e0` |
| `+0x94` | LocalDuration | `CreateControl` arg 2 |
| `+0x98` / `+0x9c` | LoopIndex / LoopCount | getters and setters `FUN_144a410a0` / `FUN_144a40fd0` |
| `+0xa0` | KillClock | `FUN_144a40840` |
| `+0xa4` | Weight | `SetControlWeight` `FUN_144a40ba0` |

- **`GrannySetControlSpeed(control*, float)` is at `0x144a410f0`.** It rescales the kill and ease clocks, then writes `+0x90`. A speed of 0 is guarded against division, so a hold is legal.
- **The catch:** `0x144a410f0`, `GrannyGetControlSpeed` and `GrannySetControlClock` are each called only from their one-line public wrappers (`0x144a0d1b0`, `0x144a0d190`, `0x144a0cf70`). Those wrappers are referenced **only from the Granny export table** (`0x14642c35c…0x14642c434`), not from Larian code.
- The Larian anim graph samples animations with its own clocks (Genome nodes). Writing a `granny_control.Speed` would affect nothing we play, and there is no character → control path anyway.

### 2. `AnimationSpeed` / `AnimationPlayRate` strings ❌ (not runtime levers)

- **`AnimationSpeed`** (`0x1456adca0`) is a FixedString used only by `FUN_14205bdf0`, the loader for `GUI/AiPathSettings.lsx`. It is a global movement-path setting.
- **`AnimationPlayRate`** (`0x1458bead0`) is read only by `FUN_143da2210`. That is a serializer (Visit) for dialogue/timeline animation keys: a double at `+0x168`, default 1.0. It is the same idea as SE's `GenomeTimelineAnimation.PlayRate`, and it is timeline-only.

### 3. Genome graph `PlayRate` input socket ◐ (most promising, Lua-reachable)

- `FUN_143a1b3c0` registers the GrannyNode socket names and node types. It includes `PlayRate`, `StartOffset`, `Animation`, `LoopAnimation`, `GrannyNode_PlayAnimation`, `…PlayAnimationFromActiveSet`, `…GetSlotAnimationPose` and so on.
- `PlayRate` has three FixedString globals: `DAT_145fcc9b8`, `DAT_145fcc2d8`, `DAT_145fcc178`. They are read by node **input-socket prototype builders**. For example, `FUN_143a3b700` builds a 6-socket prototype list whose last entry is `(type, "PlayRate")`. Similar builders are at `0x14381b060`, `0x143814400` and the `0x143a4bd40` family.
- So the anim-graph nodes take **PlayRate as a data input socket**.
- In Genome, every data socket resolves to a `VariableIndex` (`GenomeNodeTemplate::GetInputSocketVariables`). Those values live in the per-character `GenomeBlueprintInstance.Variables` (SE: `ent.AnimationBlueprint.Instance.Variables`). SE binds that array with **Lua write support for float GenomeVariants** (`Animation.inl`, `GenomeVariant::LuaSetValue`).
- Spike 4 only tried top-level fields on `AnimationBlueprint` and `AnimationSet`. It never tried `Instance.Variables`.

**Caveats (unverified until in-game):**

- If the clip that `Osi.PlayAnimation` triggers plays through a node whose `PlayRate` is wired to a named blueprint variable, writing that one float scales it **per character**. That would be ideal, and speed 0 would give the hold.
- If `PlayRate` is a compiled constant, it may still sit in `Instance.Variables` at an unnamed index. Writing it would scale every clip that node plays for that character while the write holds, so the value must be restored afterwards.
- If `PlayRate` is computed by another node (a stack variable), a write is overwritten every frame and does nothing.

**Native fallback for the unnamed case:**

1. Call node template vtable slot 8 (`GetInputSocketVariables(socketIdx, &count)`, `+0x40`; order from SE's `GenomeNodeTemplate` declaration) on the active PlayAnimation node.
2. Use the `PlayRate` socket index (5 in `FUN_143a3b700`'s list; confidence medium) to get the VariableIndex.

That is more RE than this spike's budget.

## Recommendation

**No clean native lever: use the phase substitute** for the jump now. Play the jump clip's start / loop-or-hold / land phases timed to the jump duration, and log `jump anim path=phases`.

Add one cheap probe, done in Lua, not the DLL. The jump code can switch to it automatically if it pans out:

1. Probe command `!dag_anim_vars`. It dumps, for the controlled character:
   - `AnimationBlueprint.Instance.Parent.Variables[i]`: `Name`, `Type`, `Index`;
   - the live `Instance.Variables[i]` value for every float.
   Run it once idle and once mid-`PlayAnimation`, then look for a `PlayRate`, `Speed` or `Rate`-named float, or a float that is 1.0 and changes.
2. If a named rate variable exists, the jump writes `mult` to it for the clip's duration and restores 1.0 after. Log `jump anim path=genome-var <name>`. Then the hold is `0`.
3. If nothing is named, stay on phases. Optionally a later spike resolves the PlayRate VariableIndex natively (vtable `+0x40`, see above).

## Addresses (bg3_dx11.exe, Patch 8)

| Address | What | Confidence |
| --- | --- | --- |
| `0x144a40610` | GrannyCreateControl(clock, duration) | high |
| `0x144a410f0` | GrannySetControlSpeed(control*, float) | high |
| `0x144a410e0` | GrannyGetControlSpeed | high |
| `0x144a40960` | GrannySetControlClock | high |
| `0x144a0d1b0` / `0x144a0d190` / `0x144a0cf70` | public wrappers (export-table only) | high |
| `0x143a1b3c0` | Genome GrannyNode socket and node-type name registration | high |
| `0x143a3b700` | input-socket prototype list containing `PlayRate` | medium |
| `0x14205bdf0` | AiPathSettings.lsx loader (`AnimationSpeed`) | high |
| `0x143da2210` | timeline animation key Visit (`AnimationPlayRate` @ +0x168) | high |
