# Animation play rate: how QSAT does it

**Status:** method found; NOT available on gameplay characters (no general PlayRate variable, see the probe result) (read-only study of QSAT 2.4.0, BG3AF 1.0.0.1 and "Edited Animation Blueprint for Dani Mode" 1.0.0.4, unpacked into the scratchpad from `downloaded_mods/`). Whether it works on **gameplay** characters is still to be checked in-game with `!dag_anim_vars playrate`.
**Date:** 2026-10-09 · **SE:** v32 · Supersedes the "no Lua lever" conclusion of [spike 4](04-anim-control.md) for the speed part.

## What QSAT does

QSAT (Quick Small Animation Thingy, Nexus 17737) has a "Play rate" drag slider. Moving it writes a **Genome blueprint variable named `PlayRate`** on the selected character's **photo-mode dummy**:

- **Variable names:** `entity.AnimationBlueprint.Resource.Blueprints[1].Variables[i].Name`. QSAT builds a name → index map once per entity.
- **Values:** `entity.AnimationBlueprint.Instance.Variables[i]` is a `{ Type, Value }` table. QSAT writes `{ Type = <same type>, Value = rate }` inside a pcall.
- **Where:** the client Lua state only, with no server involvement and no native code. 1.0 is normal speed.
- **Other variables:** QSAT drives everything else on the dummy the same way, e.g. `BodyAnimationShortName`, `FacialAnimationShortName` and `EnableVanillaPM`.

This is the `PlayRate` input socket that [m1b-anim-speed.md](m1b-anim-speed.md) found on Larian's PlayAnimation Genome nodes: in the photo-mode blueprint that socket is bound to a blueprint variable, so Lua can write it.

## Dependencies

- **BG3AF:** QSAT declares it as a dependency in `meta.lsx`. QSAT uses it for `AnimationSet.Get(set):AddLink(mapKey, animId, subset)`, which re-links which clip a mapping key plays (BG3AF's WaterfallManager). **The play rate does not go through BG3AF.**
- **"Edited Animation Blueprint for Dani Mode":** a `BlueprintOverrides.lsx` in the photo-mode folder that swaps the dummy blueprint of several photo-mode source blueprints for an edited one (`PhotoMode_Characters_Common_Bone_Transforms`). Its strings contain "Speed" and "VanillaPM" but not "PlayRate". So `PlayRate` itself is very likely a vanilla photo-mode variable, and the edit adds other controls. This is not proven; the name table may be stored in a way a string scan misses.
- **The open question:** the dummies QSAT drives use **photo-mode blueprints**. A gameplay character uses its own gameplay blueprint, and nobody has shown that blueprint exposes `PlayRate`. Our own probe answers it:
  ```
  !dag_anim_vars playrate
  ```
  (client console), on Gale.

## In-game probe result (2026-10-09, Gale, `!dag_anim_vars playrate`)

Gale's **gameplay** blueprint has 1794 variables and **no general `PlayRate`**. The play-rate variables it does have:

| # | Name | Likely scope |
| --- | --- | --- |
| 491 | `JumpFlightDescendPlayRate` | the blueprint's own JumpFlight descend state |
| 536 | `JumpFlightAscendPlayRate` | the blueprint's own JumpFlight ascend state |
| 165 | `LOCO_CharacterScalePlayRate` | locomotion, scaled by character size |
| 364 / 608 | `LOCO_ClimbPlayRate_A` / `_B` | climbing |
| 403 | `ATT_AdditiveStillPlayRate` | additive idle layer |
| 28, 449, 353, 497 | `STAT_Incapacitated_*PlayRate*` | incapacitated statuses |

Each value reads as a `gn::GenomeVariant` userdata with `.Type` / `.Value`. The browser's slider therefore reports "not available" on gameplay characters. The jump now tries the two JumpFlight rates; whether they affect clips started by `Osi.PlayAnimation` is being tested, and the log names the variables it set.

**Decision needed (developer):** pick one of the options below for general speed (gallery slider, hit-stop). Nothing has been built for them.

## Our implementation (own code, no copying)

- **`Client/AnimLib/AnimSpeed.lua`:**
  - Finds the variable named `PlayRate`, via the resource blueprint first, then `Instance.Parent`.
  - Writes `{ Type, Value }`.
  - Returns `false, reason` when the blueprint has no such variable.
- **Animation browser:** a play-rate slider (0 = freeze, 0.1–2.0), applied to the target or to every gallery copy. The status line says when the lever isn't available.
- **Jump:** if the player's blueprint has `PlayRate`, the jump clips play at `clipAirtime / jumpAirtime` and reset to 1 on landing; the log says `anim=genome PlayRate x0.88 + phases`. Otherwise the phase substitute stays, unchanged.
- **Later, hit-stop:** `PlayRate` 0 for a few frames, under the same condition.

## Options if gameplay characters have no `PlayRate` variable

Per the developer's instruction, stop and choose before building any of these:

1. **Our own blueprint override.** Edit the gameplay character blueprint so the PlayAnimation nodes' `PlayRate` socket reads a new variable; ship it in our pak. Needs the Toolkit, is per blueprint (races and body types), and we'd own it across patches.
2. **Optional dependency on someone else's edited blueprint.** None found yet for gameplay blueprints. Dani's edit only covers photo mode.
3. **Ask a blueprint author** (QSAT / Dani / BG3AF) whether a gameplay-blueprint `PlayRate` binding exists or could be added.
4. **Native.** Call the node template's `GetInputSocketVariables` (vtable `+0x40`) on the live PlayAnimation node to find the socket's variable index, then write it. This is the plan [m1b-anim-speed.md](m1b-anim-speed.md) parked.

## Credits

The approach was learned from **QSAT** (Quick Small Animation Thingy) by its author, and from **BG3AF** (BG3 Animation Framework). We read their mods to learn from them; none of their files, code or assets ship with Dark and Gate.
