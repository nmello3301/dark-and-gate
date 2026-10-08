# Dark and Gate — Roadmap and progress

Tick a box when it is **verified in-game**, not just written. Fill in the dates as you go, so we can compare the estimates with reality.

Estimates assume part-time work (evenings). They are guesses made on 2026-10-07 and will be revised after M0.

## At a glance

| Milestone | What it delivers | Estimate | Started | Done |
| --- | --- | --- | --- | --- |
| Setup | Repo, tools, mod scaffold, deploy and log loop working | 1 evening | 2026-10-07 | |
| M0 Spikes | Answers to the 11 engine questions; fork-Brawl decision | 1–3 weeks | 2026-10-07 | 2026-10-08 |
| M1a Native plugin | C++ DLL exports: camera follow + mouselook, then bones, anim speed/cancel, hit normals | 3–5 weeks | | |
| M1b Combat slice | Longsword chain, blade-path hits, Fire Bolt / Fireball / Misty Step, mana, hotbar, goblins on Brawl-adapted real-time AI | 5–8 weeks | | |
| **Gate 1** | **Combat feels tight** | | | |
| M2 Combat breadth | All 10 weapon families, all spell types, blocking, ranged, first MP smoke test (spike 9 answer) | 6–10 weeks | | |
| M3 Companion AI | Follow / Wait / Camp; archetypes on top of the Brawl adapter | 2–4 weeks | | |
| M4 Native UI | Prepare Hotbar tab (spike 8 answer), first-person HUD, traversal highlights | 3–6 weeks | | |
| M5 Act 1 pass | Encounter overrides, balance, saves, through Act 1 | 4–8 weeks | | |
| M6 Multiplayer | 2–4 player co-op | 4–8 weeks | | |
| **Gate 2** | **Act 1 in 2-player co-op** | | | |
| M7 Acts 2–3 | Campaign pass, public release | 2–4 months | | |

Estimate changes vs. 2026-10-07 originals:

- M1 split into M1a (native) + M1b (combat). Combined 8–13 weeks vs. the
  original 4–8. The slip is honest: six native exports is non-trivial C++,
  and the native plugin blocks the combat slice from feeling right. Camera
  follow + mouselook are the critical path for M1a — once FP looks right,
  the rest of M1a is incremental.
- M3 shrunk 3–6 → 2–4 weeks because the Brawl AI import handles the
  tactical loop; M3 is now mostly archetype tuning + Follow/Wait/Camp UX.
- Everything after M3 unchanged.

The biggest risk to these numbers is animation work in M1 and M2, not code.

---

## Setup

- [x] Game clean, mods installed, DEV-SAVE created
- [x] Git repo, reference repos, LSLib
- [x] Mod scaffold and `scripts/deploy.ps1`
- [x] DarkAndGate enabled in BG3 Mod Manager
- [x] "Dark and Gate loaded" on client and server, visible in the console and in the log files
- [x] First commit pushed to GitHub

## M0 — Engine spikes

Each spike gets a note in `docs/spikes/`. Mark the answer: ✅ yes · ❌ no (use the fallback) · ◐ partial.

