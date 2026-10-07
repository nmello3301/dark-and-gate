# Dark and Gate — Roadmap and progress

Tick a box when it is **verified in-game**, not just written. Fill in the dates as you go, so we can compare the estimates with reality.

Estimates assume part-time work (evenings). They are guesses made on 2026-10-07 and will be revised after M0.

## At a glance

| Milestone | What it delivers | Estimate | Started | Done |
| --- | --- | --- | --- | --- |
| Setup | Repo, tools, mod scaffold, deploy and log loop working | 1 evening | 2026-10-07 | |
| M0 Spikes | Answers to the 11 engine questions; fork-Brawl decision | 1–3 weeks | | |
| M1 Vertical slice | Longsword, Fire Bolt, Fireball, Misty Step, mana, hotbar, vs goblins | 4–8 weeks | | |
| **Gate 1** | **Combat feels tight** | | | |
| M2 Combat breadth | All 10 weapon families, all spell types, blocking, ranged | 6–10 weeks | | |
| M3 Companion AI | Follow / Wait / Camp; shared real-time AI | 3–6 weeks | | |
| M4 Native UI | Prepare Hotbar tab, first-person HUD, traversal highlights | 3–6 weeks | | |
| M5 Act 1 pass | Encounter overrides, balance, saves, through Act 1 | 4–8 weeks | | |
| M6 Multiplayer | 2–4 player co-op | 4–8 weeks | | |
| **Gate 2** | **Act 1 in 2-player co-op** | | | |
| M7 Acts 2–3 | Campaign pass, public release | 2–4 months | | |

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
| 4 | Play custom animations at a chosen speed and cancel at combo points | | |
| 5 | Cast a spell at a world point from script, with a short animation | | |
| 6 | Push the ragdoll in the direction of the killing blow | | |
| 7 | Freeze one character's animation for a few frames (hit stop) | | |
| 8 | Add a tab to the native character menu | | |
| 9 | Net messages fast enough for hit claims at 2–4 players | | |
| 10 | Geometry raycast fast enough for wall-bounce checks every tick | | |
| 11 | Camera on the head bone; local player's head, hair and headwear hidden on their own client only (no shrinking) | ◐ | Head/hair/beard hide via `RenderableObject.PropertyList.RenderPasses`; FP camera via Native Camera Tweaks preset (`config/native/BG3NativeCameraTweaks.toml`). Chase-cam lag during movement unsolved from Lua — needs native plugin, see [spike 11](spikes/11-head-hiding.md#known-artifact-camera-follow-lag-during-movement). |

- [ ] First-person camera values tuned in `BG3NativeCameraTweaks.toml`
- [ ] True first person: no view inside the head, hands and weapon visible, other players see the full model
- [ ] Mouse-look without holding the middle mouse button
- [ ] Decision logged: fork Brawl or start fresh
- [ ] Decision logged: data file format for `data/`
- [ ] Estimates for M1 onwards revised

## M1 — Vertical slice

- [ ] Real-time combat loop (from Brawl or our own)
- [ ] Longsword: 3-swing chain with timing data
- [ ] Blade-path hit check, with head / torso / limb zones
- [ ] Blocking and parry with a shield
- [ ] Fire Bolt aimed at the crosshair
- [ ] Fireball with a ground preview
- [ ] Misty Step to the crosshair
- [ ] Mana pool, regeneration and costs (server-owned)
- [ ] Hotbar on keys 1–0 (ImGui window to set it up)
- [ ] Hit reactions and blood/spark effects
- [ ] Goblin enemies on the shared real-time AI
- [ ] **Native plugin** (`tools/native/`) bundling the engine hooks that Lua can't reach: tight camera follow (spike 11 gap) + named-bone world positions (spike 3 gap). Must-have before Gate 1 — the melee blade-path hit check depends on bone reads. See [spike 3](spikes/03-weapon-bone-reads.md) for scope.
- [ ] The Emerald Grove gate fight playable start to finish in DEV-SAVE
- [ ] **Gate 1 — combat feels tight.** Playtest notes written; go / no-go recorded in `DECISIONS.md`

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
