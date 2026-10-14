# Playtest: direct WASD controller (one pass)

**Build:** 2026-10-13, `MoveFeel.cpp` plus Lua `Client/Movement/{Movement,LocoSkip,MoveMetrics}.lua` and `Server/MoveProbe.lua`.
**Design:** [spikes/move-feel.md](../spikes/move-feel.md); DECISIONS 2026-10-13, "Replace BG3WASD's movement with our own direct controller".

**Where things show up:**
- `MOVEFEEL` lines are in `native.log`.
- `Move:`, `MoveMetrics:` and `LocoSkip:` lines are in `client.log`.
- `MoveProbe:` lines are in `server.log`.

Claude reads all of them; you only report how it *felt*.

**How to type commands:** open the console, type `client`, then the command (for example `!dag_move_metrics on`). One `client` per console session is enough.

**For the timing steps (1, 2 and 0b):**
- Keep the mouse still: the strafe and reverse timings are measured in camera space.
- Leave about a second between presses.

## Build 10 (2026-10-13): no recover after a jump

Playtest 8: the grace worked (Space pressed early was kept), but every hop still caught. The log showed two causes:

- After each jump, BG3's landing animation held the character in the landed fall state for 150–230 ms. WASD couldn't move you, so each hop took off at 0 m/s and the air steering's 2.5 m/s floor took over. A running jump takes off at about 3–4 m/s.
- A 0.15 s jump cooldown after landing came on top of that.

Build 10:
- the cooldown is 0, and a hop buffered in the air leaves on the landing tick;
- the DLL clears BG3's landing hold after our jumps (spikes/real-lift.md "The landing hold");
- a hop keeps the last jump's speed.

**Do:**
1. Hold W and bunny hop 15 times, pressing Space just before each landing.
2. Single jumps while running: land and keep running.
3. Strafe-hop with A/D.

**Expect:**
- no catch between hops, and the speed stays the same from hop to hop;
- after a single jump you run on at once.
- native.log: `RJUMP landing hold skipped …`, `RJUMP landing: fall state off the machine N ms after the jump's end` (N under about 50), and `RJUMP start … (the last jump's momentum)` on hops.

**Knob:** `!dag_jump_land_hold on` brings BG3's hold back, for comparison.

## Build 9 (2026-10-13): bunny-hop grace

The build 8 session's log: 32 jumps, 8 take-overs of the landing state, and no fake (visual-lift) jumps. One hop was lost: Space pressed 90 ms before landing was ignored as "already airborne".

Build 9: Space pressed up to 0.25 s before landing, or in the 0.15 s after it, is kept and jumps the moment a jump is allowed. In the DLL, a jump that arrives while you are still falling waits up to 0.25 s for the landing, then starts. A hop never takes over a fall that is lower than its take-off, so there is no double jump off a ledge.

