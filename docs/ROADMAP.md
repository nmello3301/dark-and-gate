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

What doesn't: as soon as the goblins turn hostile, BG3's turn-based combat takes over. The Brawl import (`Server/Brawl/`) is still quarantined (nothing requires it), so every test so far has been against idle goblins or spawned dummies. Real-time fights (Pass B) come right after the HUD + projectiles pass (developer, 2026-10-12).

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

### Road to Gate 1 (order set by the developer, 2026-10-12)

Each pass is one or two play sessions. Tick a box only after it is verified in-game.

**Pass A: in-game HUD + projectile system v1** (current; playtest [playtest/hud-projectiles.md](playtest/hud-projectiles.md)).

HUD, using the developer's art ([design/hud.md](design/hud.md)):
- [ ] The engine is chosen and the vanilla HUD hide / restore lever is found ([spikes/hud-tech.md](spikes/hud-tech.md)). *Study done 2026-10-12: SE ImGui images from our own atlas texture (`DAG_HUD_Atlas`, texture bank in the pak); BG3's widgets collapsed via Noesis `Visibility`. Awaiting playtest.*
- [x] Art sliced into layers (`tools/hud/slice.py`), and the preview sheet approved by the developer. *(2026-10-12: "mostly good"; asked for numbers under the orbs, key numbers on the hotbar, R / T potions)*
- [ ] Live HUD in first person:
  - health orb and mana orb;
  - a 10-slot hotbar with the spell icons, the armed glow and a mana-too-low tint;
  - health potion [Q] and mana potion [R];
  - the XP bar;
  - the crosshair kept.

  The vanilla HUD is hidden in POV and restored outside it, and in dialogue, menus and cutscenes. Commands: `!dag_hud on|off|vanilla`.
- [ ] Spell cast bar (blue): fills over the cast time, shows READY when the loop starts, drains on cancel.
- [ ] Bow draw bar (an amber arc around the crosshair): draw %, a 30 % marker and a full-draw tick (wired to the bows when they land).
- [ ] **Bows (2026-10-12, built, not verified):** Q swaps melee / ranged; hold LMB = 3 s draw with BG3's draw clip stretched (`Client/Combat/Bow.lua`), release = arrow with drop through the projectile system (`Server/Combat/Bows.lua`, `data/bows.lua`); no shot below 30 %, damage and speed by draw; RMB cancels; 60 % speed while drawing; the ring fills. Crossbows: click + reload.
- [ ] **NPC archers draw too** (3 s, the clip stretched on every client through the DLL's new multi-character clip rates `nclips`), facing the target, aiming at the release for lead + drop + error (`Server/Combat/NpcCombat.lua`).
- [ ] **Test kit:** `!dag_chest` (every weapon type + shield + special arrows), `!dag_goblins [kind [n]...] [idle] | clear | list` (default scimitar, greataxe, archer, caster), `!dag_god [on|off|party|status]` (`Server/Combat/TestKit.lua`, `data/testkit.lua`).
- [ ] **Prepare Hotbar menu** (our own; DECISIONS 2026-10-12): opens beside BG3's I / Tab panels in first person, H pins it; bind any of the character's spells to 1..0, saved per character; the server checks the caster has the spell.
- [ ] BG3 panels usable in first person: Tab (party view) and I (inventory) open their panels; the cursor is free while a panel is open; BG3's HUD comes back with it.

Projectiles, for spells ([design/projectiles.md](design/projectiles.md), [spikes/projectiles.md](spikes/projectiles.md)):
- [x] Study: how BG3 projectiles move, how to steer and remove them, and how to build the impact-only spell variant. *(static, 2026-10-12: [spikes/projectiles.md](spikes/projectiles.md); in-game probes in the playtest)*
- [ ] Server-owned flight (`data/projectiles.lua`) and swept-sphere hits against current cylinders. Moving targets can be hit.
- [ ] The server knows a jumping player's height, for hit checks and the spawn origin.
- [ ] The game's own Fire Bolt / Fireball visual follows our path and is removed at our hit.
- [ ] The impact variant applies BG3's damage, saves, statuses and VFX (Fireball's area at the point). The original projectile never deals damage.
- [ ] `!dag_spawn_dummy moving`: a dummy walking back and forth over about 6 m.
- [ ] Fireball ground preview (if time allows).

