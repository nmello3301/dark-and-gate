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

Depends on M1a camera + mouselook being usable. Everything else in M1a can
land in parallel with M1b work.

### Status (2026-10-08): player-side combat works in first person ✅

Verified in-game on DEV-SAVE (fixes 1–5, `patches/m1b-fix*`):

- **LMB** swings a melee chain: 3 swings, real BG3 one-handed attack clip, hits land through a camera-relative swing arc (geometric cone + line of sight) and the server applies the damage.
- **1–0** arm a spell, **LMB** casts it at the crosshair, **RMB** or the same key cancels. Fire Bolt hits the character under the crosshair (6° aim assist) or the ground/object you aim at; Fireball and Misty Step land where you look.
- **Mana** is server-owned: pool from class level + casting stat, regeneration, per-spell cost, refund if a cast fails.
- **HUD**: crosshair + one status line (mana, armed spell, what you are aiming at).
- **MMB** toggles mouse-look; with the cursor visible, LMB/RMB go to the vanilla UI.
- `!dag_spawn_dummy [hostile] [name]` spawns an adult goblin to test on.

Lessons recorded for the next pass: `Ext.Require` only works at load time; `hit.Distance` is a 0–1 fraction of the ray; BG3's view forward is `+InvViewMatrix` column 3; ray hits can't name an entity from Lua; Fire Bolt is `Projectile_FireBolt`; `Osi.UseSpellAtPosition` takes 6 args; scripted `PlayAnimation` stalls the player during turn-based combat.

### Tooling (M1b)

- [x] **Animation browser + gallery** (`!dag_animlib`) *(verified 2026-10-09: browsing, filters, paged gallery, notes, per-character play rate; 9 picks in [anim-picks-2026-10-09.txt](anim-picks-2026-10-09.txt))*: per-character clip list with filters, solo play, tagging by mapping id (per-rig overrides, DFLT fallback), coverage by rig, a looping grid of preview copies with floating labels, play-rate slider when the blueprint exposes `PlayRate`. Written 2026-10-09, playtest: [playtest/animlib.md](playtest/animlib.md).

