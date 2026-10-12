# Dark and Gate — Roadmap and progress

Tick a box when it is **verified in-game**, not just written. Fill in the dates as you go, so we can compare the estimates with reality.

Estimates assume part-time work (evenings). They are guesses made on 2026-10-07 and will be revised after M0.

## At a glance

| Milestone | What it delivers | Estimate | Started | Done |
| --- | --- | --- | --- | --- |
| Setup | Repo, tools, mod scaffold, deploy and log loop working | 1 evening | 2026-10-07 | 2026-10-07 |
| M0 Spikes | Answers to the 11 engine questions; fork-Brawl decision | 1–3 weeks | 2026-10-07 | 2026-10-08 |
| M1a Native plugin | C++ DLL exports: camera follow + mouselook, then bones, anim speed/cancel, hit normals | 3–5 weeks | 2026-10-07 | 2026-10-08 |
| M1b Combat slice | Longsword chain, blade-path hits, Fire Bolt / Fireball / Misty Step, mana, hotbar, goblins on Brawl-adapted real-time AI | 5–8 weeks | 2026-10-08 | |
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
- **2026-10-12 check-in:** the player side of M1b took four days, much faster than estimated, because BG3's own systems (genome events, class casting sets, the falling state) carried it. What's left is real-time AI (step 1) and the projectile system (step 4). Both carry engine unknowns, so the 5–8 week M1b estimate stays for now.

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

### Status (2026-10-08): first-person camera works ✅

Verified in-game on DEV-SAVE: `client` → `!dag_full_pov`.

- Camera sits at Gale's eyes, head / hair / beard hidden on the local client, body visible when looking down.
- Mouse-look (yaw **and** pitch) is on as soon as POV starts; **MMB toggles** it. WASD walks where you look.
- No follow lag: the camera is anchored to the engine's own *desired* camera point (pre-smoothing) every frame.
- Looking down slides the eye forward (up to 20 cm straight down) so the neck opening never shows.
- Dialogue and cutscenes hand the camera back to the game automatically.

How it works (details in `tools/native/src/Hooks/Pov.cpp`): NCT provides placement and pitch (zoom 0, FOV 90, offset 0.95, pitch unlocked); our DLL hooks the camera commit (`vt[0x58]`), the one call proven to reach the screen, and sets the eye *and* the look-at point together, restoring the camera fields afterwards so nothing persists. Lua (`FullPov.lua`) only tells the DLL on/off, gameplay-active and offsets.

**Kept settings (defaults in code):** `eye_fwd 0.10`, `down_fwd 0.20`, `pivot_up -0.15`, look-at distance 1.0 m. NCT TOML as installed (ZoomMin 0.0, FOV 90, VerticalOffsetMult 0.95, UnlockPitch ±89, MousePitchMult 0.25). Live tuning: `!dag_pov_eye <up> <fwd>`, `!dag_pov_down <m>`, `!dag_pov_status`, `!dag_pov_dump`.

### Checklist

- [x] Build setup: Visual Studio C++ project, Ch4nKyy loader stub, pattern-scan hooks chained with NCT. One-step build: `scripts\pov-build-deploy.ps1` (or `DAG build POV.bat` on the Desktop).
- [x] **Camera follow + mouselook**: `!dag_full_pov`, zero lag, mouse yaw/pitch, MMB toggle. *(2026-10-08)*
- [x] FP camera values finalized (NCT TOML + POV defaults above). *(2026-10-08)*
- [x] True first person: local head / hair / beard hidden, body and arms visible. *(2026-10-08)*
- [x] Raycast hit normals via `Ext.Level.RaycastClosest` (Lua, native not needed).
- [x] Smoke test: FP camera stays on the head, mouse-look rotates smoothly. *(2026-10-08)*

See **Archived (future)** below for bone reads, anim speed/cancel and ragdoll push — moved out of M1a.

### Known issues / polish

- Mouse sensitivity comes from NCT's TOML (`MouseCameraRotationMult`, `MousePitchMult`); an in-game slider (MCM) later.
- Head hiding occasionally needed an off/on toggle; fixed by resetting `hide_head` at session start (verify over a few sessions).
- The game runs `bg3_dx11.exe`; static analysis should use the `bg3_dx11.exe` Ghidra program (now imported).
- Old camera-override experiments (vt58 pin, instant_follow, legacy writes) are parked behind default-off switches in `native-config.toml`.

## M1b — Combat vertical slice

