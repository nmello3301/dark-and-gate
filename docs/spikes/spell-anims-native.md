# Spell prepare / loop / cast / recover while moving (static RE)

**Status:** static RE only, nothing run in-game. **Date:** 2026-10-10 · **Binary:** `bg3_dx11.exe` Patch 8 (image base `0x140000000`) · **SE:** v32 source in `reference/bg3se`.
**Method:** pefile + capstone on the exe bytes, Ghidra (read-only) for one decompile, and the vanilla humanoid animation blueprint `Public/Shared/Assets/Blueprints/Characters_Common.lsbs` / `.lsbc` (in `Assets.pak`). The blueprint was unpacked with Divine into the session scratchpad and converted to LSX for reading. Nothing from the game is copied into the repo; only names, GUIDs, RVAs and byte patterns are recorded here.

Confidence tags: **[H]** instruction- or data-level evidence · **[M]** strong inference · **[L]** hypothesis.

## TL;DR

1. **The spell path ends in a Genome gameplay event, not in a script animation.** The client spell-cast code converts the spell's animation request into a blueprint **gameplay event**. The event's name is a GUID FixedString, and its payload is a 22-slot `GenomeParametrizedEventArgs` holding the spell's animation mapping ids. Blueprint `GenomeAnimationNode_GameplayEventNode` nodes receive the event and copy the payload into `SPELL_*` variables, such as `SPELL_Prepare` (#466) and `SPELL_Loop` (#214). **[H]**
2. **SE already exposes the same queue to Lua:**
   ```lua
   Ext.System.AnimationBlueprint:QueueGameplayEventToGenome(entity, eventName, args)
   ```
   - It is client-side.
   - It pushes `{Entity, Event, Args[22]}` into `ls::AnimationBlueprintSystem::GameplayEventsToGenome` under its lock (`Animation.inl:291`).
   - Args are `GenomeVariant`s written from Lua as `{Type = "AnimationSimpleName", Value = "<mapping guid>"}`.

   **This is the recommended lever (a).** No native code, no Osiris action queue, no server task. **[H]** that the API exists; **[L]** that the blueprint accepts the event outside a real spell action.
3. **The vanilla humanoid blueprint is full-body. It has no upper-body layer.**
   - Every `ServerNode_Blend` (25 of them) takes `(alpha, poseA, poseB)`. No node takes a bone mask or bone group.
   - The only non-root slots are `Wings`, `Weapon`, `Tail`, `Tentacles`, `HeadwearRemap` and `"1"`.
   - **So whatever plays the spell prepare/loop replaces the legs too.** The capsule can still move: WASD/MoveTo and our falling-state jump are separate movement-machine code. But the legs won't walk while the spell clip owns the pose. **[H]** for the blueprint structure, **[M]** for the visual consequence.
4. `SR_LayeredTurn_*` is the **steering-rotation (SR)** turn-in-place clip, played additively while the prepare holds (variables `SR_PrepareOffset`, `SR_TurnDegreeThreshold`, `SR_UseNewSR`, `SR_SteppingAngle`). It is not a locomotion layer. **[M]**
5. **Skipping prepare for an `Osi.UseSpell` release:** the blueprint guards the prepare with `GenomeAnimationNode_IsShortnameValidAnim(SPELL_Prepare, …)` (node 481). An empty or invalid prepare mapping id makes it skip that state. A runtime stats edit that blanks `SpellAnimation` slot 0 should therefore give Cast + Recover only. **[M]** for the guard, **[L]** that the server does not wait out a prepare phase anyway.

## Q1: from the spell-cast system to the blueprint

### Engine side

