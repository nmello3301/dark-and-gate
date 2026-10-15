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
| **MP Multiplayer (pulled forward)** | Co-op that feels like single-player for every player; up to 8 players / 16 party members with Party Limit Begone. MP-0 to MP-4 ([design/multiplayer.md](design/multiplayer.md)); Gate 1 / Pass D follow after MP-2 | | 2026-10-13 | |
| Release 0.1.0 alpha | First public build on Nexus Mods; repo public (DECISIONS 2026-10-15) | | 2026-10-15 | |
| **Gate 1** | **Combat feels tight** | | | |
| M2 Combat breadth | All 10 weapon families, all spell types, blocking, ranged, first MP smoke test (spike 9 answer) | 6–10 weeks | | |
| M3 Companion AI | Follow / Wait / Camp; archetypes on top of the Brawl adapter | 2–4 weeks | | |
| M4 Native UI | Prepare Hotbar tab (spike 8 answer), first-person HUD, traversal highlights | 3–6 weeks | | |
| M5 Act 1 pass | Encounter overrides, balance, saves, through Act 1 | 4–8 weeks | | |
| M6 Multiplayer | ~~2–4 player co-op~~ Moved up as **MP** (DECISIONS 2026-10-13); what is left here is the Gate 2 co-op pass | 4–8 weeks | | |
| **Gate 2** | **Act 1 in 2-player co-op** | | | |
| M7 Acts 2–3 | Campaign pass, public release | 2–4 months | | |

**2026-10-13: multiplayer moved up** (DECISIONS): it touches every system, so it's cheaper to build now than retrofit later. Gate 1 / Pass D follow after MP-2. See the MP section below.

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
- **2026-10-12 (late):** real-time fights, bows, cast cameras and the test kit are in; the developer set the AI pace (4 s for everyone) and the spell ranges (70 m / 30 m). Next focus after this round: multiplayer, then game balancing.
- **2026-10-13 check-in:** a movement-feel day. The direct WASD controller, the real jump's flicker and bunny-hop fixes are verified. The melee cooldown and the body following the camera are built. M1b's remaining time is mostly playtest sign-off of the 2026-10-12 real-time pass, then Pass D (melee feel) and the Gate 1 fight. See the M1b status.

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

### Status (2026-10-13): fights run in real time; the backlog is sign-off, then melee feel

Fights no longer drop into turn-based. Brawl's loop drives every hostile group, and goblins act on our rules at their own pace. The player side has gone through several feel rounds. Most of what's left before Gate 1 is built but not yet signed off in a playtest, plus the melee feel pass (Pass D).

**Verified in-game:**
- **Movement:**
  - the direct WASD controller: full speed and a stop almost at once, the body facing the way you move;
  - walk / run;
  - the real jump: no take-off flicker, hops right after a landing, the bunny-hop grace, no recover after landing ("Works great!").
- **Melee:** the 3-swing chain, the interim arc hit check, server-validated damage, BG3's hit reactions.
- **Spells:**
  - the hotbar on 1–0 and the mana pool;
  - channelled casting with the class casting animations;
  - Fire Bolt, Fireball and Misty Step at the crosshair;
  - casting in a fight no longer moves the camera.
- **Fights** (2026-10-12 evening):
  - real time;
  - WASD at exploration speed;
  - bows and crossbows, goblin archers drawing too;
  - the test kit (`!dag_chest`, `!dag_goblins`, `!dag_god`).
- **Campaign:**
  - F interaction fixes on the nautiloid: the vine climbs once, "[F]" only where BG3 allows a use, Myrnath talks;
  - our HUD standing aside in the nautiloid's dialogues and cutscenes.

**Built, waiting on a playtest** (the biggest block of work; each has its own playtest doc):
- The real-time combat pass, Parts 1–11 ([playtest/realtime-combat.md](playtest/realtime-combat.md)):
  - AI on our rules;
  - shields, downed / revive, crouch-stealth;
  - LookAt and F, V companions, the map;
  - targeted and area spells.
- Pass A leftovers: the live HUD and cast bar, server-owned projectiles (round 3), the Prepare Hotbar menu, the old step-0 checklist.
- Later fixes:
  - fight end;
  - pace by difficulty;
  - companions that stood idle;
  - downed control, the game over and Give up;
  - the head showing outside first person;
  - `!dag_play`, `!dag_hp`;
  - hardening in character creation.
