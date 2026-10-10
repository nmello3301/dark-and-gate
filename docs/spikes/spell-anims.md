# Spell animations: which clips, and who plays them

**Status:** 2026-10-10. Recording plus stats verified; the non-rooting playback path is being researched statically ([spell-anims-native.md](spell-anims-native.md)).

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
| 6 | unknown, not played in the recording | `eadedcce` |
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