| What | Where | Evidence |
| --- | --- | --- |
| Spell genome event builder (21 args) | **`0x144208030`** (RVA `0x4208030`). Callers: `0x141ce8820`, `0x143435710` | Builds a `GenomeParametrizedEventArgs` (vtable `0x1458df288`, 22 × 16-byte variants via `0x144e65d7c(buf, 0x10, 0x16, ctor)`). Sets the event FS from global `0x145EED6AC`, then calls `0x144209d60`. **[H]** |
| Its input struct (`param_7`) | Fields read at `+0x10` (optional flag), `+0x14` (vec3), `+0x1c`, `+0x28`, `+0x29`, `+0x2a`, `+0x2b`, `+0x2c`, `+0x2d`, `+0x2e` | Matches `eoc::spell_cast::AnimationRequestOneFrameComponent` / `AnimationInfoComponent`: `TargetHitPosition` optional (flag at +0x10), `TargetPosition` +0x14, `field_28`, `TargetIsCaster`, `LoopingCastAnimation`, `CacheFlag256`, `DualWielding`, `HasWeapon`, `ObjectSize`. **[H]** layout match, **[M]** identity |
| Event writer | `0x144209d60` (only caller: the builder) | Inserts into a per-entity hash map at system `+0x130/+0x140/+0x150`. This is the shape of `eoc::animation::GameplayEventsOneFrameComponent { HashMap<EntityHandle, Array<ReceivedEvent>> }`. `ecl::animation::GameplaySystem` / `EventDispatchSystem` then forward it to the blueprint queue. **[M]** |
| Side events raised by the same builder | `0x144209660` → event FS `0x145EED6BC` (`0df4bd9f-9a34-4714-a7be-3bb6b7c6844d`, 4 args: 3 × Vector3 + 1). Only when the optional `TargetHitPosition` is set. `0x144209520` → FS `0x145EED6C0` (`96516143-3fb4-4838-aa83-654a6a3e76d9`, Vector3, ?, Vector3: target position). `0x144209360` → FS `0x145EED6C8` (`43b4462a-cdc9-478f-9f09-897127f39985`, 1 FixedString: spell-cast id) | **[H]** wiring, **[M]** meaning |
| FS registration of all event GUIDs | Static-init block `0x140f34de0–0x140f35d80` (`lea rax,"<guid>"` → FS ctor `0x1440f7a40` → `mov [global],eax`). Teardown list: `0x140f36840` | **[H]** |

Unique pattern for the builder (1 hit in `.text`; the 4 masked bytes are the security-cookie displacement):
```
40 55 53 56 57 41 54 41 55 41 56 41 57 48 8D AC 24 68 FC FF FF 48 81 EC C8 04 00 00
48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 85 80 03 00 00 4C 89 4D B0 4C 89 45 C0 4C 8B FA 48 89 55 20
```

### Blueprint side (Characters_Common, the humanoid gameplay blueprint)