**Gate 1 needs:** the Emerald Grove gate fight in DEV-SAVE played start to finish, in real time and in first person:
- a longsword plus Fire Bolt, Fireball and Misty Step;
- goblins that fight back;
- and it has to feel tight.

### Status (2026-10-12): the player side works; the enemy side doesn't exist yet

What works in first person:
- Gale walks, runs and jumps for real.
- He swings a 3-hit chain.
- He channels spells with BG3's own class casting animations, VFX and sounds, aims them along the crosshair, and pays mana for them.

What doesn't: as soon as the goblins turn hostile, BG3's turn-based combat takes over. The Brawl import (`Server/Brawl/`) is still quarantined (nothing requires it), so every test so far has been against idle goblins or spawned dummies. **Real-time fights are the critical path.**

Lessons recorded:
- `Ext.Require` only works at load time.
- `hit.Distance` is a 0–1 fraction of the ray.
- BG3's view forward is `+InvViewMatrix` column 3.
- Ray hits can't name an entity from Lua.
- Fire Bolt is `Projectile_FireBolt`.
- `Osi.UseSpellAtPosition` takes 6 args.
- Scripted `Osi.PlayAnimation` roots the walk and stalls in turn-based combat. BG3's own genome events don't.

### Done (verified in-game)

Movement and camera:
- [x] Walk by default, Left Shift toggles run. *(2026-10-09: "walking and running feel great")*
- [x] Real jump: body and camera move together, base height 0.8 m, gentle touchdown, wall and ceiling collision, ascend + descend clips, momentum kept while walking or running. *(2026-10-10: "chef's kiss")*