| # | Question | Answer | Note |
| --- | --- | --- | --- |
| 1 | Capture LMB / RMB / keys 1–0 and suppress BG3's bindings in first person | ✅ | `Ext.Events.KeyInput` + `MouseButtonInput` with `event:PreventAction()`; verified in [spike 1](spikes/01-input-capture.md). |
| 2 | Camera ray through screen centre → world point and character hit | ✅ | Camera position + forward from `InvViewMatrix`; `Ext.Level.RaycastClosest` with reconstructed hit position. See [spike 2](spikes/02-aim-ray.md). |
| 3 | Read weapon bone positions every frame | ❌ | Weapon bones live in shared skeleton `Pose`, which SE hides from Lua. Only cloth-driven overrides are readable. See [spike 3](spikes/03-weapon-bone-reads.md). Native plugin required. |
| 4 | Play custom animations at a chosen speed and cancel at combo points | ◐ | `Osi.PlayAnimation` triggers clips; no Lua lever for playback speed or clean cancel. Native plugin picks up speed+cancel. See [spike 4](spikes/04-anim-control.md). |
| 5 | Cast a spell at a world point from script, with a short animation | ✅ | `Osi.UseSpell` fires the full engine pipeline unconditionally — ignores action economy, spell prep and known-spell list. Lvl 1 Gale cast Fireball. See [spike 5](spikes/05-spellcast-from-script.md). |
| 6 | Push the ragdoll in the direction of the killing blow | ◐ | `Osi.ApplyStatus("KNOCKED_DOWN")` ragdolls the target; Lua has no handle on direction. M1 uses directional death animations instead. See [spike 6](spikes/06-ragdoll-direction.md). |
| 7 | Freeze one character's animation for a few frames (hit stop) | ❌ | Same speed-field gap as spike 4. Hit stop reuses the native plugin's `SetAnimPlaySpeed`. See [spike 7](spikes/07-hit-stop.md). |
| 8 | Add a tab to the native character menu | ⏳ | **Deferred to M4** (Native UI milestone). M1 uses an ImGui window for the Prepare Hotbar tab, so the native-tab answer isn't needed to start the vertical slice. |
| 9 | Net messages fast enough for hit claims at 2–4 players | ⏳ | **Deferred to M2** (first two-instance MP smoke test). Measuring without a real second client is theatre; M0's shared net plumbing proves the single-client round-trip (`!dag_ping` ~100 ms incl. engine tick). |
| 10 | Geometry raycast fast enough for wall-bounce checks every tick | ✅ | ~0.6 µs per `Ext.Level.RaycastClosest` call. See [spike 10](spikes/10-raycast-throughput.md). |
| 11 | Camera on the head bone; local player's head, hair and headwear hidden on their own client only (no shrinking) | ◐ | Head/hair/beard hide via `RenderableObject.PropertyList.RenderPasses`; FP camera via Native Camera Tweaks preset (`config/native/BG3NativeCameraTweaks.toml`). Chase-cam lag during movement unsolved from Lua — needs native plugin, see [spike 11](spikes/11-head-hiding.md#known-artifact-camera-follow-lag-during-movement). |

- [ ] First-person camera values tuned in `BG3NativeCameraTweaks.toml` (M1, bundled with native plugin camera-follow)
- [ ] True first person: no view inside the head, hands and weapon visible, other players see the full model (M1, bundled with native plugin)
- [ ] Mouse-look without holding the middle mouse button → ❌ **not Lua-reachable, folded into M1 native plugin.** See [DECISIONS 2026-10-08](DECISIONS.md) and `se-api-notes.md`.
- [x] Decision logged: fork Brawl or start fresh → **Option B: fork, project is GPL-3.0.** See DECISIONS 2026-10-08 and [fork-brawl.md](fork-brawl.md).
- [x] Decision logged: data file format for `data/` → **Lua tables.** See DECISIONS 2026-10-08.
- [x] Estimates for M1 onwards revised. M1 split into M1a + M1b above.

## M1a — Native plugin foundation

The DLL that lives in `tools/native/` and loads via Ch4nKyy's Mod Loader.
Order of exports is "what makes FP look right first", so M1b can start as
soon as the camera is usable.

- [ ] Build setup: Visual Studio C++ project, Ch4nKyy loader stub, DKUtil hook pattern-scan. Template: Native Camera Tweaks source.
- [ ] Head-bone-read spike ([m1a-bone-reads.md](spikes/m1a-bone-reads.md)) running in parallel with camera follow — exports `GetBoneWorldPos(entity, bone)` once the Granny node vtable is resolved.
- [ ] **Camera follow + mouselook** (combined — same hook): read mouse delta, drive camera yaw/pitch, place camera at a Lua-chosen bone/world point each frame. Unblocks true first person.
- [ ] FP camera values finalized in `BG3NativeCameraTweaks.toml` once mouselook is live.
- [ ] True first person: local head / hair / beard / headwear hidden (Lua side already works; native covers the follow lag).
- [ ] `GetBoneWorldPos(entity, boneName) → vec3`. Unblocks the blade-path hit check.
- [ ] `SetAnimPlaySpeed(entity, mult)` and `CancelAnim(entity)`. Unblocks swing-chain timing + hit stop.
- [ ] `RaycastHitNormal(from, to) → vec3?`. Unblocks surface-aligned blood / spark effects.
- [ ] (Stretch, deferred unless M1b feel demands it) `PushRagdoll(entity, vec3, force)`.
- [ ] Smoke test: FP camera stays on the head, mouse look rotates smoothly, blade-path hits visibly land in the right places.