- From 2026-10-13:
  - **the 1.5 s melee cooldown** (never swung in a session yet);
  - **the body follows the camera** (the log looks right; feel not confirmed);
  - the direct controller's metrics, sync and locomotion-clip checks;
  - jumps going their full arc.

**Not built yet, needed for Gate 1:**
- Pass D, melee feel:
  - the chain picked from the equipped weapon's family;
  - swings stopping at walls;
  - blood and spark at the hit point;
  - the call on the interim arc vs the blade-path check.
- Then the full Emerald Grove gate fight in DEV-SAVE, and the go / no-go.

**Known limits:**
- Standing on rocks was dropped (DESIGN, Campaign compatibility).
- Enemies don't use height yet ("enemies and high ground", later).
- The real jump, prepare VFX and casting animations are local only until M6.

**After Gate 1's round** (developer, 2026-10-12): multiplayer, then game balancing.

Lessons recorded:
- `Ext.Require` only works at load time.
- `hit.Distance` is a 0–1 fraction of the ray.
- BG3's view forward is `+InvViewMatrix` column 3.
- Ray hits can't name an entity from Lua.
- Fire Bolt is `Projectile_FireBolt`.
- `Osi.UseSpellAtPosition` takes 6 args.
- Scripted `Osi.PlayAnimation` roots the walk and stalls in turn-based combat. BG3's own genome events don't.
- A character's visible front is its Transform's local −Z (2026-10-13, body facing).
- BG3's landing animation holds the fall state after a landing (`MSFalling +0x40`), which blocks WASD and the next jump ([spikes/real-lift.md](spikes/real-lift.md)).
- Turn the body through BG3's own steering (the look-at state), never by writing the rotation: the steering keeps its own yaw and fights direct writes ([spikes/move-feel.md](spikes/move-feel.md)).

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
- [x] **Bows** (verified 2026-10-12 evening, signed off by the developer 2026-10-13): Q swaps melee / ranged; hold LMB = 3 s draw with BG3's draw clip stretched (`Client/Combat/Bow.lua`), release = arrow with drop through the projectile system (`Server/Combat/Bows.lua`, `data/bows.lua`); no shot below 30 %, damage and speed by draw; RMB cancels; 60 % speed while drawing; the ring fills. Crossbows: click + reload.
- [x] **NPC archers draw too** (verified 2026-10-12 evening, signed off by the developer 2026-10-13) (3 s, the clip stretched on every client through the DLL's new multi-character clip rates `nclips`), facing the target, aiming at the release for lead + drop + error (`Server/Combat/NpcCombat.lua`).
- [x] **Test kit** (verified 2026-10-12 evening, signed off by the developer 2026-10-13): `!dag_chest` (every weapon type + shield + special arrows), `!dag_goblins [kind [n]...] [idle] | clear | list` (default scimitar, greataxe, archer, caster), `!dag_god [on|off|party|status]` (`Server/Combat/TestKit.lua`, `data/testkit.lua`).
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
- [x] Wire the Brawl import: strip Swarm Mode and Leaderboard (one commit each), add `BrawlAdapter.lua`, and run the RealTime pulse so the DEV-SAVE gate fight never drops into turn-based. *(fights run in real time: verified 2026-10-12 evening, signed off by the developer 2026-10-13)*
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
- [ ] **Melee cooldown** (developer 2026-10-13, built, not verified; DECISIONS): one swing per 1.5 s, swing start to swing start; a click in the last 0.3 s is kept; the chain still advances; the server rejects hits from swings that came too soon. Scaling options for later (weapon family, chain step, stats, Extra Attack, buffs, feats) in DESIGN "Melee cooldown". Knob: `!dag_melee_cooldown <s>`.
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
- [x] Enemy AI acts every ~2.5 s (was 6 s). Superseded the same evening: a 4 s pace for everyone (below).
- [x] Casting in a fight no longer moves the camera: Ray of Frost, Fireball, Thunderwave, Fog Cloud, Grease (CamGuard drops BG3's Projectile / Spell camera requests, the DLL holds first person on any foreign camera, visual clones aim 2 m past the aim point).

Built, not verified yet:
- [ ] A fight ends when no enemy has been within 30 m for 4 s (combat music stops); `!dag_goblins` moves goblins with no path to you next to you.
- [ ] Misty Step: one first-person settle instead of a burst of ~200.
- [ ] No more `TurnOrder.lua:255 ... TurnOrderComponent::Groups` errors in the SE console.
- [ ] Surfaces don't touch you mid-jump (`AirSurfaces:` lines; add any surface status logged as "kept").

Built late on 2026-10-12, not verified yet (developer's settings; playtest steps 29–35):
- [ ] **Pace 4 s** for every AI fighter, enemies, companions and NPC allies (about 3.7–4.4 s by initiative); an archer's 3 s draw or a cast no longer costs it a whole extra pace.
- [ ] **Companions and allies fight:** Shadowheart never acted in the last `!dag_goblins` fight. Now one that Brawl finds nothing for attacks the nearest enemy with its weapon; `AI: … did nothing this pulse: <why>` and `AI: … has had no AI pulse …` lines say why one stands idle; `AI: fight roster: …` lists sides and paces.
- [ ] **Ranges:** 70 m for shots and arrows (aim, flight, BG3's visible projectile), 30 m for area and multi-target spells (Sleep, Bless, Grease, Fireball: aimed farther, the spell lands on the ring 30 m out). NPCs keep BG3's ranges for how close they walk.
- [ ] **`!dag_play`** (2026-10-13): the whole mod on with one command, remembered; first person by itself after loads and after character creation; your own spells on a fresh hotbar. Developer's run: a sorcerer from game start to the end of the Emerald Grove fight ([playtest/sorcerer-run.md](playtest/sorcerer-run.md)).
- [ ] **`!dag_hp 50 [party]`** (2026-10-13): +50 % max HP (BG3's `IncreaseMaxHP(50%)` on a hidden status), for your character or the whole party, kept for every save.

**Hide our HUD during cutscenes (developer, 2026-10-13)** — verified on the nautiloid 2026-10-13: all 8 of its dialogues / cutscenes were reported (`Scene:` lines) and played through, Myrnath's included. The grove's are still to see. Our first-person HUD (health / mana orbs, hotbar, crosshair, prompts, toasts) stayed on screen over the nautiloid's opening scene and **blocked clicking the dialogue**: the client's component check (Dialog / Cinematic / Cutscene) didn't see that scene. Built the same night, not verified: the server reports BG3's DialogStarted / DialogEnded to every client (`Server/Scene.lua`, `!dag_scene [off]`), and while one runs our HUD, input and first person stand aside. Check every cutscene / dialogue on the way to the grove; anything of ours still on screen during one is the follow-up (toasts, the overlay).

F interaction fixes (2026-10-13, sorcerer run on the nautiloid; verified the same day, second nautiloid run: the developer's "Myrnath now works fine. Most interactions do too", and the log):
- [x] **The vine (a ladder) no longer climbs up and down forever.** (Both vines: one F, one climb, the task ended; no "AGAIN on its own".) One F on the "Arterial Mesh" climbed it every 2.3–2.8 s for two minutes. BG3's Osiris use task (`Osi.Use`) doesn't count a player-style use as done and runs it again (Ghidra: `OsirisUseItemTask::Update`, [spikes/lookat.md](spikes/lookat.md)); the same bug pulled the Neural Apparatus lever twice. The task is now ended at the first `UseFinished` of what F used.
- [x] **"[F]" only on what BG3 itself lets you use.** (Brain Jar and the rubble helper: none; chairs "Sit on"; the lever once per press.) Brain jars (the ones named "Mind Sanctuary" too) and an invisible helper on the rubble showed "[F] Use", and every use failed. Items now need one of BG3's world use actions (`data/interact.lua` `use_actions`); chairs say "Sit on". A decoration in front of something usable no longer hides it.
- [x] **The brain (Myrnath, the man with the exposed brain in the lab) can be talked to.** His dialogue is a 3-speaker story entry that our talk check missed; talk now follows BG3's own "has dialog" flag (`GetHasOsirisDialog`).

Downed, pace and head fixes (2026-10-13, second nautiloid run: the helm fight; built, not verified):
- [ ] **You keep control of your own body when you go down.** BG3 handed control to Lae'zel the moment Tav went down; as the "controlled" character she got no AI, stood still and went down 15 s later. It is handed back now (`MakePlayerActive`, then the portrait re-select), so she keeps fighting.
- [ ] **The game over waits for the bleed-out.** BG3's story ends the game once every party member is "defeated", and downed counts, so the second downing ended the game 15 s into Tav's 3-minute bleed-out. While someone is downed, "Downed" is in the story's own list of defeats that don't end the game; the story's check runs after each bleed-out death (the game over comes when nobody is left).
- [ ] **Nobody attacks a downed character.** The imps kept shooting Tav's body for 3 minutes and Zhalk swung and cleaved at it. Brawl's target picks skip downed characters now, and a cast already aimed at one is dropped.
- [ ] **Your head shows whenever the camera is out of your eyes:** the downed camera, dialogues and cutscenes, first person off. The restore looked at whoever had control (Lae'zel by then), so Tav stayed headless.
- [ ] **Give up** on the downed screen when nobody in the party stands: a button (the cursor frees itself) or G, twice; BG3's game-over screen at once (every player has to give up in co-op). `!dag_downme all` downs the whole party to test it.
- [ ] **The enemies' pace follows the difficulty:** Explorer 10 s, Balanced 6 s, Tactician 5 s, Honour 4 s per action; companions and allies stay at 4 s (`!dag_enemy_pace <s>|auto`).

Direct WASD controller (2026-10-13, DECISIONS 2026-10-13: "Replace BG3WASD's movement with our own direct controller"; [spikes/move-feel.md](spikes/move-feel.md), playtest [playtest/move-feel.md](playtest/move-feel.md); built, not verified):
- [ ] **Metrics:** `!dag_move_metrics on|off` times start (90 % speed), stop (time + slide), reverse and strafe changes from the physical keys, logs every server correction (MOVEFEEL lines in native.log), and measures the client / server drift (MoveMetrics lines in client.log). The vanilla (BG3WASD) baseline goes in the spike note.
- [x] **Instant feel in first person** (verified 2026-10-13: "movement feels fluid", "engine is the clear winner"; signed off by the developer 2026-10-13): full speed within about 0.06 s, stopped within 0.04 s with no slide, W↔S and W→D at once, no turn-in-place pause; diagonals not faster. The direction is the physical W/A/S/D on our own camera (`move.input raw`); the body turns with BG3's own steering (`move.turn engine`; instant facing fought BG3's steering and flickered, playtests 1–2, DECISIONS 2026-10-13).
- [ ] **No flicker:** walking and running in any direction keeps the model, camera and shadow steady (playtest 2: steady with `engine`); no twitch at the jump take-off, and every jump goes its full arc (playtest 3: 11 of 53 running jumps were cut off mid-air; build 4 holds the ground controller still under a jump and logs `RJUMP interrupted`).
- [ ] **Everything else kept:** walls, slopes, stairs, doors, ledges and the real jump (take-off momentum, landing straight back into control); Shift walk / run, C crouch, casting ×0.7, bow draw, the speed knob; dialogue, menus, map, loot and downed release the input like before; Misty Step and other engine moves win.
- [ ] **Sync:** 0 server corrections in 60 s of walking, drift under 0.1 m; enemies, hits and stealth see you where you are.
- [ ] **Locomotion clips:** the Start / End*Foot / turn clips are found by name per character (`Client/Movement/LocoSkip.lua`) and fast-forwarded (×5) in direct mode, except during a jump and for the fall landings; the walk / run clips play at the speed's rate as before.
- Knobs: `!dag_move_mode vanilla|direct`, `!dag_move_accel <s>`, `!dag_move_decel <s>`, `!dag_move_turn engine|instant|<deg/s>`, `!dag_move_input raw|game` (defaults first; `data/movement.lua` move, MCM "move_direct" / accel / decel).
- **Standing on rocks: dropped** (DECISIONS 2026-10-13, known limitation in DESIGN "Campaign compatibility"). A foot box, step-up, hold-the-floor and knee-height walls were tried in builds 5–7 and removed: they made jumping worse. You walk at the height of BG3's walkable map ([spikes/ground-support.md](spikes/ground-support.md)).
- [x] **The take-off doesn't flicker** (verified 2026-10-13, playtest 6: "dag_jump_sync_guard worked perfect to remove the flicker"): the server changes your character flag 0x20 about 60 ms after take-off (most likely the jump clip's `Osi.PlayAnimation`), and the engine's reset for that stopped all movement and reset the character light; the DLL skips that reset during a jump (`!dag_jump_sync_guard on|off`, `RJUMP sync` lines).
- [ ] **Jumps go their full arc** (build 6: no `RJUMP exit` with the guard on; to confirm in play).
- [x] **No fake jumps / direction changes when hopping** (verified 2026-10-13, playtest 9: "Works great!"; playtest 7, build 8): a jump pressed during the last landing's phase (the fall state still on the machine) was refused ("RJUMP: already falling") and fell back to the old visual lift (you stayed on the ground and BG3's walk carried you on), every other jump. Now the real jump takes that fall state over; a jump pressed while really in the air is skipped, with no visual lift. Log of the build 8 session: 32 jumps, 8 take-overs (all fall state 2, 156–233 ms after the last jump's end), no refusal, no visual-lift jump; waiting on the developer's word on the direction change.
- [x] **Bunny-hop grace** (verified 2026-10-13, playtest 9; developer 2026-10-13, build 9, DECISIONS): Space up to 0.25 s before landing (or in the 0.15 s after) jumps the moment a jump is allowed; the DLL waits up to 0.25 s for a fall's landing instead of skipping. The build 8 log had one hop lost 90 ms before landing. Knobs: `!dag_jump_buffer <s>`, MCM "jump_buffer_s". Playtest 8 (build 9): the grace worked (6 buffered hops) but every hop still "caught".
- [x] **No recover after a jump** (verified 2026-10-13, playtest 9: "Works great!"; developer 2026-10-13, build 10, DECISIONS): the 0.15 s jump cooldown is gone; BG3's landing hold (its landing animation keeps the fall in the landed state, so WASD and the next hop waited 150–230 ms) is skipped after our jumps; a hop keeps the last jump's momentum (build 9 hops took off at 0 m/s). Knob: `!dag_jump_land_hold on|off`.
- [ ] **The body follows the camera** (developer 2026-10-13, builds 11-12, DECISIONS; build 11 faced 180° away: the body's front is the Transform's -Z): in the air the body turns with the camera; standing still it turns to the camera past 30°; moving, it faces the way you move. Through BG3's own look-at steering (`MoveFeel.cpp` `Facing`, spikes/move-feel.md). Knobs: `!dag_face_idle <deg>`, `!dag_face_air on|off`, MCM. Playtest 11 log (build 12): in the air the body trailed the camera by 0-58° (once 103°), idle turns 40° -> 4° in 267 ms and 90° -> 3° in 350 ms, nothing facing away; waiting on the developer's word on the feel.
- [ ] Later: **enemies and high ground.** Give the enemy AI the height difference to a player standing above them (ledges, stairs, the real jump's apex), so archers and casters shoot and cast instead of trying to reach them (developer, playtest 5).

Character creation crash (2026-10-13, sorcerer run): BG3 aborted in its own UI update (a pure virtual call) about 13 s into character creation, with nothing of ours running at that moment; the second try ran 5+ minutes there without a crash. Hardened (deployed 2026-10-13 with the scene fix, not verified): Brawl's HP rewrite is off at x1 (it rewrote every party member's Health, also the creation dummy's on each class / race change), Brawl's level start and `!dag_hp` skip character creation, and the hotbar stops reading the dummy's spells there.

Next (developer's list, 2026-10-12):
1. **Spell indicators:** better targeting indicators for spells in general (next session's main task).
2. Verify the four items above.
3. While BG3 holds a foreign camera, mouse-look freezes on your last direction (now rare); write the stored rotation back if it shows up.
4. The server WASD fallback (`Client/Movement/CombatMove.lua`) hasn't been needed; keep it a few sessions, then decide. It maps speed modifiers to Walk / Run only.
5. Bow draw time scaled by a stat (`Server/Combat/Bows.lua` DrawTime is the hook).
6. ~~Visual clones stop at 40 m~~ Settled: 70 m for shots and arrows, 30 m for area spells (above).
7. native.log noise: Camera.cpp's legacy per-frame "Camera: cam=… NO MATCH" probe lines.
8. `docs/se-api-notes.md` (SE v33): TurnOrder groups field name, removing `CombatTargetRequests.Requests` entries with `[i] = nil`, the camera GlobalSwitches don't stop BG3's in-fight spell camera.
9. If a companion still stands idle: its `did nothing` / `no AI pulse` lines name the cause (Brawl's target filter, its spells, a stopped pulse); fix that in Brawl's picks, not only the fallback. The `!dag_god` status (built on BG3's INVULNERABLE) was on in the fight where Shadowheart stood idle: check one fight without it.
10. **After this round (developer, 2026-10-12): multiplayer, then game balancing** (pace, ranges, damage, mana, AI aim).

### Open questions

- **Crouch** (C toggles it, and you can walk crouched; to build later): should crouching also be BG3 sneaking (stealth), or only the pose and speed? This is for the developer to decide before it's built.
- Settled on 2026-10-12: a hit doesn't interrupt a channel, blocking and parry move to M2, and DESIGN.md gets one sync pass at the end of Pass A.

### Known issues (open)

- Turn-based combat now only comes back with `!dag_rt off` (fights run in real time since the 2026-10-12 pass). In it, swing animations are skipped and the camera can dip under the map while casting.
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

## MP — Multiplayer (co-op), pulled forward 2026-10-13

"Multiplayer moved up: it touches every system, so it's cheaper to build now than retrofit later. Gate 1 / Pass D follow after MP-2." (developer, DECISIONS 2026-10-13)

**Goals:**
- co-op must feel like single-player for EVERY player, not just the host;
- it must work with Party Limit Begone (16 party members, 8 players, including its exe patch).

Principles P1-P5, the audit table, the net protocol and the test setup: [design/multiplayer.md](design/multiplayer.md). Each pass ends in `docs/playtest/mp-N.md`, every step done from the **joining** player's machine first, then as the host.

**MP-0: research + architecture** (no gameplay code yet, except the diagnostics) — started 2026-10-13.
- [ ] `docs/design/multiplayer.md`: how BG3 co-op works for us, PLB compatibility, the audit table, the net protocol, the version handshake, the test setup, the pass plan.
- [ ] PLB's exe patch checked against every DLL hook and pattern (no overlap, all still resolve).
- [ ] Diagnostics: `!dag_mp_status`, user-tagged logs, the version handshake, the DLL's exe detection (`exe: vanilla | patched (PLB)`) with the hook self-check.
  - Seen working in single player (2026-10-14): tagged logs (`[Client p1 host]`, `[Native p1-host]`), the handshake ("same build as the host"), `native-selfcheck.txt` (exe vanilla, 16/16 patterns unique). `!dag_mp_status` not run yet.
- [x] Solo check: single-player unchanged. Verified 2026-10-14 (pak 9cc56b2, DLL 1a84741): the developer played the nautiloid fight in real time: "It played perfectly translated to RTC" (not winnable, as BG3 intends: you flee).
  - One unexplained glitch the session before: MMB stopped bringing mouse-look back and Esc didn't open the game menu (nautiloid save, after arming Shocking Grasp). The logs showed no error and no blocked key; it was gone after restarting the game and reloading. Neither MMB nor Esc presses are logged yet.

**MP-1: everyone in first person.**
- [ ] Your own camera, movement, jump and crouch feel identical to single-player, as the joining player.
- [ ] Each player sees the others move, jump and crouch smoothly (no hovering, sliding or ghost jumps).
- [ ] 2 players, then a PLB party bigger than 4 if possible.

**MP-2: combat per player.**
- [ ] Melee, spells (with visible cast stages), bows, projectiles (visible to all; the host decides hits), mana and the hotbar.
- [ ] Fights with all players + enemies; enemies target every player correctly.

**MP-3:**
- [ ] Downed / revive / bleed-out / spectate any ally (any count).
- [ ] Stealth per player.
- [ ] Companions split between players with per-player V cycles.
- [ ] F interact + dialogue, map / fast travel.

**MP-4: polish.**
- [ ] Joining mid-session, reconnecting, the version check, lag tests, settings sync.
- [ ] 5-8 players via LAN.

## Release 0.1.0 alpha (Nexus Mods), started 2026-10-15

The first public build (DECISIONS 2026-10-15). Steps in [release.md](release.md) "Nexus release"; page text and form values in [nexus/](nexus/upload-sheet.md).

- [x] Release files built by `scripts/make-release.ps1`: mod zip, native zip, recommended settings; lint clean.
- [ ] Smoke test with the release files on DEV-SAVE: BG3 Mod Manager imports the mod zip, the log shows `mod_version 0.1.0.0`, `!dag_play` works, one goblin fight.
- [ ] Repo public on GitHub.
- [ ] `DarkAndGate.dll` and the native zip submitted to Microsoft (release.md "Antivirus false positives").
- [ ] Nexus page published; its link in README.md; `v0.1.0` tag pushed.
- [ ] tinybike told ([tinybike-message.md](tinybike-message.md)).

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

Head start (2026-10-12, M1b): companions and NPC allies already fight on Brawl's AI at the shared 4 s pace, through our swing / shot rules, with a weapon-attack fallback and idle diagnostics (not verified yet; M1b session notes).

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
