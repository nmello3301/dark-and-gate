# Animation browser + gallery: engine facts

**Status:** verified in-game 2026-10-09 (browser, filters, gallery, notes, play rate); first playtest doc ([playtest/animlib.md](../playtest/animlib.md)). Fill in the "Verified" column from the logs.
**SE:** v32 · **BG3:** Patch 8

## Finding a character's own animations

| Path | What it gives | Verified |
| --- | --- | --- |
| `ent.AnimationSet.Entries[i].Resource` (`ls::AnimationSetComponent`, SE `Components/Visual.h`) | the AnimationSet resource ids the character uses | ✅ 2026-10-09 Gale: 6 sets, 13184 mappings -> 6878 clips in 1.8 s, rig HUM_M |
| `ent.AnimationWaterfall.Waterfall[i].Resource` | the same, through the waterfall (used if the first is empty) | ☐ |
| `Ext.Resource.Get(set, "AnimationSet").AnimationBank.AnimationSubSets[sub].Animation[mappingId].ID` | mapping id → Animation resource | ✅ (Anims.lua, JumpAnims.lua) |
| `Ext.Resource.Get(id, "Animation").SourceFile / .Duration` | clip file and length | ✅ (2026-10-09 jump scan: Ascend 0.60 s, Recover 1.70 s) |
| Global index (every set, `!dag_animlib global`) | coverage per rig + fallback list | ✅ 349713 mappings in 2331 sets, 25 s (ticks ran 2-5 ms: one big set's pair collection can't be split) |

**Rig** = the most common `<RACE>_<BODY>` prefix of the clip names (e.g. `HUM_M_Rig_…`). If a character has no sets, the rig comes from the visual template name.

## Mapping ids and rigs (hypothesis to verify)

The same mapping id resolves to a different clip per weapon stance and per rig, through each character's own AnimationSet. Evidence so far: jump mapping `8ee67630…` was stored against the `ST` (staff) clip in our scan, yet it is a stance-independent JumpFlight id. Tags therefore store the **mapping id**, plus optional per-rig overrides. If a rig has no clip for the id, the fallback is that rig's DFLT clip with the same category and phase.

## Test matrix (fill in from the playtest)

| Character | Rig shown | List size | swing1 tag plays | Coverage gaps |
| --- | --- | --- | --- | --- |
| Gale | | | | |
| Shadowheart | | | | |
| Karlach | | | | |
| Lae'zel | | | | |
| Dwarf / halfling custom | | | | |

## Gallery copies

- **Template:** chosen by name tokens per rig (`Server/AnimLib.lua`, `RIG_TOKENS`, generic NPC words preferred, story / combat / summon names pushed down). The browsed character's own template is the fallback. Logged as `AnimLib: gallery N copies of rig X using template …`. Override: `!dag_animlib template <uuid>`.
- **Inert:** `SetCanJoinCombat 0`, `SetCanFight 0`, `SetHasDialog 0`, boost `Invulnerable()` (each result logged once in `AnimLib: copy setup …`).
- **Facing the player:** `Osi.SteerTo(copy, player, 1)` is a probe; the result is logged once.
- **Removal:** `SetOnStage 0`, `SetHasDialog 0`, `RequestDelete`, `RequestDeleteTemporary` (Brawl's recipe). Triggered by menu close, `!dag_animlib clear`, the `Save` game state (the uuid list is kept on disk) and `LevelGameplayStarted` (leftovers from `animlib-spawned.txt`).

## Playtest 1 (2026-10-09)

- **Template:** `BASE_Elves_Male_Drow_Lolth_Civilian` for HUM_M (63 ms scan, 275 candidates).
- **Spawn:** 12 copies in 547 ms.
- **Copy setup:** `SetCanJoinCombat`, `SetCanFight`, `SetHasDialog` and the `Invulnerable()` boost all returned ok. `Osi.SteerTo` returned ok; whether the copies actually face the player is not reported yet.
- **The copies played nothing.** No PlayAnim reached the server. The page handed to the gallery was empty: the Family dropdown offered values from the whole list (SCENE 1513 under Melee), so the combined filters matched nothing.
- **Fix:**
  - The dropdowns now cascade: each lists only values present under the other filters.
  - Cutscene / photo-mode clips are hidden by default.
  - Families have plain labels.
  - The gallery logs `gallery page -> N clips` (warning on EMPTY) and its first plays.

## Playtest 3 (2026-10-09): verified

- Browsing, cascading filters, paged gallery (one clip per civilian, pages loop) and cleanup on close all work.
- Notes: 9 picks logged to `anim-notes.txt` (copied to [docs/anim-picks-2026-10-09.txt](../anim-picks-2026-10-09.txt)).
- Play rate: the native hook patched 6 vtable slots and scales Gale's clips (slow, freeze, fast).
- **Mapping ids are stance-resolved.** The same id `f4ac302b…` was logged as 1HPSH and as 1HSSH. A civilian with the 1HSSH stance played that clip; Gale played his own stance's. Exact-clip playback is the next step.