Melee:
- [x] Single-click 3-swing chain with the developer's clip picks (RHand, LHand, RHand). *(2026-10-09, unarmed only)*
- [x] Interim hit check: camera-relative swing arc (cone + line of sight), torso / limb zones, server-validated damage. *(2026-10-08)*
- [x] Hit reactions (BG3's own, triggered by our server-side damage). *(2026-10-08)*

Spells:
- [x] Hotbar on keys 1–0: arm, LMB casts, RMB or the same key cancels. *(2026-10-08)*
- [x] Mana pool, regeneration and costs (server-owned). *(2026-10-08)*
- [x] Fire Bolt, Fireball and Misty Step at the crosshair. *(2026-10-08)*
- [x] Channelled casting: 2 s cast time (server-checked), held as long as wanted. Straight-line aim (first cylinder on the line, else the world, else 100 m out), no max range for shooting spells, momentum kept when arming in the air. *(2026-10-10: "spells feel great, aim feels perfect")*
- [x] Spell channel animations through BG3's own select / cancel events, with no rooting: each spell's prepare (stretched to the cast time), then the loop at READY, then cast, then recover. *(2026-10-10)*
- [x] Class casting animations from the caster's top class (DECISIONS 2026-10-10), plus prepare VFX and sounds from the spell's stats. *(2026-10-10: "plays the correct animation, works while moving"; Fire Bolt, Fireball, Misty Step)*

Tooling:
- [x] Animation browser and gallery (`!dag_animlib`), per-character play rate (DLL). *(2026-10-09)*
- [x] Animation recorder (`!dag_anim_record`), genome event capture (`!dag_genome_events`), animation state snapshot (`!dag_anim_state`), spell variants gallery (`!dag_spell_variants <spell> gallery`). *(2026-10-10)*

### Road to Gate 1 (proposed order, 2026-10-12)

Each step is one or two play sessions. Tick a box only after it is verified in-game.

**Step 0: re-check sweep (one short session).** These items were written on 2026-10-09 and 10-10 and have been played over since, but were never signed off one by one. Do one pass on DEV-SAVE, then tick each item or reopen it as a bug.
- [ ] The first jump of a session works (fix `42ba492`). If the second jump still glitches, look at the Falling Update hook being installed on the first jump (`RJUMP: Falling Update hooked`).
- [ ] LMB spam (3 fast clicks) never leaves WASD dead, and `!dag_unstick` is never needed.
- [ ] Head-bone camera: the view stays glued to the body while attacking, with no body drifting ahead of the camera.
- [ ] Gale's face never flashes, including after a gear change.
- [ ] Cylinder hitboxes: swing reach is measured to the cylinder's surface, and a goblin's cylinder matches its body.
- [ ] Casting slows to x0.7 on the ground and returns to full speed at READY. The speed knob (`!dag_speed_mult`) works.
- [ ] Locomotion clips play at the gait's speed (no foot sliding).
- [ ] Swing or cast in the air: the action plays, the arc continues, and the landing waits for it.

**Step 1: real-time fights (critical path).** Nothing else can be judged against a real fight until this works.
- [ ] Wire the Brawl import: strip Swarm Mode and Leaderboard (one commit each), add `BrawlAdapter.lua`, and run the RealTime pulse so the DEV-SAVE gate fight never drops into turn-based.
- [ ] Goblins act on Brawl's AI as it is, with BG3 attack rolls through `Osi.UseSpell` (temporary, replaced in step 2).
- [ ] Our swings, spells, mana and jump keep working while the loop runs. Remove the "skip swing animations in turn-based" workaround.
- [ ] Dialogue and cutscenes pause the fight and resume it; the fight ends cleanly; companions don't break it. Companions are part of the fight via Brawl; their M3 behaviour comes later.

**Step 2: enemies use our combat rules.**
- [ ] AI melee goes through our swing scheduler and hit check, validated by the same server code as the player's swings (DECISIONS 2026-10-08).
- [ ] Getting hit: reaction, damage, and what a hit does to the player's channel (open question below).

**Step 3: melee feel.**
- [ ] A longsword actually equipped, with the chain picked from the equipped weapon's family. Needs exact-clip playback for picks that must be one specific clip (DECISIONS 2026-10-09).
- [ ] Melee wall stop (`wall = stop`, the default): the swing's damage window ends when its path hits world geometry; overhead swings and thrusts ignore side walls.
- [ ] Blood and spark effects at the hit point.
- [ ] At the gate, decide whether the interim swing arc is good enough, or whether the blade-path check (weapon bone reads, see Archived) is needed for Gate 1.

**Step 4: projectile system v1 for Fire Bolt and Fireball** ([design/projectiles.md](design/projectiles.md)). This step has the most engine unknowns, so it starts with a static Ghidra spike.
- [ ] Spike, part 1: steer BG3's own projectile entity from the DLL and remove it on our hit. Fallback: the spell's trail effect on an invisible mover.
- [ ] Spike, part 2: the instant, projectile-free "impact variant" of a spell. Can it be built at stats load from the original spell, or does it need shipped stats?
- [ ] Server-owned flight and swept-sphere hits against current cylinders, so moving goblins can be hit.
- [ ] The server's copy of a jumping player's height. The real jump is client-side, so today the server sees a jumping player standing on the ground (wrong for hits on or by jumpers).
- [ ] Fireball ground preview.

**Step 5: HUD stand-ins (ImGui, small, can slot in anywhere).** The full custom HUD is M4.
- [ ] Spell cast charge bar: fills over the cast time, shows READY when the loop starts, drains on cancel.
- [ ] Health and mana readable at a glance during the fight.
- [ ] Optional: a hotbar setup window. `!dag_hotbar <slot> <spell>` covers it until the M4 tab.

**Step 6: Gate 1.**
- [ ] The Emerald Grove gate fight is playable start to finish in DEV-SAVE.
- [ ] **Gate 1: combat feels tight.** Playtest notes written; go / no-go recorded in `DECISIONS.md`.

### Open questions for the road ahead

- **Getting hit while channelling.** DESIGN says a melee hit interrupts a cast of level 1+ and refunds half the mana. With 2 s channels, should a hit cancel the channel, reset its timer, or do nothing?
- **Blocking and parry.** Proposed: move to M2 with the defence animations (they reuse the wall-stop path), not Gate 1.
- **DESIGN.md has drifted** from the logged decisions:
  - cast time;
  - range;
  - Q vs RMB to cancel;
  - wall bounce vs stop;
  - the projectile model;
  - the HUD;
  - the native plugin's role.

  Proposed: one sync pass of DESIGN.md and its live artifact.

### Known issues (open)

- Turn-based combat takes over when enemies turn hostile (step 1). Until then, swing animations are skipped in turn-based combat, and the camera can dip under the map while casting there.
- Ending the prepare loop sound stops **all** of the caster's sounds at that moment (`Ext.Audio.Stop`).
- Prepare VFX, casting animations and the real jump are local only; other players see none of it yet (M6).
- Forcing the casting set rewrites `AnimationSet.Entries`, which drops the engine's hidden per-entry tag pointers until a reload. No visible effect seen so far.
- Bards and Sorcerers have no class casting set, so they use the default sets' first variant (a Bard gets the violin one).
- Head-zone hits come from the cylinder's height fraction, not bones.
- Rare frames of Gale's head showing while walking (re-check in step 0).

### History (superseded, kept for the trail)

- **Visual-only floaty jump (2026-10-09) → real jump (2026-10-10).** The engine rewrites the mesh render objects every frame, so a visual lift detached the body from the camera at height ([m1b-visual-lift.md](spikes/m1b-visual-lift.md), [real-lift.md](spikes/real-lift.md)).
- **Spell prepare via `Osi.PlayAnimation` (rooted the walk) → BG3's genome select / cancel events (2026-10-10).** Along the way, the prepare was briefly turned off, and the "draw the weapon on arm" theory was tried and dropped (vanilla doesn't draw the staff).
- **Aim-assist cone and ground / 18 m fallback → one straight line (2026-10-10).**
- **Auto-picked swing-1 clip was BG3's ranged attack (played nothing in melee stances) → the developer's picks (2026-10-09).**
- **Animation recorder, first run:** the node's animation input is a FixedString, which is now decoded through the global string table.
- **Not scheduled:** upper-body casting while walking (own blueprint with a masked layer, or an additive overlay). The full-body cast pose while walking is accepted (DECISIONS 2026-10-10).

