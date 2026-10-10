# Spell animations: which clips, and who plays them

**Status:** 2026-10-10. Recording plus stats verified; event layouts captured ([genome-capture.md](genome-capture.md)); playback by replaying BG3's select / cancel events is built, not verified in-game yet.

## The recording ([anim-record-2026-10-10.txt](../anim-record-2026-10-10.txt))

Gale, normal camera (POV off), vanilla BG3 casts through the hotbar.

**Every clip in it was played by the engine, none by our code.** The recorder was stopped at +70 s and POV was turned on only at +154 s, so the input gate (POV on) was closed. The window contains no `Spells:` / `Hotbar:` / `Prepare:` lines and no server `Net: PlayAnim` lines. The prepare animation is also off in data.

| t ms | Node | Mapping id | Clip | Notes |
| --- | --- | --- | --- | --- |
| 8562 | FromActiveSet | `3ff87abf…` | `HUM_M_Rig_VIO_SPL_Bard_01_Prepare` 2.13 s | spell selected |
| 9484 | FromActiveSet | `d8925ce4…` | `…Bard_01_Loop` 6.20 s, loop | held while targeting |
| 11531 | FromSpecificSet | `38cdb41c…` | `…Bard_Damage_01_Cast` 2.43 s | click |
| 12937 | FromSpecificSet | `85414f5f…` | `…Bard_Damage_01_Recover` 0.30 s | |
| 13406 | FromSpecificSet | `b7a713aa…` | `HUM_M_Rig_Gale_DFLT_IDLE_Neutral_Peace_01_Transit` | back to idle |

- **During the prepare:** `HUM_M_Rig_DFLT_SR_LayeredTurn_R/L_01_Loop` (FromSpecificSet, play rate 0.4–2.0) played. This is a layered turn while targeting.
- **Cast variants:** the 3rd cast used different mapping ids for the same Cast / Recover clips (`cd5e5d4a…`, `141f48d9…`), so the engine has a variation pool beyond the stat ids.

## Generic source: the spell's SpellAnimation stats

Fire Bolt (`Projectile_FireBolt`, Shared/Gustav `Spell_Projectile.txt`):

```
SpellAnimation "3ff87abf…,,;,,;38cdb41c…,,;85414f5f…,,;d8925ce4…,,;,,;eadedcce…,,;,,;,,"
```

| Slot | Role | Fire Bolt |
| --- | --- | --- |
| 0 | **prepare** | `3ff87abf` (recorded) |
| 1 | (empty) | |
| 2 | **cast** | `38cdb41c` (recorded) |
| 3 | **recover** | `85414f5f` (recorded) |
| 4 | **loop** | `d8925ce4` (recorded) |
| 5 | (empty) | |
| 6 | **cancel** (sent on right-click cancel; genome capture round 2) | `eadedcce` |
| 7, 8 | (empty) | |

- Fireball uses the same family.
- Misty Step has its own ids: `dd86aa43` / `39daf365` / `5c400e93` / `cc5b0caf`.
- The old `Prepare.lua` took slot 1 as the loop. Slot 1 is empty on these spells, so Fire Bolt's real loop was never found.

`Client/Combat/SpellAnims.lua` resolves these per caster through the caster's own AnimationSets (mapping id → clip, per rig and stance). Gaps fall back to the `spell_anims.fallback` family in `data/spells.lua` and are logged as a coverage line. `!dag_spell_anims <spell>` prints the result.

## Cast time

`Spells.CastTime(spell)` = `base_cast_s` (data, per spell override, or `!dag_cast_time`) × `Spells.AddCastTimeModifier` factors. It is fixed at arm time.

The client sends its effective time with `SpellArm`. The server floors it at `min_cast_s` and rejects earlier releases. Once traits exist server-side, the server computes it.

## Per-clip play rate (native)

`AnimRate::SetClipRates(instance, "id:rate,…")` scales only the nodes whose animation input (socket 0 FixedString = mapping id) matches. It is used to:

- stretch the prepare to exactly the cast time (rate = prepare duration / cast time) without speeding up the legs;
- fast-forward the engine's own prepare / loop at release, so it isn't played twice.

## Weapon stance (2026-10-10)

Playtest: the replayed select event animated Gale, but not with the same prepare animation as vanilla.

- The mapping id is the same, but the blueprint resolves it in the **active** animation subset, and that subset follows the drawn weapon.
- The vanilla capture shows the stance change in the same frame as the select: `ad925ffc` with `Staff2H` / `Unarmed1H`, then `35ddd8c7`. Vanilla targeting draws Gale's staff, so the staff variant of the prepare plays. Our channel left him sheathed.
- **Fix:** on `SpellArm` the server calls `Osi.SetWeaponUnsheathed(char, 1, immediate)`, the 3-arg builtin the game's own story uses (`_CRIME_CrimeTriggers`, `GLO_Camp`). The choice follows the spell's `Sheathing` stat; the map is in `data/spells.lua` `spell_anims.unsheath`.
- The client holds the select event for up to `wait_s` until `ent.Unsheath.State` leaves `Sheathed`. It then stretches the prepare over the rest of the cast time.
- `!dag_spell_anims <spell>` now lists every clip an id maps to in each set / subset, plus the current stance. Our duration still comes from the first match, so the stretch can be slightly off until the staff clip is identified.

**Result (playtest, 2026-10-10): wrong.** Vanilla doesn't draw the staff; Gale does hand gestures with the fire. Our version still shows a different animation even with the staff drawn. The draw is now off (`unsheath.enabled = false`, the code is kept). Next: record vanilla and ours in the same session (`!dag_anim_record` gives the graph node, its class and the mapping id) and compare.

## Side-by-side recording (2026-10-10)