**Do:**
1. Hop 15 times in a row, pressing Space a little *before* you land, running and standing.
2. Jump off a ledge (or the gate's steps) and press Space while falling, well before you land.

**Expect:**
- every hop goes up the moment you land, with no exact timing needed;
- off the ledge: no jump in mid-air. A press in the last moment before touching down jumps right after the landing.
- client.log: `Jump: Space buffered N ms before landing`, then `Jump: buffered Space fires`;
- native.log: `JUMP seq=… waits for the landing` followed by `JUMP start seq=… after waiting N ms`, or nothing when no wait was needed. No `lift=body+camera`.

**Knob:** `!dag_jump_buffer <s>` (0 = off).

## Build 8 (2026-10-13): hopping right after a landing

Playtest 7: almost every other jump changed your direction. Those jumps came right after a landing, while BG3's fall state was still in its landing phase. The real jump refused them ("RJUMP: already falling") and fell back to the old visual lift: you stayed on the ground, and BG3's walk carried you on under a fake jump.

Build 8: the real jump takes that fall state over. A jump pressed while you are really in the air (falling off a ledge) is skipped, without the visual lift.

**Do:** hop 15 times in a row (Space again right as you land), running and standing.

**Expect:**
- every jump goes up for real;
- no direction change;
- native.log: `RJUMP: re-arming the last fall for a new jump …`, and no `lift=body+camera`.

## After build 7 (2026-10-13): standing on rocks dropped

The developer had the rock attempts (builds 5–7: foot box, step-up, hold-the-floor, knee-height walls) removed: jumping felt worse. Rocks are a known limitation (DESIGN, Campaign compatibility). The sync guard (no take-off flicker, verified) stays. Ignore the rock steps in builds 5–7 below.

## Build 7 (2026-10-13): staying up on the rock, and what turns you

Playtest 6: the sync guard fixed the flicker. The ground code never acted (`gs=on lifts=0 steps=0 walls=0`), so the rock behaved as before.

Build 7 holds you on the surface under your feet when BG3 drops you more than 0.2 m in one frame. It also logs every drop, the knee sweeps, and any time you move more than 60° away from your keys.

**Do:**
1. Jump onto the beach rock. Stand 5 s. Walk slowly across the top and off an edge.
2. Walk straight into the rock's tall face.
3. On the beach, run and jump over debris until the direction change happens again. Note what the debris looked like.

**Expect** in native.log:
- `GROUND hold #n` when you'd have sunk, or `GROUND drop #n` if the box found nothing;
- `GROUND so far: … knee sweeps -> … held back`;
- `MOVEFEEL check … moving off the keys` when the direction changes.

**Tell me:**
- whether you stayed on top;
- for the direction change: did your character walk off another way, or did the view turn?

## Build 6 (2026-10-13): the jump keeps going, rocks are solid

Playtest 5 found two things:
- **What ended the jumps:** the engine's reset when the server changes your character flag 0x20, about 60 ms after take-off. It stops all movement and resets the character light, which is likely the flicker. Build 6 skips it during a jump.
- **The foot box in the air:** it landed jumps on every small rock. It now holds you only where you stand. Faces taller than a step block walking.

**Do:**
1. Run-jump 10 times, over flat ground and past small rocks. Every jump should go its full arc.
2. Watch the take-off. Then type `!dag_jump_sync_guard off`, jump 5 times, and type `!dag_jump_sync_guard on`.
3. If it still flickers with the guard on: `!dag_jump_play_anims off`, jump 5 times, then `!dag_jump_play_anims on`.
4. At the beach rock:
   - walk into its tall face: you stop or slide along it, not into it;
   - jump onto it: you stay up, including near the edge;
   - jump off.

**Expect** in native.log:
- `RJUMP sync #n: … skipped` on (nearly) every jump;
- no `RJUMP exit` before u ≈ 1, and no `landed early … u=0.01`;
- `GROUND wall #n` when you walk into a face.

**Tell me:**
- whether the flicker changed with the guard, and with the clips off;
- what happened on and around the rock.

## Build 5 (2026-10-13): standing on rocks, the flicker bisect

**New:** ground support, so you stand on what your jump reaches. A foot box (0.30 × 0.40 m) keeps you up while any corner is on something. Walking into a rock's edge lifts you onto it instead of sinking in. See [spikes/ground-support.md](../spikes/ground-support.md).

**Do:**
1. At the beach rock: jump onto it (run at it, Space).
   - Stand there.
   - Walk slowly to its edge until only the front of your feet is on it.
   - Turn around.
   - Jump off.
2. Walk into a few rocks' low edges and onto small rocks.
3. The flicker, 5 running jumps each:
   - normal;
   - after `!dag_jump_play_anims off` (then `!dag_jump_play_anims on`);
   - after `!dag_jump_mode visual` (then `!dag_jump_mode real`).

**Expect:**
- you stay on the rock until the whole foot box is past its edge;
- your feet stay on rock surfaces instead of inside them;
- native.log:
  - `GROUND step-up` lines and `GROUND so far: …`;
  - for any cut-off jump: `RJUMP exit … (callers rva …)` and `RJUMP interrupted … layer 0 type N, layer 1 type N`.

**Tell me:**
- whether you stayed up on the rock;
- what happened when you tried to walk on top of it;
- which of the two commands made the flicker go away.

## Build 4 (2026-10-13): jumps cut off mid-air

Playtest 3: 11 of 53 running jumps were cut off mid-air (the body snapped back to the ground: the take-off flicker, and the jump not going through). Build 4 holds the ground controller still while a jump is in the air, and logs any jump that still gets cut off.

**Do:**
1. Run and jump about 10 times, in different directions and over uneven ground.
2. Type `!dag_move_mode vanilla` and run-jump 5 times.
3. Type `!dag_move_mode direct` again.

**Expect:**
- every jump goes the full arc;
- native.log: no `RJUMP interrupted` lines in direct mode, and one `MOVEFEEL: the WASD controller sat out N frames of the last jump` per running jump.

**Tell me:**
- whether the take-off flicker is gone or smaller;
- whether vanilla (step 2) had it too.

## Build 3 (2026-10-13): engine facing, jump take-off

Playtest 2: `!dag_move_turn engine` removed the flicker (now the default). One small twitch of the view at each jump take-off remained.

**Do:**
1. Run and jump about 5 times in direct mode.
2. Type `!dag_move_mode vanilla` and jump 5 times the same way.
3. Type `!dag_move_mode direct` again.

**Expect:**
- no twitch at take-off in direct mode;
- one `JUMP takeoff seq=… head step max …` line per jump in native.log. The direct and vanilla numbers should be alike.

## Build 2 (2026-10-13): the flicker

Playtest 1 found a flicker about once a second while walking in direct mode (model, camera, the shadow turning away and back). Build 2 moves on the physical keys and our own camera instead of BG3's camera object; see [spikes/move-feel.md](../spikes/move-feel.md), "Playtest 1".

**Do:** in direct mode, walk and run for about 20 s each: straight ahead, sideways (A or D alone), backwards, and while turning the mouse slowly.

**Expect:**
- no flicker, and the shadow keeps facing where you run;
- `Move: gait=` stays `run` (or `walk`) while the key is held;
- native.log: `MOVEFEEL check` lines tell which cause it was. Lots of `input off` = BG3's camera object (now bypassed). `body turned by others` or `loco clip mid-run` = something still to fix.

If it still flickers, type `!dag_move_turn engine`, then `!dag_move_input game`, and say which one changes it.

## 0. Setup and vanilla baseline

1. Load **DEV-SAVE**. First person comes on by itself (`!dag_play`).
2. Walk a step: the DLL learns your character from the first WASD move.
3. Expect these log lines:
   - `MOVEFEEL: installed (...)` and `MOVEFEEL: DIRECT (first person, move_mode direct)` in native.log;
   - `Move: registered ... mode direct` in client.log;
   - `LocoSkip: N locomotion Start / End / turn clips found` (the first time; later `(cached ...)`).
4. **0b. Vanilla baseline.** Type `!dag_move_mode vanilla`, then `!dag_move_metrics on`. Then:
   - 5×: from standing, hold W about 1.5 s, release;
   - 3×: run forward, then switch W → S without stopping;
   - 3×: run forward, then switch W → D;
   - type `!dag_move_metrics off`.
5. Expect:
   - `MOVEFEEL summary [vanilla] ...` in native.log;
   - `MoveMetrics: drift [vanilla] (whole run) ...` in client.log.
6. Type `!dag_move_mode direct` (native.log: `MOVEFEEL: DIRECT`), then `!dag_move_metrics on`. Leave it on for steps 1–10.

## 1. Start and stop

**Do:** from standing, hold W about 1.5 s, then release. Repeat 5×.

**Expect:**
- `MOVEFEEL [direct] start: 90% speed after ≤ 80 ms (first motion ≤ 20 ms, settles at ~2.0 m/s walking / ~3.75 running)`;
- `MOVEFEEL [direct] stop: ≤ 50 ms, slide ≤ 0.05 m`.

**Feel:** full speed at once, no glide when you let go.

## 2. Direction changes

**Do:**
- W → S without stopping (3×): expect `MOVEFEEL [direct] reverse: ~100–130 ms`.
- W → D → S → A circle: expect `MOVEFEEL [direct] strafe 90 deg: ≤ 80 ms` lines.
- Tap A / D / A / D: expect strafe lines with no `not settled after 2 s`.

**Feel:** no turn-in-place pause; you move the new way at once (the body follows with BG3's own turn).

## 3. Strafing while looking around

**Do:** hold D (and W+D) while turning the mouse.

**Feel:**
- smooth, no jitter;
- the feet roughly match the ground speed (no ice-skating);
- the start / stop poses are gone or very short.

If the body jitters, say so (facing is BG3's own steering since build 3; `!dag_move_turn instant` is the old fighting mode).

## 4. Speed modifiers

Run each of these and compare the `start: ... settles at X m/s` values:

| Do | Expect `settles at` |
| --- | --- |
| Left Shift toggles walk / run | ~2.0 walk / ~3.75 run (humans) |
| C crouch | ×0.6 (and BG3's sneak cap) |
| Cast a spell while walking (hold the cast) | ×0.7 |
| Draw the bow while walking | ×0.6 |
| `!dag_speed_mult 1.5` (then `!dag_speed_mult 1`) | ×1.5 |

`Move: speed walk x… run x…` lines show the multipliers.

## 5. Jump

**Do:** jump while running forward, then while strafing.

**Expect:**
- `RJUMP start ... vel=(…)`, non-zero, along your run: momentum kept;
- `RJUMP end` / `landed early`, then the next `MOVEFEEL ... start` or running straight on.

**Feel:** landing goes straight back into instant control. The jump itself should feel exactly as before.

## 6. The world

**Do:**
- run into a wall at an angle (you slide along it);
- go up and down stairs, and up a slope;
- go through a doorway;
- walk off a ledge (or stop at one, as vanilla would);
- push into an NPC.

**Expect:** no `MOVEFEEL ... CORRECTION` lines.

**Tell me:** any clipping, sticking or snagging.

## 7. Sync

**Do:** walk and run around the grove for 60 s.

**Expect:**
- `MOVEFEEL summary [direct] ... corrections 0`;
- `MoveMetrics: drift [direct] ... moving ...: matched max < 0.1 m` and `standing ... raw max ≈ 0`.

The test **fails** if corrections appear in normal walking.

## 8. A real fight

**Do:** walk north into the goblin fight, or use `!dag_goblins`.

**Check:**
- enemies (melee and archers) track you;
- your hits land;
- C crouch still hides you (stealth).

**Expect:** no corrections.

## 9. Pauses mid-walk

**Do** each of these while running:
- F on something;
- talk to someone;
- M (map) open and close.

**Expect:**
- dialogue and cutscenes: native.log shows `MOVEFEEL: VANILLA (first person off / paused / downed)`, then `MOVEFEEL: DIRECT (...)` after;
- you don't keep walking after a menu opens;
- control comes back at once after it closes.

## 10. Misty Step

**Do:** cast Misty Step while running.
- If your character doesn't have it: type `!dag_learn Target_MistyStep`, then put it on a hotbar key in the Prepare Hotbar menu (H).

**Expect:**
- the teleport works;
- `MOVEFEEL [direct] teleport: X m (not a correction)`;
- running resumes.

## 11. Compare

**Do:** type `!dag_move_metrics off`.

The two summaries (`MOVEFEEL summary [vanilla]` from 0b and `[direct]`), and the two `MoveMetrics: drift` lines, fill the table in [spikes/move-feel.md](../spikes/move-feel.md).

**Tell me:** how direct felt next to vanilla, and anything that looked wrong.