- **Main spell event `ba293d56-e14d-4d62-8151-4d63f1257bcd`** (FS global `0x145EED6AC`). The compiled node 1494 has 21 outputs, with these types in order:

  | Args | Type | Probable role **[M]** |
  | --- | --- | --- |
  | 0–5 | `AnimationSimpleName` | Anticipation / Prepare / Loop / Recover-type slots |
  | 6–8 | `ShortNameSet` | `SPELL_CastSet` / `SPELL_CastSetHigh` / `SPELL_CastSetLow` (variables #613/#22/#611). This is why the second Fire Bolt played the **same** Cast/Recover clips under **different** mapping ids: a set is drawn at random. |
  | 9–11 | `AnimationSimpleName` | |
  | 12, 13, 15, 17 | `Bool` | `SPELL_bCastIsLooping`, dual-wield, has-weapon… |
  | 14, 16, 18 | `Enum` | `SPELL_CastAnimationType`, `SPELL_ThrownObjectSize`… |
  | 19 | `FixedString` | `SPELL_CurrentSpellCastUUID` |
  | 20 | `AnimationSetID` | `SPELL_CachedAnimSet` |

  Outputs 0–11 feed a single `GenomeNodeType_FunctionCall` (node 1503). That function writes the `SPELL_*` variables; the exact slot-to-variable order sits inside compiled code pages and was **not** decoded. Get it in-game (step 1 below).
- **Second event `e8545375-1537-4eba-b045-0cee8a0ad64c`** (FS `0x145EED6B4`, 9 args: ASN, ?, ?, ASN, ?, ?, Bool, Enum, Enum). Probably the Cast / CastContinue update. **[L]**
- **Relevant public variables** (indices are this blueprint's; Gale reported 1794 variables, close to the 1779 + extern here):
  - `SPELL_Prepare` 466, `SPELL_Loop` 214, `SPELL_Recover` 227, `SPELL_RecoverHigh` 92, `SPELL_RecoverLow` 4, `SPELL_Anticipation` 203 (`High` 586, `Low` 369), `SPELL_Cancel` 32, `SPELL_Dash` 545.
  - `SPELL_eSpellState` 407 (Enum), `SPELL_bIsPrepareActive` 126, `SPELL_bCastIsLooping` 432, `SPELL_bCastLoopIsInterrupted` 651, `SPELL_CastAnimationType` 249, `SPELL_AnimationIntent` 224, `SPELL_CurrentSpellCastUUID` 495, `SPELL_LastFinishedSpellCastUUID` 555, `SPELL_SpellCastNotified` 216, `SPELL_IsCastFinished` 451.
  - **The type `AnimationSimpleName` holds a mapping-id GUID string.** The throw defaults prove it: `SPELL_ThrowCast` = `3ad7bf24-…`.
- **Internal events** (state enter/exit, sent by the graph to itself or to the game):
  - `OnSpellPrepared`, `PrepareLoop_Entered` / `_Exit`, `OnPrepareStateExit`, `SpellAnticipationEntered` / `Exiting`.
  - `OnCastEnterStart`, `OnCastA*` / `OnCastB*` (two cast slots alternate, hence `SPELL_CastIndexA/B`).
  - `OnSpellCastFinishEnter*`, `SpellCancel*`, `PrepareCancelComplete*`, `SpellCastStateExit`, `SPL_RecoverEntered`, and `Script_SpellFinished` (`SPELL_Script_SpellFinished_Event`).
- **Engine → blueprint extern variables** (`CharacterContext` / `AnimationGameObjectVariables` groups, #670–715 and #900) are movement and steering only:
  - `MovementSpeedCurrent` / `Desired` / `Retained`, `MovementTemplateSpeed*`, `bMovementIsController`, `bMovementIsSneaking`.
  - `SteeringRotationDesired`, `SteeringLookAt*`, `JumpingTrajectoryDirection`, `WorldTransform`…

  None of them is spell-related, so the spell state is driven only by the gameplay events above. **[H]**

### How the mapping id reaches socket 0 of the PlayAnimation node

The event arg lands in a stack variable, and a function call copies it to a public `SPELL_*` variable (`AnimationSimpleName`). The FromActiveSet node's socket 0 (`ctx+0x48`, see [anim-clock.md](anim-clock.md)) is bound to that variable, or to a stack copy of it. The node resolves the mapping id through the character's active AnimationSet, so the stance-resolved clip plays. **[M]**

## Q2: full-body or layered?

**Full-body.** **[H]** for structure, **[M]** for what you'd see.

- Node inventory (2118 nodes):
  - 344 `ServerNode_PlayAnimationFromActiveSet`, 70 `…FromSpecificSet`, 161 `ServerNode_State`, 54 `ServerNode_StateMachine`.
  - Blend nodes: 215 `BlendByBool`, 36 `BlendByEnum`, 11 `BlendByInt`, 25 `ServerNode_Blend`, plus `BlendSpace*`.
  - 63 `SaveCachePose`, 8 `GetSlotAnimationPoseNode`, 2 IK solvers.
- **No bone-mask or bone-group blend input anywhere.** `ServerNode_Blend` always takes `(alpha, poseA, poseB)`.
- `ACT_UpperBodyBlend` (#587) exists, but no node reads it. It only appears in one function's event list, and is likely a leftover. `DIAG_EMOT_BlendUpper` / `Lower` are dialogue-face/emotion blends.
- **Root-motion slots:** `""` (main, sequence 0) and `"1"` (seq 679) carry the body. `Weapon`, `Wings`, `Tail`, `Tentacles` and `HeadwearRemap` are attachment skeletons.
- **Layering that does exist is additive:** the PlayAnimation socket 4 `LoopAnimationAdditive`, and the `ATT_*` / `LOCO_CanPlayMovingStartAdditive` additives.
- `SR_LayeredTurn_R/L_01_Loop` at PlayRate 0.4–2.0 during prepare is the steering-rotation turn-in-place additive (`SR_*` variables) that rotates the caster toward the target while holding the prepare.
- **Consequence:** while the spell state owns the pose, the legs play the prepare/loop clip, not locomotion. If the capsule moves at the same time, the body **slides**.
  - In first person the player mostly sees arms, so this may be acceptable for the caster.
  - Co-op partners will see the slide.
  - Real "legs walk, arms cast" needs either our own blueprint (an override with a masked layer, built in the Toolkit) or a native pose-blend hack. Neither is cheap.

## Q3: what roots the character

| Candidate | Finding |
| --- | --- |
| `Osi.PlayAnimation` | Becomes `eoc::script::PlayAnimationRequestOneFrameComponent` plus a server **Osiris/action-queue task**. The task occupies the character's action slot, and that cancels MoveTo. This is the rooting we see today. **[M]** |
| Vanilla prepare | Driven by the server spell-cast state (`esv::spell_cast::StateComponent`, `eoc::spell_cast::IsCastingComponent`). Our WASD path is client MoveController/MoveTo, which the server UseSpell flow normally cancels. `AllowMoveAndCast` / `MoveDuringCast*` / `SteeringSpeed_CastingCurve` belong to move-to-range and Rush/dash spells, not free WASD. **[M]** |
| Blueprint | Does **not** stop the capsule. It only owns the pose. Root motion would be the only way, and spell clips are not root-motion movers. **[M]** |

**Where to neutralise it:** don't. Avoid both rooting paths, the Osiris PlayAnimation task and a real spell cast during the prepare, and drive the blueprint directly instead (Q4 lever a). The server learns about the cast only at release (our own `Osi.UseSpell` or damage path), when stopping briefly is acceptable.

## Q4: levers, ranked

### 1. (a) Queue the vanilla spell gameplay event from client Lua (SE)

**Recommended.**

**API:**
```lua
Ext.System.AnimationBlueprint:QueueGameplayEventToGenome(ent.Handle, "ba293d56-e14d-4d62-8151-4d63f1257bcd", args)
```
- `args` is an array of up to 22 `{Type = …, Value = …}`, following the type order in Q1.
- Prepare/loop: fill the `AnimationSimpleName` slots with the spell's `SpellAnimation` mapping ids (Fire Bolt: prepare `3ff87abf…`, loop `d8925ce4…`, cast `38cdb41c…`, recover `85414f5f…`).
- Cast: send the cast event (`e8545375…`, 9 args), or the same main event with the cast data. The exact semantics are to be confirmed in-game.

**Constraints:**
- **Thread:** the queue is locked by SE, so calling it from any client Lua tick is safe.
- **Client only:** `AnimationBlueprintSystem` is `ls::`, mapped in `ClientObjects.inl`.
- **Multiplayer:** each client must queue the event on its own copy of the caster. The server broadcasts `DAG_SpellAnim{caster, phase, ids}` on our net channel. Nothing touches server truth.

**What it plays:** the vanilla full-body spell state. Movement is untouched: the capsule keeps WASD/MoveTo/jump, and the legs slide (Q2).

**Risk:**
- **[L]** the graph may require the "action machine" to be in a spell action, entered through `OnActionStarted` / `ActionMachine`. If so, the event is ignored. Fallback: also queue `OnActionStarted`-style events (GUID events, not decoded).
- Locomotion events from MoveTo may kick the state machine out of the spell state every frame (the `OnMoving_*` transitions). The test shows which wins.
- Cancel: there is a `SPELL_Cancel` mapping plus `SpellCancel*` states. Look for the cancel event GUID among the unlabeled ones (`44065f06…`, `c3cd0191…`, …) in-game.

### 2. (c) Write `SPELL_*` variables from Lua

`ent.AnimationBlueprint.Instance.Variables[i] = {Type, Value}` (the QSAT technique, [anim-speed.md](anim-speed.md)). On its own this does **not** enter the spell state; it only changes what plays when the state is entered. Use it together with (a), or to swap the clip played by the real cast (e.g. force `SPELL_Prepare` = "" so the prepare is skipped). **[M]**

### 3. (d) Socket-0 override in our existing Execute hook `0x143a498f0`

The hook already sees every PlayAnimation-type node for one instance. Replacing the animation FS of a locomotion node with our clip would play it full-body, with the same slide, and lose walking. Using socket 4 (`LoopAnimationAdditive`) on a locomotion node to add the prepare loop **additively** over walking is the only "legs walk" option without a new blueprint.

**Risks:**
- Full-body additive clips distort the pose.
- It is per-node and per-frame.
- The pattern and layout are in [anim-clock.md](anim-clock.md).

**[L]**, experimental.

### 4. (b) Hit-animation request path

`esv::hit::HitAnimationRequestOneFrameComponent` is server-side. It raises hit-reaction genome events (`HitAnimationType` enum, no mapping id), so it cannot carry a spell clip. Rejected. **[M]**

### 5. Native call of the builder `0x144208030`

It needs a live `AnimationRequest`-shaped struct, the system pointer and the entity. That is strictly worse than (a), which hits the same blueprint queue with fewer assumptions. Rejected.

## Q5: skip the engine prepare on `Osi.UseSpell`

- **The blueprint already handles a missing prepare.** `IsShortnameValidAnim(SPELL_Prepare, …)` (node 481) branches around the prepare state. **[M]**
- **Lever:** at spell registration, set the spell's `SpellAnimation` slot 0 (prepare) to empty with `Ext.Stats` on the server, plus `Sync`. Optionally blank slot 4 (loop) too. Then `Osi.UseSpell` plays Cast + Recover only, and our Lua plays prepare/loop through lever (a) beforehand.
  - This changes presentation only, not effects. It is in line with "spells stay BG3 data" but **needs a DECISIONS.md entry**.
- **`SpellFlags.ImmediateCast`** exists (string `ls.thoth.shared.SpellFlags.ImmediateCast`). It may also skip preview/prepare, but its effect wasn't traced. **[L]**
- **Unknown:** whether the server's UseSpell still idles for a prepare duration. The log timestamps of `UseSpell` → `CastEvent` will show it.

## Open in-game questions (numbered for the next playtest)

1. **Arg order:**
   - Cast Fire Bolt normally (vanilla).
   - Every client tick, dump `SPELL_Prepare`, `SPELL_Loop`, `SPELL_Recover`, `SPELL_CastSet`, `SPELL_eSpellState` and `SPELL_bIsPrepareActive` by name from `ent.AnimationBlueprint.Instance.Variables`.
   - Also poll `Ext.Entity.GetAllEntitiesWithComponent("AnimationGameplayEventsSingleton")` → `.Events` (Event FS + Args) and log every event for Gale. This gives the 21-arg layout and the cancel/cast event GUIDs.
2. **Lever (a), standing still:** queue `ba293d56…` with the logged args. Does Gale enter prepare, then loop? Does `SPELL_eSpellState` change?
3. **Lever (a) while moving:** hold W, then queue. Does the spell pose hold (sliding), or does locomotion override it at once? Does the jump still work?
4. **Release:**
   - With slot 0 blanked via `Ext.Stats`, `Osi.UseSpell` → only Cast + Recover?
   - Does movement stop at release, and for how long?
5. **Multiplayer:** a second client sees the same state when its own client queues the event for the remote caster.

## Not done / parked

- Decoding the function at node 1503 (which arg lands in which `SPELL_*` variable). Step 1 above makes it unnecessary.
- Identifying the callers `0x141ce8820` / `0x143435710` by system name. They are probably `ecl::spell_cast` (live cast) and preview/AI.
- The action-machine entry events (`OnActionStarted` / `OnActionMachineStarted` and the unlabeled GUID events).