`!dag_anim_record` with a vanilla select and then ours, in one session (the second was cast, not cancelled):

| | Vanilla | Ours |
| --- | --- | --- |
| Prepare `3ff87abf` | node `…CDA0`, FromActiveSet | node `…CDA0`, FromActiveSet |
| Loop `d8925ce4` | node `…CE20`, FromActiveSet, +0.94 s | node `…CE20`, FromActiveSet, +1.56 s |
| Other PlayAnimation nodes during the prepare | LayeredTurn L/R (turning toward the cursor) | none until the cast |

- The graph runs the **same clips on the same nodes**, so the select replay is exact.
- The genome capture also shows vanilla sends the select event to the targeting-preview dummies (`…233A1` / `…233B1`, with a `Private Parts` event). That is preview only.
- **Open:** what the developer sees as "a different animation". Candidates: the first-person view (camera following the head bone, head hidden), or something outside PlayAnimation nodes (look-at / aim, blend layers). Next test: `!dag_prepare_test` runs our channel with the normal camera, for a direct comparison.

**Third-person check (playtest, 2026-10-10):** `!dag_prepare_test` with the normal camera is **clearly a different clip**.

- **Vanilla:** standing tall, feet a little wide, facing the aim point, fire in the right hand, left hand holding the right elbow, hand signs every ~3 s.
- **Ours:** low sideways stance, legs spread, left hand extended as if aiming, right hand cocked like a throw, occasional forward flinch.

So the same node and mapping id resolve to a different clip. Something on the character that vanilla targeting sets steers the resolution: a blueprint variable, animation tag or set override. Probe: `!dag_anim_state <label> [delay]` (`Client/AnimLib/AnimState.lua`) snapshots blueprint variables (named), DynamicAnimationTags / AnimationWaterfall / AnimationSet / overrides, the component list and a full component dump, for a vanilla vs ours diff.

## Snapshot diff: the casting animation set (2026-10-10)

`!dag_anim_state` taken during vanilla targeting and during ours (`anim-state-*.txt`). Blueprint variables only differ by timers. The real differences:

| | Vanilla targeting | Ours |
| --- | --- | --- |
| DynamicAnimationTags | `a865965f` type 0 **and type 1** | `a865965f` type 0 only |
| AnimationSet.Entries[1] | **`745fbb35…` Dynamic** (Visual) | (absent) |
| Components | `eoc::spell_cast::IsCastingComponent` | (absent) |

- Gale's `AnimationWaterfall.Overrides` maps tag `a865965f` with **OverrideType 1** to set `745fbb35`.
- The type-1 copy of the tag activates that override, and the set goes first in the AnimationSet. The prepare / loop ids then resolve there: the standing, elbow-holding casting pose, instead of the generic low "throw" stance.
- None of Gale's other tags has an OverrideType 1 entry.

**Fix:** `Client/Combat/CastTags.lua`. On arm, every type-0 tag with an OverrideType 1 waterfall entry gets a type-1 copy. The select event waits (up to `cast_tags.wait_s`) until the override sets appear in `AnimationSet`. The clips are then re-resolved (`SpellAnims.For(..., fresh)`) for the right durations. The copies are removed `cast_hold_s` after a cast or `cancel_hold_s` after a cancel.

**Open:** whether the engine rebuilds the AnimationSet when Lua writes the tag (logged as "casting set ready / NOT ready"). Also whether other casters use the same rule.

**Tag route result (playtest, 2026-10-10):** the Lua-written type-1 tag was accepted, but the engine did **not** rebuild the AnimationSet from it (`casting set NOT ready`). The old clip played.

**Next round:**
- `cast_tags.force_set` writes the override set into `AnimationSet.Entries` directly (`CastTags.PrependSet`). It is prepended as a Dynamic Visual entry, like the engine's own. Caveat: rewriting the entries from Lua loses their hidden per-entry tag pointers until the save is reloaded.
- `!dag_spell_variants <spell> [gallery]` (`Client/AnimLib/SpellVariants.lua`) lists every distinct clip each phase id maps to across active, waterfall and override sets. `gallery` spawns one civilian per prepare variant, forces that variant's set first on it, and sends BG3's select event to it, so the developer can pick the vanilla pose by eye.

## Gallery result: class casting sets (2026-10-10)

`!dag_spell_variants Projectile_FireBolt gallery` gave 17 prepare variants. Each civilian got its set written first in `AnimationSet` (it started with 0 entries) and played its own variant, so the **direct write does change the resolution**.

| # | Clip | From |
| --- | --- | --- |
| 1–4, 6, 7 | `VIO/DRM/LYR/DFLT/LUT/FLT_SPL_Bard_01_Prepare` | Gale's active sets (instrument variants) |
| 5 | `DFLT_SPL_Sorcerer_Damage_01_Prepare` | active sets |
| 8 | `DFLT_CMBT_Skill_Barbarian_01_Prepare` | override `0b9a711d` |
| 9–13 | `Cleric / Druid / Paladin / Ranger / Warlock_Damage_01_Prepare` | override sets `12deb965 / 45545fc1 / 8e575d96 / dfb571ca / ac911282` |
| **14** | **`DFLT_SPL_Wizard_Damage_01_Prepare`** | **override tag `a865965f` type 1 → `745fbb35`** (the developer's pick = vanilla) |
| 15–17 | `1HSSH / 1HS / DWS_SPL_Bladesinger_Damage_01_Prepare` | `e082392a` |

Our old resolution took the first active set, the Bard violin variant.

**Rule** (DECISIONS 2026-10-10): use the casting set of the class with the most levels. Ties go to `AnimationSetPriority`, then the first class taken. Subclass tags are checked before class tags, and the first tag with an OverrideType 1 set wins. `CastTags.lua` forces that set first.