**Status 2026-10-12, round 1:** the vanilla HUD hid; our HUD did not draw (its texture bank wasn't loaded); Tab stopped working; projectiles "worked" on the moving goblin, but the hits were BG3's own projectile (the visual clone still dealt damage, our flight started 1.2 s late and the server's world ray errored). **Round 2** fixes all four and adds the Prepare Hotbar menu ([playtest/hud-projectiles.md](playtest/hud-projectiles.md)). In round 2 our HUD drew, but the camera no longer turned and the cursor was invisible in menus. Cause: the HUD's full-screen ImGui window took the mouse, because SE has no `win.Flags` field and its `NoInputs` flag was never set; SE then drops every mouse event (se-api-notes). **Round 3** sets the flags field by field and re-runs round 2's tests. Not built yet: the Fireball ground preview, the DLL steering of BG3's projectile (only if the Lua probe shows it is needed), and a mana potion item.

Then, only if the spell projectiles pass their test, arrows and throwables:
- bows: draw, hold forever, release;
- crossbows: reload;
- throwables;
- arrows that stick in walls and targets.

Checklist folded in from the old step 0. These items were written on 2026-10-09 and 10-10 and played over since, but never signed off one by one; they are ticked during the Pass A playtest:
- [ ] The first jump of a session works (fix `42ba492`). If the second jump still glitches, look at the Falling Update hook being installed on the first jump (`RJUMP: Falling Update hooked`).
- [ ] LMB spam (3 fast clicks) never leaves WASD dead, and `!dag_unstick` is never needed.
- [ ] Head-bone camera: the view stays glued to the body while attacking.
- [ ] Gale's face never flashes, including after a gear change.
- [ ] Cylinder hitboxes: swing reach is measured to the cylinder's surface, and a goblin's cylinder matches its body.
- [ ] Casting slows to x0.7 on the ground and returns to full speed at READY.
- [ ] Locomotion clips play at the gait's speed (no foot sliding).
- [ ] Swing or cast in the air: the action plays, the arc continues, and the landing waits for it.

**Pass B: real-time fights (Brawl wiring), right after Pass A.**
- [ ] Wire the Brawl import: strip Swarm Mode and Leaderboard (one commit each), add `BrawlAdapter.lua`, and run the RealTime pulse so the DEV-SAVE gate fight never drops into turn-based.
- [ ] Goblins act on Brawl's AI as it is, with BG3 attack rolls through `Osi.UseSpell` (temporary, replaced in Pass C).
- [ ] Our swings, spells, mana and jump keep working while the loop runs. Remove the "skip swing animations in turn-based" workaround.
- [ ] Dialogue and cutscenes pause the fight and resume it, and the fight ends cleanly. Companions take part through Brawl; their M3 behaviour comes later.

**Real-time combat pass (task of 2026-10-12, Parts 1-11).** Built 2026-10-12 (`cb90cdf`..`df5a8a8`), none of it verified in-game yet. Playtest: [playtest/realtime-combat.md](playtest/realtime-combat.md), one pass, 13 steps.
- [ ] Part 1: Brawl's loop drives every fight: hostile groups never drop into turn-based, vanilla combat groups join together, `!dag_rt off` gives BG3's turn-based back (debugging only; also typed in the client console).
- [ ] Part 1: 1 turn = 6 s, logged the first time each timed status lands in a fight (`RT: status BLESS on Gale: 10 turns -> 60 s`).
- [ ] Part 1: reactions and Sneak Attack are off in real-time fights: the hidden status `DAG_NO_REACTIONS` (`ActionResourceBlock(ReactionActionPoint)` + `ActionResourceBlock(SneakAttack_Charge)`) on every fighter, removed when it leaves combat or on `!dag_rt off` (`Server/Combat/NoReactions.lua`).
- [ ] Part 2: AI on our rules (`Server/Combat/NpcCombat.lua`). Melee goes through our server swing (the longsword data: committed direction, arc, reach, wall stop, shield; weapon dice on our damage path). Ranged goes through our projectiles, with reaction delay, aim error and a misjudged lead (`data/ai.lua`). Casters wait our cast time; area spells commit their point at cast start.
- [ ] Part 2: the player takes hits with no hit reaction (`Server/Combat/Damage.lua`, direct Health write; the lethal hit uses `Osi.ApplyDamage`); enemies keep theirs.
- [ ] Part 3: passive shields, 40 % off hits that land on the disc (all hit paths).
- [ ] Part 4: downed: bleed-out 3 min (our self-stabilising downed status), orbit camera (DLL) with spectate, hold-F revive (3 s, 1.5 m, 1 HP), companions revive first, banner + timer + bar.
- [ ] Part 5: C = crouch = BG3 sneaking (x0.6 speed, the eye follows the head, cones hidden), our stealth checks (d20 + Stealth vs passive Perception, one per NPC per 6 s), uncrouched in a cone = detected.
- [ ] Part 6: knobs `!dag_ai_aim`, `!dag_ai_react`, `!dag_bleedout`, `!dag_revive_time`, `!dag_shield_pct`, `!dag_crouch_speed`, `!dag_stealth_debug`; per-tick watchdog (`!dag_watchdog`).
- [ ] Part 7: `Client/LookAt.lua`: what the crosshair is on (world point, character, interactive object), server classification ([spikes/lookat.md](spikes/lookat.md)).
- [ ] Part 8: F interacts like a click (talk, loot, doors, levers, pickup, climb); BG3 panels pause our input.
- [ ] Part 9: V cycles Follow / Wait / Go to camp, with a toast.
- [ ] Part 10: M opens BG3's map, fast travel works, first person comes back cleanly (level_seq reset, settle after loads / teleports).
- [ ] Part 11: targeted spells (LMB picks, auto-fire at max when READY, key again = early, RMB cancels), area indicators (BG3's ring at the crosshair; walls / cones as rows of rings).

Built on assumptions the playtest has to confirm (each logs which way it went):
- `hit.Shape.PhysicsObject.Entity` names entities (else the nearby scan is used).
- `GetEntitiesAroundPosition` works on the client (else a sliced item scan).
- Our MultiEffectInfos load and `FXScale` scales the ring (else the vanilla 4 m ring).
- `Darkness.SneakingConesVisibility` is writable.
- NPC visual clones animate through the cast request queue.
- `Osi.Use` opens containers like a click.
- The camp procs work on one companion.
- `Shield.Forward`'s sign is right (checked against walking, flips itself).
- `Stats.Skills[7]` is Stealth.

Known gaps (not bugs yet, rework later):
- Weapon actions picked by Brawl (Topple, Piercing Shot...) deal plain weapon damage; their extra effects are lost.
- Throws stay vanilla.
- NPCs show no cast bar while casting.
- Area-spell explosions hit the player with a hit reaction unless a player-controlled character is inside the clone's `area_m` (then none for everyone in it).
- Instant-kill effects can still kill a downed player.
- Direct-HP damage skips concentration checks and on-damage passives.

Rework notes, one per disabled rule (full table in [rework-list.md](rework-list.md)):
- [ ] Opportunity attacks: real-time melee has no "leaving reach" moment. Could return as a free swing when an enemy turns its back inside your reach.
- [ ] Riposte: fits the M2 parry window.
- [ ] Shield (spell): first to return, as a short timed window after a hit lands (key + mana), like an active block.
- [ ] Counterspell: first to return, once enemy cast bars exist (M4): a key during the enemy's cast time.
- [ ] Hellish Rebuke: automatic retaliation on being hit, with a cooldown?
- [ ] Other reaction interrupts (Uncanny Dodge, Deflect Missiles, Cutting Words, Sentinel, Mage Slayer, Warding Flare…): one by one, automatic with a cooldown or a key in a short window.
- [ ] Sneak Attack: hits from behind or on targets that don't see you (stealth detection), once per 6 s.
- [ ] Interrupts that cost no reaction (Divine Smite prompts, Lucky, Portent, Bardic Inspiration…) are not blocked by the status. Our hits never trigger on-hit interrupts; revisit if a prompt shows up in a real-time fight.

**Pass C: enemies use our combat rules.**
- [ ] AI melee goes through our swing scheduler and hit check, validated by the same server code as the player's swings (DECISIONS 2026-10-08). Goblin archers' shots go on the projectile system.
- [ ] Getting hit: reaction and damage. A hit does **not** interrupt the player's channel (DECISIONS 2026-10-12).

**Pass D: melee feel.**
- [ ] A longsword actually equipped, with the chain picked from the equipped weapon's family. Needs exact-clip playback for picks that must be one specific clip (DECISIONS 2026-10-09).
- [ ] Melee wall stop (`wall = stop`, the default): the swing's damage window ends when its path hits world geometry; overhead swings and thrusts ignore side walls.
- [ ] Blood and spark effects at the hit point.
- [ ] At the gate, decide whether the interim swing arc is good enough, or whether the blade-path check (weapon bone reads, see Archived) is needed for Gate 1.

**Gate 1.**
- [ ] The Emerald Grove gate fight is playable start to finish in DEV-SAVE.
- [ ] **Gate 1: combat feels tight.** Playtest notes written; go / no-go recorded in `DECISIONS.md`.

### Session 2026-10-12 (evening): real-time fight fixes

Verified in-game:
- [x] Test kit: `!dag_chest` (one of every weapon + arrows), `!dag_goblins` (melee, brute, archer, caster), `!dag_god`.
- [x] Bows and crossbows: 3 s draw with the bow raised and pulled during the charge, release on LMB up; crossbow R reload; Q swaps melee / ranged; goblin archers draw the same way.
- [x] Chest loot window frees the cursor (F); potions on T / Y.
- [x] WASD moves you in real-time fights at exploration speed (the DLL skips BG3's "no WASD in a combat" check); goblins run, not sprint.
- [x] Enemy AI acts every ~2.5 s (was 6 s).
- [x] Casting in a fight no longer moves the camera: Ray of Frost, Fireball, Thunderwave, Fog Cloud, Grease (CamGuard drops BG3's Projectile / Spell camera requests, the DLL holds first person on any foreign camera, visual clones aim 2 m past the aim point).

Built, not verified yet:
- [ ] A fight ends when no enemy has been within 30 m for 4 s (combat music stops); `!dag_goblins` moves goblins with no path to you next to you.
- [ ] Misty Step: one first-person settle instead of a burst of ~200.
- [ ] No more `TurnOrder.lua:255 ... TurnOrderComponent::Groups` errors in the SE console.
- [ ] Surfaces don't touch you mid-jump (`AirSurfaces:` lines; add any surface status logged as "kept").

Next (developer's list, 2026-10-12):
1. **Spell indicators:** better targeting indicators for spells in general (next session's main task).
2. Verify the four items above.
3. While BG3 holds a foreign camera, mouse-look freezes on your last direction (now rare); write the stored rotation back if it shows up.
4. The server WASD fallback (`Client/Movement/CombatMove.lua`) hasn't been needed; keep it a few sessions, then decide. It maps speed modifiers to Walk / Run only.
5. Bow draw time scaled by a stat (`Server/Combat/Bows.lua` DrawTime is the hook).
6. Visual clones stop at 40 m: on a long sky shot BG3's visible projectile ends there; consider a longer cap for arrows.
7. native.log noise: Camera.cpp's legacy per-frame "Camera: cam=… NO MATCH" probe lines.
8. `docs/se-api-notes.md` (SE v33): TurnOrder groups field name, removing `CombatTargetRequests.Requests` entries with `[i] = nil`, the camera GlobalSwitches don't stop BG3's in-fight spell camera.

### Open questions

- **Crouch** (C toggles it, and you can walk crouched; to build later): should crouching also be BG3 sneaking (stealth), or only the pose and speed? This is for the developer to decide before it's built.
- Settled on 2026-10-12: a hit doesn't interrupt a channel, blocking and parry move to M2, and DESIGN.md gets one sync pass at the end of Pass A.

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
- [ ] **Crouch** (developer, 2026-10-12): C toggles crouch, and you can walk crouched. Open question before building: BG3 sneaking (stealth) too, or only the pose and speed?
- [ ] **Movement speed from agility:** scale walk / run speed with the character's agility (DEX), through `Movement.AddModifier` (the knob is ready; no mechanic yet, developer 2026-10-09).
- [ ] **Weapon chain auto-guess:** propose each weapon family's chain from clip names (light 1–3, heavy, ranged draw / hold / release) and show it in the gallery for one-click accept.

## Archived (future)

Native plugin exports that would have gone into M1a but are not blocking M1b. Each line names what was learned and what the next session would start from.

- [ ] **Head-bone anchor for the camera.** *(Un-archived 2026-10-09: solved without bind pose via the skeleton's Granny world pose, see M1b checklist.)* M1a reaches the body `Pose` array through the MeshBinding addresses passed from Lua (`Pose1`/`Pose2`, 65 bones body, 83 head). The matrices are 3×4 model-space skinning matrices (`M = ModelSpaceCurrent × inverse(ModelSpaceBind)`), not bone positions — need the bind-pose model-space positions **and** the skeleton→binding bone index map before a bone position falls out as `worldPos = ObjectTransform × (M × bindPos)`. For M1b the engine-anchor camera is tight enough; head bob and leaning are polish, not blockers.
- [ ] **`GetBoneWorldPos(entity, boneName) → vec3`.** Same groundwork as the head-bone anchor. M1b's hit detection switches to a timed camera-relative swing arc (ray fan from the eye through the arc) which doesn't need a bone position, so this is unblocked but no longer on the critical path.
- [ ] **`SetAnimPlaySpeed(entity, mult)` and `CancelAnim(entity)`.** No SE Lua exposure of the field, Granny internals not RE'd. Hit stop and chain-timing finesse are deferred (M1b uses fixed timings).
- [ ] **`PushRagdoll(entity, vec3, force)`.** Directional death animations keyed on hit direction (M1b) cover the feel without a physics impulse.