- [x] **Per-character animation play rate** (DLL hook on the shared PlayAnimation-node Execute, [anim-clock.md](spikes/anim-clock.md)): slow motion, freeze and 2x on Gale's clips. *(verified 2026-10-09)*
- [ ] Use the 9 picks: swing chain, prepare -> loop, left-hand attack, jump cast/ascend/descend/recover, with their noted speeds. Needs **exact-clip playback** (a mapping id plays the character's own stance version; see DECISIONS 2026-10-09).

### Known issues (M1b)

- **WASD dead after LMB spam** (reproducible, 3 fast clicks): queued `Osi.PlayAnimation` tasks stalled the Osiris queue. Fix written 2026-10-09 (queue purge before each clip + watchdog + swing recovery gate); `!dag_unstick` remains the manual escape. Awaiting playtest.
- **First swing animation only plays on the second LMB** (damage lands on the first): queue purge now runs before every clip (2026-10-09), awaiting playtest.
- **Jump while walking showed no lift** with the head-bone camera: the camera now adds any lift the body is missing; the DLL re-lifts the body when an engine write bypasses the hooks and logs `body writes: hook/refresh/external` per jump, plus `JUMP lift … liftSrc=body|body+camera-fill|camera-only` (2026-10-09 movement round).
- **Jump clips while moving:** `Osi.PlayAnimation` may stop the walk. `data.jump.moving_anims = "auto"` checks the first moving jump and skips clips on moving jumps if they root the walk (logged); awaiting playtest.
- **Face shows for a moment** while playing: the engine writes the hidden head's `RenderPasses` back. Re-hide check every 1000 ms (was 100 ms) plus an immediate re-hide when the player's visual / equipment changes (200 ms signature check; engine event subscriptions crashed the game at load), helmet sub-visuals included, written 2026-10-09; playtest [movement-round.md](playtest/movement-round.md) step 6.
- **Turn-based takes over** as soon as an enemy turns hostile — the real-time loop (Brawl import) is the fix. Until then swing animations are skipped in turn-based combat; `!dag_unstick` clears a stuck action queue.
- **Attack animations move Gale ahead of the camera**: the camera follows the engine pivot, not the body. Head-bone anchor written 2026-10-09 (`Head_M` via the Granny world pose, [m1b-head-bone.md](spikes/m1b-head-bone.md)); awaiting playtest.
- Camera can dip under the map while casting in turn-based (moot once combat is real-time).
- Rare frames of Gale's head showing while walking.
- All 3 swings use the same clip (`HUM_M_Rig_DFLT_CMBT_Melee_RHand_01_Attack`); per-swing clips and timing come with the animation pass.
- Head-zone hits need target height (bone reads); hits are torso/limbs for now.

### Checklist

- [ ] Brawl import wired in: `Server/Brawl/` strips committed, `BrawlAdapter.lua` bridges Brawl's AI into our net channels and mana check.
- [ ] Real-time combat loop (Brawl's RealTime pulse) running on DEV-SAVE goblins.
- [x] Generic melee chain: 3 swings with timing data, one shared attack clip. *(2026-10-08 — uses `data/weapons/longsword.lua` values for whatever is equipped)*
- [ ] Longsword: tested with a longsword actually equipped; chain picked from the equipped weapon's family.
- [x] Interim hit check: camera-relative swing arc (cone + line of sight), torso / limb zones, server-validated damage. *(2026-10-08)*
- [ ] Blade-path hit check, with head / torso / limb zones. Uses `GetBoneWorldPos`.
- [ ] **AI melee goes through our swing + blade-path system, not BG3 attack rolls.** `Pick.decideActionOnTarget` adapted so melee choices resolve through the swing scheduler, not `Osi.UseSpell`.
- [ ] **First-person movement: floaty Space jump** (visual lift of body + camera, BG3 jump clips in phases, `data/movement.lua`). Written 2026-10-09, awaiting playtest.
- [ ] **Cylinder hitboxes** for every character (aim, melee, server validation), lifted while jumping. Written 2026-10-09, awaiting playtest.
- [ ] **Head-bone camera anchor** (`Head_M` from the live Granny world pose; fixes the camera falling behind Gale during attacks). Written 2026-10-09, awaiting playtest.

**Movement round (2026-10-09), written, awaiting playtest** ([playtest/movement-round.md](playtest/movement-round.md)):

- [ ] Camera A/B: `!dag_pov_anchor head|pivot` identical at rest; head glued to the body walking / running / attacking / jumping. Per-frame `CAM delta` stats in native.log and on the status line; optional `!dag_pov_smooth` (off by default).
- [x] Walk by default, Left Shift toggles run (BG3WASD config; Shift+W autoforward unbound). *(verified 2026-10-09: "walking and running feel great")*
- [ ] Speed knob: `move.walk_speed / run_speed / speed_mult` (`data/movement.lua`, MCM), `Movement.AddModifier / RemoveModifier`, `!dag_speed_mult / !dag_walk_speed / !dag_run_speed`. Native lever: the MoveController template fetch ([move-speed.md](spikes/move-speed.md)).
- [ ] Locomotion clips play at the gait's speed multiplier (no foot sliding).
- [ ] Jump while walking / running keeps the movement and steering; same arc; no double jump; lift source logged per jump. **2026-10-09 playtest: no visible jump while moving**, although the DLL lifted the Visual every frame. Fix 2: the camera measures the head mesh's real rise and fills the rest; the body re-applies the lift after engine writes when the mesh doesn't follow (`LIFT: … force on`, `JUMP lift … meshRise=`).
- [x] Jump while walking / running (camera + body rise, movement kept). *(verified 2026-10-09)*
- [x] Single-click swing chain. *(verified 2026-10-09, unarmed; weapons not tested yet)*
- [x] Standing jump. *(verified 2026-10-09)* Clips now cast → ascend → descend fitted to the airtime (x1.35); the Recover clip is dropped (developer: unneeded).
- [ ] Swing / cast / spell prepare loop in the air take priority over the jump clips; the arc continues; landing waits for the action.
- [ ] Spell prepare loop while a spell is armed (ids from the spell's `SpellAnimation` stats); LMB casts, RMB / same key cancels to idle.
- [x] Channelled casting, straight-line aim, unlimited range, momentum in the air. *(verified 2026-10-10: "spells feel great, aim feels perfect")*
- [ ] **Casting slows instead of blocking** (2026-10-10): the prepare animation is off for now (it stopped all movement); while the cast time runs on the ground, speed x0.7 (`casting_speed_mult`, Movement modifier "casting"); ready to release = full speed. Next pass: casting animation without rooting.
- [ ] **Channelled casting** (2026-10-09): selecting a hotbar spell starts casting (prepare animation, priority over the jump clips); held indefinitely; LMB releases only after the cast time (`data/spells.lua` `cast_time_s = 2.0`, server-checked via `SpellArm`). Later: cast time scaled by character traits.
- [ ] **Shooting spells have no max range**: aim point up to 100 m along the crosshair, spell `TargetRadius` raised to 100 at stats load (`Shared/SpellRange.lua`).
- [ ] **Straight-line spell aim** (2026-10-10): one ray from the eye along the crosshair; first hit wins (character hitbox cylinder exactly on the line, else world, else the point 100 m out). No cone assist, no ground-plane / 18 m "ahead" fallback. HUD shows `character|world|far <distance>` from the same function.
- [ ] **Momentum kept when arming in the air**: the prepare clip (an Osiris PlayAnimation, which stops the walk) waits for the landing while airborne and moving.
- [ ] **Animation recorder** (`!dag_anim_record on|off`, 2026-10-10): the DLL logs every animation BG3 starts on the player (PlayAnimation-node Execute hook, socket 0); Lua resolves ids to clip names -> `anim-record.txt`. Use: record BG3's own jump (Z) and spell casts to pick the right jump / prepare clips.
- **Recorder first run (2026-10-10):** the node's animation input is a FixedString (`0x28400001`-style ids), not a GUID; the DLL now decodes it through the game's global string table (`name=` in `native-anim-rec.txt`).
- [ ] **Real jump lift** (native, decided 2026-10-10): the character's real height follows the jump curve; body, camera, hitbox and collision together; clears low obstacles. Static RE spike running ([real-lift.md](spikes/real-lift.md)).
- **Body follows the jump (2026-10-10):** result: the engine rewrites the render objects every frame (7904 of 7920 lifted writes), so at 5.5 m the body still trailed ~3 m below the camera. Visual lift = fallback only.
- **Body follows the jump (2026-10-10, attempt):** the drawn body is the meshes' render objects (`MeshBinding+0x28`), which the root-Visual lift never moved (head rose 0.26 of 5.5 m). The jump now lifts every render object through its own `SetWorldTranslate` (`JUMP objects …` line per jump; `!dag_lift_objects off` for A/B).
- **10x jump test (2026-10-10):** casting in the air plays the cast animation in the air (wanted). At 5.5 m the camera rose ~2x the body (camera fill measured on a mesh object that never moves, `meshRise=0`) -> now measured on the head bone; the body parts looked disjointed (visual lift vs attachments at big heights). Candidate: use BG3's real jump movement instead of the visual lift.
- [ ] Spell prepare animations are the wrong clips (developer, 2026-10-10; fix later): check the logged `SpellAnimation` slot order.
- **Known limitation:** any scripted clip (`Osi.PlayAnimation`) stops WASD movement on the ground too (jump clips, prepare loop). Animation playback that doesn't go through Osiris (native) would fix it; not scheduled.
- [ ] First swing animates on a single click; single-click chain 1→2→3. **2026-10-09: cause found** — the auto-picked swing-1 clip was BG3's ranged attack (no clip in melee stances), so click 1 played nothing and click 2 (swing 2) did. Swings 1–3 now use the developer's picks (RHand, LHand, RHand) via `data/anim_tags.lua`; ranged clips excluded from the auto-pick.
- [ ] Blocking and parry: **custom animations**; block only with a shield equipped, parry only with a weapon that can parry (decided 2026-10-08).
- [x] Fire Bolt aimed at the crosshair (character aim assist, or ground / object point). *(2026-10-08)*
- [x] Fireball cast at the crosshair. *(2026-10-08)*
- [ ] Fireball ground preview.
- [x] Misty Step to the crosshair (`Osi.UseSpellAtPosition`, 6 args). *(2026-10-08)*
- [x] Mana pool, regeneration and costs (server-owned). *(2026-10-08)*
- [x] Hotbar on keys 1–0, arm-then-cast (LMB cast, RMB / same key cancel). *(2026-10-08)*
- [ ] Hotbar setup window (ImGui; `!dag_hotbar <slot> <spell>` works meanwhile — native tab is M4).
- [x] Hit reactions (BG3's own, triggered by our server-side damage). *(2026-10-08)*
- [ ] Blood / spark effects at the hit point.
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