## M1b — Combat vertical slice

Depends on M1a camera + mouselook being usable. Everything else in M1a can
land in parallel with M1b work.

- [ ] Brawl import wired in: `Server/Brawl/` strips committed, `BrawlAdapter.lua` bridges Brawl's AI into our net channels and mana check.
- [ ] Real-time combat loop (Brawl's RealTime pulse) running on DEV-SAVE goblins.
- [ ] Longsword: 3-swing chain with timing data (`data/weapons/longsword.lua`).
- [ ] Blade-path hit check, with head / torso / limb zones. Uses `GetBoneWorldPos`.
- [ ] **AI melee goes through our swing + blade-path system, not BG3 attack rolls.** `Pick.decideActionOnTarget` adapted so melee choices resolve through the swing scheduler, not `Osi.UseSpell`.
- [ ] Blocking and parry with a shield.
- [ ] Fire Bolt aimed at the crosshair (uses the aim ray from spike 2).
- [ ] Fireball with a ground preview.
- [ ] Misty Step to the crosshair (needs a position-based cast; probe `Osi.UseSpellAtPosition` or spawn a transient target).
- [ ] Mana pool, regeneration and costs (server-owned).
- [ ] Hotbar on keys 1–0 (ImGui window to set it up — native tab is M4).
- [ ] Hit reactions and blood/spark effects (uses `RaycastHitNormal` for surface alignment).
- [ ] Goblin enemies on the shared Brawl-adapted AI.
- [ ] The Emerald Grove gate fight playable start to finish in DEV-SAVE.
- [ ] **Gate 1 — combat feels tight.** Playtest notes written; go / no-go recorded in `DECISIONS.md`.

## M2 — Combat breadth

- [ ] All 10 weapon families with their chains
- [ ] All spell types from the targeting table (projectile, area, cone, single target, teleport, wall, summon, self, reaction)
- [ ] Bows, crossbows and thrown weapons
- [ ] Class features in real time (Sneak Attack, Divine Smite, Rage, Action Surge, and the rest of the table)
- [ ] AC as damage reduction; crits; advantage and disadvantage
- [ ] First two-instance multiplayer smoke test

## M3 — Companion AI

- [ ] Follow / Wait / Camp modes, V key
- [ ] Companions join fights and return to their previous mode afterwards
- [ ] Archetypes, kit limited to "AI may use" slots, mana reserve
- [ ] Friendly-fire avoidance (swing arc, area spells)
- [ ] Healing and reviving downed allies
- [ ] Party frames and downed callouts

## M4 — Native UI

- [ ] Prepare Hotbar tab in the native character menu
- [ ] First-person HUD: crosshair and reticles, health and mana, hotbar strip
- [ ] Enemy cast bars, hit markers, directional damage
- [ ] Traversal highlights on vines, ladders, climbable walls, stairs and ledges

## M5 — Act 1 pass

- [ ] Every Act 1 fight played in real time; overrides file filled in
- [ ] Turn-based fallback toggle works everywhere
- [ ] Saving and loading mid-fight
- [ ] Balance pass on swings, mana and damage

## M6 — Multiplayer

- [ ] Hit claims and validation over the network
- [ ] Mana, hotbar and mode sync
- [ ] Each player's companions follow that player
- [ ] **Gate 2 — Act 1 in 2-player co-op**, with a friend

## M7 — Acts 2–3 and release

- [ ] Act 2 fight pass
- [ ] Act 3 fight pass
- [ ] Install guide and mod page
- [ ] Public release