## M2 — Combat breadth

- [ ] All 10 weapon families with their chains
- [ ] Blocking and parry with **custom animations**: block only with a shield, parry only with a parry-capable weapon (decided 2026-10-08). Reuses the melee "swing obstructed" path (DECISIONS 2026-10-10). Moved from M1b on 2026-10-12, pending the developer's OK.
- [ ] All spell types from the targeting table (projectile, area, cone, single target, teleport, wall, summon, self, reaction)
- [ ] Bows, crossbows and thrown weapons — draw / hold-forever / release, damage+speed by draw, reload for crossbows; arrows on the shared projectile system with a **DLL-driven arrow** that sticks into walls and targets ([design/projectiles.md](design/projectiles.md))
- [ ] **Bow draw charge bar** (separate style from the spell bar): draw %, a marker at the ~30% minimum shot, full-draw tick
- [ ] Projectile system v2: all projectile spells, instant rays, cone / area shape tests; Magic Missile stays homing
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
- [ ] First-person HUD: crosshair and reticles, health and mana, hotbar strip — **developer's design in [design/hud.md](design/hud.md)** (health orb, mana orb, 10 slots, potion slots, XP bar, cast / draw charge bars); vanilla HUD hidden in first person
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

## Backlog (much later, not scheduled)

Added 2026-10-09 (movement round).

- [ ] **Strafe / dash-strafe animations** (custom). The body may turn toward the movement as long as the camera isn't forced.
- [ ] **Defence animations:** block hold and parry (custom). Block only with a shield, parry only with a parry-capable weapon (decided 2026-10-08).
- [ ] **Movement speed from agility:** scale walk / run speed with the character's agility (DEX), through `Movement.AddModifier` (the knob is ready; no mechanic yet, developer 2026-10-09).
- [ ] **Weapon chain auto-guess:** propose each weapon family's chain from clip names (light 1–3, heavy, ranged draw / hold / release) and show it in the gallery for one-click accept.

## Archived (future)

Native plugin exports that would have gone into M1a but are not blocking M1b. Each line names what was learned and what the next session would start from.

- [ ] **Head-bone anchor for the camera.** *(Un-archived 2026-10-09: solved without bind pose via the skeleton's Granny world pose, see M1b checklist.)* M1a reaches the body `Pose` array through the MeshBinding addresses passed from Lua (`Pose1`/`Pose2`, 65 bones body, 83 head). The matrices are 3×4 model-space skinning matrices (`M = ModelSpaceCurrent × inverse(ModelSpaceBind)`), not bone positions — need the bind-pose model-space positions **and** the skeleton→binding bone index map before a bone position falls out as `worldPos = ObjectTransform × (M × bindPos)`. For M1b the engine-anchor camera is tight enough; head bob and leaning are polish, not blockers.
- [ ] **`GetBoneWorldPos(entity, boneName) → vec3`.** Same groundwork as the head-bone anchor. M1b's hit detection switches to a timed camera-relative swing arc (ray fan from the eye through the arc) which doesn't need a bone position, so this is unblocked but no longer on the critical path.
- [ ] **`SetAnimPlaySpeed(entity, mult)` and `CancelAnim(entity)`.** No SE Lua exposure of the field, Granny internals not RE'd. Hit stop and chain-timing finesse are deferred (M1b uses fixed timings).
- [ ] **`PushRagdoll(entity, vec3, force)`.** Directional death animations keyed on hit direction (M1b) cover the feel without a physics impulse.
