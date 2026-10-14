# Direct WASD controller: where the feel comes from, and where we take it over (static RE)

**Status:** static RE only, built, **not verified in-game**.
**Date:** 2026-10-13
**Binary:** `bg3_dx11.exe` Patch 8 (image base `0x140000000`). Ghidra (MCP, read-only decompile) plus capstone / byte scans of the exe; no debugger, no game process. Builds on [move-speed.md](move-speed.md) (the MoveController and where its speed comes from) and [real-lift.md](real-lift.md) (the movement machine, MSFalling, the client → server sync).

**Decision:** DECISIONS 2026-10-13, "Replace BG3WASD's movement with our own direct controller". **Code:**
- `tools/native/src/Hooks/MoveFeel.cpp` (controller and metrics);
- `MoveSpeed.cpp` (direct speed);
- `AnimRate.cpp` (locomotion clip skip);
- Lua `Client/Movement/Movement.lua`, `LocoSkip.lua`, `MoveMetrics.lua` and `Server/MoveProbe.lua`.

Confidence tags: **[H]** instruction-level reading, **[M]** decompiler reading plus inference, **[L]** guess.

## TL;DR

- **Injection point: A**, BG3's own controller-mode movement. It is exactly what BG3WASD already uses for the keyboard: it NOPs the controller-mode check in "may WASD run?" and feeds WASD into BG3's four CharacterMove axes. So we never left it. **[H]**
- That path is **MoveController → MoveTo request → MSMoveTo path step**. The client sends the path to the server, which replays it in MSMoveToSync. **[H]**
- Walls, slopes, stairs, the nav grid, doors, characters, ledges and multiplayer sync are already the engine's. That is why A wins and B or C were not needed.
- **The feel comes from five places in that path, all found:**

  | # | Source | Where |
  | --- | --- | --- |
  | 1 | 50 ms dead time after every controller entry | jbe at `0x14425F589` |
  | 2 | Move-target ("carrot") ramp of 16 m/s² | minss at `0x14425FA4C` |
  | 3 | The MoveTo step uses the engine's **ramped** `Movement.Speed`, not the requested speed | client `0x141BEEE90`, server replay `0x1430611E2` |
  | 4 | The stop slide: after key-up, "may WASD run?" stays true while the carrot is non-zero, so the character walks on to the shrinking carrot | (follows from #2) |
  | 5 | The body turns through BG3's steering | look-at on the steering machine |

  **[H]** for 1–4, **[M]** for 5.
- **Direct mode** removes 1–3 with four small switchable patches, feeds the controller our own vector and velocity (which ends 4), and turns the body itself (5).
  - Vanilla mode restores every byte.
  - Third person is always vanilla.

## Step 1: the injection points

### A) BG3's gamepad / controller-mode movement: **chosen**

- **Where the stick vector enters [H].** `GetMovementInputWorldVec(out vec3*, u16 player, u8 flag)` `0x14425E7F0`:
  - It reads input commands `0xA0` / `0x9F` / `0x9D` / `0x9E` (CharacterMove forward, back, left, right) through `GetInputValue` `0x1440EFB10`.
  - It forms `(fwd−back, left−right)`, normalises it when longer than 1 and rotates it by the camera yaw.
  - Gamepad and keyboard share it. BG3WASD hooks the four `GetInputValue` calls inside it: walk = ×WalkSpeed, zero when BG3WASD is in camera mode.
- **Callers [H].** The three are slots of the client **MoveController** vtable (rva `0x591A158`; ASCII tag `MoveController` before it):

  | Slot | Function | What it does |
  | --- | --- | --- |
  | 7 | "may WASD run?" `0x14425EC30` | Returns true while the input or the **carrot** (WASD state `+0x34`) is longer than 0.1 and the start check `0x141CAB8E0` passes. |
  | 25 | Enter `0x14425F160` | Creates the per-entity WASD state component fresh (timer `+0x80` = 0). |
  | 26 | Update `0x14425F2C0` | `(ctl, GameTime*)`, dt at `GameTime+8`. Runs only while slot 7 says yes. |

  `ctl+0x68` = `ecl::Character*`, `ctl+0x100` = the input flag byte, player id = `character+0x12C` (0 when its high half is set).
- **Feeding a virtual stick vector from WASD + camera yaw every frame:** yes. We hook the three call sites (`InstallFarCall5`, chained like BG3WASD's) and the Update / Enter vtable slots.
  - BG3WASD's hooks sit *inside* the callee, so nothing collides.
  - Our vector replaces only the Update's read. BG3's own (BG3WASD-fed) vector is still read once per frame for the direction, walk / run and gating (below).

### B) Velocity injection into the client movement component: not needed

The movement state machine (`ecl::Character+0x78`) has no velocity for walking. MSMoveTo steps the character along a nav path by `Movement.Speed × dt`, so "velocity injection" = what A does through the step speed. A falling-style state (the RealJump machinery) would need our own walls, ground and a custom server sync (the server only learns about MSFalling once, at its start).

### C) Full ownership (our own position writes + collision + sync): rejected

Raw `SetTranslate` writes are never reported to the server ([real-lift.md](real-lift.md) Q3), and we would rebuild the nav-grid rules, step-up, ledges and doors that MSMoveTo already has. No hard blocker in A forced it.

## The path, and where the feel goes wrong

### MoveController Update `0x14425F2C0` [H]

1. Input → WASD state:
   - `+0x10` raw vec;
   - `+0x04` dir (normalised);
   - `+0x00` magnitude.
2. **Dead time.** `if (state+0x80 <= 0.05) { state+0x80 += dt; return; }`.
   - The state is created fresh at every Enter, so every WASD start waits 50 ms.
   - `comiss xmm0, [0.05]; jbe` at **`0x14425F589`** (pattern `F3 41 0F 10 86 80 00 00 00 0F 2F 05 ?? ?? ?? ?? 0F 86 ?? ?? ?? ?? 48 8B D3 49 8B CD E8`, jbe at +16).
3. Template speeds (MoveSpeed's hook site `0x14425F428`): `speed = Stroll + t·(Run − Stroll)`, `t = (clamp(mag, 0.1, 0.9) − 0.1)/0.8`.
4. **Carrot.** `carrot (+0x34)` moves toward `speed·dir` by at most **16·dt** m per frame.
   - `mulss xmm1, [16.0]; minss xmm3, xmm1` at **`0x14425FA4C`** (pattern `48 8B 45 30 F3 0F 10 48 08 F3 0F 59 0D ?? ?? ?? ?? F3 0F 5D D9`, minss at +17).
   - From standing to a 3.75 m/s run: 0.23 s. W → S: 7.5 m of carrot to swing, 0.47 s, through zero, where the MoveTo stops and restarts.
5. Target = position + carrot, grid-corrected by `0x1442603B0` (near walls the speed is scaled by `0.1 + 0.9·k`). A grid line walk gives the target height.
6. `|target − pos| < 0.01` → `StopMovement(machine, 0)`.
   - Otherwise a MoveTo request: `0x141BED4C0(moveTo, params, 400, 1, {1, 1, speed = |carrot|, kind 1})`, then the push into layer 0.
   - The request re-paths when the target moved more than 2 cm.
7. Look-at: steering machine (`ecl::Character+0x80`) state 6 → `0x141BEAA10(state, pos + step dir)`. BG3's steering turns the body toward it.

**The stop slide (vanilla) [H].** Key up → the input is 0, but slot 7 stays true while the carrot is longer than 0.1. The Update shrinks the carrot by 16 m/s² and the character walks on toward `pos + carrot`, then stops (about 0.2 s and a few tens of centimetres at run).

### MSMoveTo::Update `0x141BEE2C0` (client) and MSMoveToSync::Update `0x143060A30` (server) [H]

- The speed request is resolved by `0x141BF6AC0`: the explicit float, `SpeedMultiplier`, the `CanMove.SpeedLimit` clamp and the status slow-down. The result is written to **`eoc::MovementComponent.Speed2` (`+0x14`)**.
- The step along the path is **`Movement.Speed` (`+0x10`) × dt**:
  - client `movss xmm7, [rax+0x10]` at **`0x141BEEE90`** (pattern `F3 41 0F 11 75 14 48 8B 45 D0 F3 0F 10 78 10 4C 8B A5 28 02 00 00 F3 41 0F 59 7C 24 08`, +10);
  - server `movss xmm10, [rax+0x10]` at **`0x1430611E2`** (pattern `F3 45 0F 11 41 14 48 8B 44 24 58 F3 44 0F 10 50 10 48 8B 45 80 F3 44 0F 59 50 08`, +11).
- `Speed` is ramped toward `Speed2` somewhere else. The integrator was not found among the systems that touch `eoc::MovementComponent` **[L]**: the template acceleration `+0x588`, or the start / stop clips, which matches "Run_F_Start" being 1 s long.
- The step reads it every frame, so it doesn't matter who ramps it.

### Sync (client → server) [H]

- The client sync builder `0x141FE0520` sends, per controlled character, **the path** whenever `eoc::PathingComponent.PathId` (`+0x3C`) changes: message 0xEB, the nodes with two flag bits each, `PathMovementSpeed` `+0x44`, `+0x48` and `ServerControl` `+0x4C`.
- With no path it sends the current position.
- The server replays it in **MSMoveToSync** (type 3: `Positions`, the two flag arrays): the same `Speed × dt` step from its own (ramped) `Movement.Speed`.
- Rotation goes as the steering state (message 0x24, steering type changes). A falling start goes as 0xCC ([real-lift.md](real-lift.md)).

## Direct mode: what the DLL does (`MoveFeel.cpp`)

Only while `move_mode=1` **and** first person is live (on, active, not the downed orbit). Toggled from the render thread with one interlocked 8-byte store per patch.

| # | Patch | Direct | Vanilla |
| --- | --- | --- | --- |
| 1 | dead-time `jbe` (`0x14425F589`, 6 bytes) | 6-byte NOP | original |
| 2 | carrot `minss` (`0x14425FA4C`, 4 bytes) | 4-byte NOP, so the carrot = speed·dir at once | original |
| 3a | client step load (`0x141BEEE90`) | stub: `Speed = Speed2` (xmm6), step with it | stub: original load |
| 3b | server step load (`0x1430611E2`) | stub: `Speed = Speed2` (xmm8), step with it | stub: original load |

- **3a / 3b** are permanent `call` stubs installed at load. A flag byte selects the behaviour.
- **3b** runs on the host only, for every player-controlled character's synced path.

**The controller** (MoveController Update hook, game thread, dt from `GameTime+8`):

1. **Wish direction.** The physical W/A/S/D on **our** camera's forward (the same mapping and strafe sign as the real jump's air steering). Default since playtest 1, see "Playtest 1" below.
   - BG3's own vector (one extra `GetMovementInputWorldVec` call) is still read every frame. Its length tells BG3WASD's walk / run state (under 0.95 = walking, its WalkSpeed).
   - It also gates: it goes quiet wherever vanilla WASD does (chat, console, dialogue, BG3WASD's camera mode). Keys down while BG3 sees no movement for 120 ms count as released.
   - `!dag_move_input game` takes the direction from BG3's vector instead (the first build's default).
2. **Target speed** = `MoveSpeed::NaturalSpeed(walking)`:
   - the walk lerp × walkMult, or Run × runMult;
   - Lua's multipliers carry speed_mult, crouch ×0.6, casting ×0.7 and the bow draw;
   - the engine's resolver still clamps it (SpeedLimit, status slow-downs).
3. **Velocity.** Along the wish it accelerates at `S/accel_time` up to S, and brakes at `S/decel_time` first if it points backwards. Across the wish it brakes. With no wish it brakes to a stop. 0 = instant.
   - W → S: decel, then accel (≈ 0.1 s).
   - W → D: the old component brakes in 0.04 s while the new one builds in 0.06 s.
4. **Output.**
   - The Update's input read gets `v/|v|` (unit length: lerp `t = 1`, so Run).
   - `MoveSpeed`'s template block gets `Stroll = Run = |v|`.
   - So the carrot is exactly `v`, the MoveTo request speed is `|v|`, and the step moves at `|v|`.
   - At `|v| < 0.03` with no wish the vector is zero. The carrot is 0, so BG3 stops on the spot this frame and slot 7 ends the controller next frame: no slide.
   - While turning around, the wish direction at 0.05 m/s is sent instead, so no stop frame.
5. **Facing.** Default `engine`: BG3's own steering turns the body, as in vanilla (Playtest 2).
   - `!dag_move_turn instant` or `<deg/s>`: while `|v| > 0.25`, `ecl::Character` vtable `+0xE0` (`SetRotation` `0x141C65700`, the quaternion setter next to `SetTranslate` `+0xD8`) gets the yaw of `v`.
   - BG3's steering writes its own yaw back over it, so the body flickers. These modes are kept only as knobs.
   - Standing: untouched, so the body follows the camera as before.
   - It never gates movement.

**Animation.**
- `Movement.Speed` = the target, so the locomotion blend sees the real speed at once.
- The walk / run clips keep their play rate from `Movement.lua` (gait multiplier, so the feet match the speed).
- The Start / End*Foot / turn clips are found by name in the character's own animation sets (`_LOCO_` + `_Start` / `_End` / `Turn`; cached per set in `DarkAndGate/locoskip-v1-<sig>.txt`). The DLL plays them at ×5 (`move.loco_transition_rate`) in direct mode, through its own AnimRate table (the bow and spell clip rates are untouched).
- Known ids, from [anim-record-2026-10-10.txt](../anim-record-2026-10-10.txt): Run_F_Peace_01_Start `6687e57c-…`, EndRFoot `cb419433-…`.

**Everything else stays the engine's:**
- walls and sliding (the grid-corrected target);
- slopes, stairs, step-up and ledges (MSMoveTo's fall check hands off to MSFalling);
- doors and characters (nav grid);
- teleports, knockback and cutscene moves (other movement states; the controller only touches the WASD MoveController);
- turn-based mode (BG3's WASD gate refuses to start);
- the real jump: take-off uses the measured velocity, steering in the air is RealJump's, and the controller keeps its velocity through the jump, so the landing resumes at speed.

## Metrics (`!dag_move_metrics on|off`)

**DLL, render thread** (`MOVEFEEL` lines in native.log, a summary every 60 s and on off):
- the WASD character's position every frame, speed over 60 ms, and the physical keys;
- **start**: keys down from standing → the first frame at 90 % of the speed held 0.7–1.0 s later (plus the first visible motion);
- **stop**: all keys up while moving → when the position stops changing, and the slide distance;
- **reverse**: the key direction flips while moving → velocity turned past 150° at 90 % of the old speed;
- **strafe**: the key direction turns 30–150° → the velocity has turned that far (±10°);
- **corrections**: a horizontal jump far beyond what the speed explains (6 m or more = a teleport, not counted).

**Lua** (`MoveMetrics` lines in client.log every 10 s and on off): the server sends its own position of your character every 50 ms (`Server/MoveProbe.lua`).
- **raw** = distance to where this client has you now.
- **matched** = to the closest point of your last 0.5 s, with that lag. The server replays your path, so matched is the real disagreement and the lag is its delay.
- The samples are split into **moving** and **standing** (still for 300 ms).

## Playtest 1 (2026-10-13): flicker about once a second

**Report.** In direct mode, walking in any direction: the character model and the camera flicker every couple of steps (about once a second), and the shadow shows the body turning away quickly and back. Not in the air. Seen in more than one save.

**Log evidence.**
- `CAM delta` (head-bone eye minus the engine pivot, per frame): every 8 s window of direct-mode walking has a single-frame step of **0.25–0.45 m** (`jerk ≈ max`, so a step that holds, not a one-frame spike). Standing: 0.001 m. A body snap of 90–180° moves a head that sits 0.1–0.2 m in front of the pivot by about that much.
- `Move:` gait flips walk ↔ run within 200–400 ms while W is held (speed 1.6–3.2 m/s). The start probe "settles" at 2.80 m/s, between walk (1.99) and run (3.75).
- BG3's gameplay camera object changes again and again while moving (`POV: BG3's gameplay camera object A -> B`, 15 swaps in this run, the log caps at 40).

**Cause guessed after playtest 1 [M], disproved by playtest 2** (`input off` fired once; the real cause is the steering fight, see Playtest 2).
- `GetMovementInputWorldVec` turns `(fwd − back, left − right)` by the yaw of the player's **active gameplay camera object** (`0x14425E9DB`, camera manager `0x1417F6DA0`), not by our mouse-look camera.
- If a freshly swapped camera object carries a stale yaw for a frame or two, BG3's vector points somewhere else for those frames.
- Vanilla hides that: the 16 m/s² carrot moves at most 0.27 m a frame out of 3.75 m, and the steering turns the body slowly. The direct controller follows within a frame (decel 0.04 s, accel 0.06 s), and instant facing snaps the body there and back. The speed dips at the same time.
- In the air RealJump steers from our own camera forward and the physical keys, which matches "not in the air".

**Ruled out (static):**
- The vector's length can't wobble with camera pitch (the rotation is yaw-only).
- No other DLL or Lua code turns the player (the old `character_facing` Lua writer is off).
- No turn clips are in the LocoSkip sets.
- `SetRotation` (`ecl::Character` vtable `+0xE0` = `0x141C65700`) has only two other callers: a teleport `0x141FA9100` and a transform-apply `0x141FAAB30`.
- BG3's steering sets `SteeringComponent.TargetRotation = atan2(−dx, −dz)` through steer state 2 (`0x141BBD650`), from MoveController's state-6 direction (`0x141BEAA60`). It never calls `SetRotation`.

**Fix (build 2):**
- Direction = physical keys on our camera (`move.input = "raw"`, the default now). BG3's vector only gates and gives walk / run.
- The fall-landing clips (`_LOCO_Fall_…_End*`) are left out of LocoSkip, so the jump's landing plays as signed off (cache `locoskip-v2-*`).

**Checks** (native.log, direct mode, always on): `MOVEFEEL check #n <kind>: …`, the first 12 of each kind, then every 50th. A `MOVEFEEL checks so far: …` line every 30 s when a count changed; the totals are also on the summary line and in `mfchk=` on the status line.
- `input off`: BG3's vector more than 25° away from the keys on our camera, with the keys unchanged for 100 ms. This confirms or rules out the cause above.
- `body turned by others`: the body's yaw is more than 20° away from the facing we set the frame before. That would be a second writer.
- `loco clip mid-run`: a Start / End clip plays while you run steadily (≥ 90 % speed, keys unchanged 0.4 s).

## Playtest 2 (2026-10-13): BG3's steering fights instant facing

**Report.** "`dag_move_turn engine` is the clear winner": no flicker with BG3's own steering. A very small twitch of the whole view at every jump take-off (Space), then fluid.

**Log evidence (build 2):**
- `body turned by others`: about **1,650** hits with instant facing (0 with `engine`, which doesn't write). On consecutive frames the body was 33°, 56°, 69° … 113° away from the facing we had just set, later up to 180°.
  - So BG3's steering keeps its own yaw and turns it toward its own target. It writes that yaw back over ours instead of starting from the Transform. Two writers. **[H]**
- `input off`: **1** hit in the whole run. BG3's vector and the keys on our camera agree, so the camera-object theory of playtest 1 was wrong.
- `CAM delta` max while walking: 0.27–0.34 m with instant facing, **0.05–0.12 m with engine**.
- Jump windows (`jump=1`) in engine mode: 0.10–0.29 m.

**Decision:** `move.turn = "engine"` is the default (DECISIONS 2026-10-13). `move.input = "raw"` stays: it's what the jump steers with, and it can't flick.

**Jump take-off twitch (build 3):**
- **Suspect:** at take-off the run's End clip starts under the jump's ascend clip, and direct mode plays End clips at ×5. **[L]** The `loco clip mid-run` check also fired often while running (1–5 hook calls at a time), so these clips do run around the gait.
- **Change:** the DLL pauses the ×5 while a jump is in the air (`g_jump.active` in `Pov.cpp`), so take-off and landing blend at ×1 as when the jump was signed off.
- **New logs:**
  - `JUMP takeoff seq=… head step max …m in the 250 ms before, …m in the first 300 ms (at +… ms); move direct|vanilla`, one per jump. Comparing it with a jump in `!dag_move_mode vanilla` shows whether direct mode adds anything.
  - `MOVEFEEL: the WASD controller ran N frames during the last jump`. No line means it doesn't run under a real jump.

## Playtest 3 (2026-10-13): jumps cut off mid-air

**Report.** Movement fluid. The take-off flicker is still there ("almost seems like the terrain flickers", very quick, at the start of the jump). Some jumps don't go through or stop on small terrain. Question: can players get on top of terrain their jump reaches (a rock at the beach)?

**Log evidence (53 jumps, all direct mode, none in vanilla):**
- **11 jumps have no `RJUMP end` or `landed early` line at all.** All 11 were running jumps (3.2–4.5 m/s); none of the 8 standing jumps was cut off.
  - The falling state left the movement machine mid-air, and RealJump never noticed. It stayed "active" until the next jump.
  - These are the jumps with the big take-off steps, **0.07–0.36 m at +66–90 ms** (`JUMP takeoff`). That is the body snapping back to the ground: the "terrain flicker", and the jump not going through.
- `MOVEFEEL: the WASD controller ran 98–188 frames during the last jump`: BG3's MoveController keeps issuing MoveTo requests under a real jump while the keys are held.
  - RealJump counts 40–90 `re-seeds` per running jump. The jumps without the controller have 1.
- A smaller first-frame step remains on most jumps: 0.02–0.13 m at +10 ms, and 0.36 m on three standing jumps. That's a pose change at take-off (the jump clip's first pose). Whether vanilla has it too isn't measured yet.

**Changes (build 4):**
- **Controller off while airborne.** While RealJump steers (`realjump::Active()`), the direct controller's Update returns 0 without running BG3's, as BG3's own start-delay frames do (every path of `0x14425F2C0` returns `al = 0`). The velocity is kept for the landing. Log: `MOVEFEEL: the WASD controller sat out N frames of the last jump`.
- **Interruptions noticed.** `realjump::Active()` checks that its falling state is still on the movement machine (layer 1, `machine + 0x40`), polled every frame from `MeasureFrame`. If not: `RJUMP interrupted seq=… at u=… (the falling state left the movement machine)`, and the jump is over. Before, a cut-off jump stayed "active", and a later fall off a ledge with the same state object would have been steered by it.
- Vanilla mode is unchanged: BG3WASD's controller still runs under a jump there.

**Standing on top of terrain the jump reaches: not built, needs a decision.**
- The air part already lands on physics geometry: the engine's falling ground probe ends the jump `on something`, for example at y = 1.13 and 1.28 m.
- Walking afterwards is MoveTo on BG3's AI nav grid. A rock top that isn't walkable on the grid can't be walked on or pathed from, and the server's path replay only knows grid positions.
- Allowing it means an **off-grid walk mode**:
  - our own ground-following on the physics surface (RealJump's sweeps) while off the grid, falling off at the edges;
  - our own server sync of that position (raw position writes never reach the server, [real-lift.md](real-lift.md) Q3);
  - and a rule for enemies, who can't path up there.
- This is option C of this spike, rejected for walking, so it goes against DESIGN.md's "everything else stays the engine's". It needs the developer's go-ahead and a spike first.

## Baseline and result (fill from the playtest, [playtest/move-feel.md](../playtest/move-feel.md) step 11)

| Metric | Vanilla (BG3WASD) | Direct | Goal |
| --- | --- | --- | --- |
| Start: 90 % speed | – | – | 50–80 ms |
| Start: first motion | – | – | ≤ 1 frame |
| Stop: time | – | – | ≤ 50 ms |
| Stop: slide | – | – | ≈ 0 |
| Reverse (W→S) | – | – | "same frame" (≈ accel + decel) |
| Strafe change (W→D) | – | – | "same frame" |
| Corrections in 60 s walking | – | – | 0 |
| Drift, matched, moving (max / avg) | – | – | < 0.1 m |
| Drift, standing | – | – | ≈ 0 |

## Open questions (in-game)

1. **Facing.** Answered by Playtest 2: they fight, so `engine` is the default. For a faster body turn later, raise BG3's own turn rate instead of writing the rotation: the steering's `field_18` multiplier, which `0x141BBD650` sets to 1.0 every frame.
2. **Re-pathing.** Does the MoveTo re-path latency (a new path whenever the target moves more than 2 cm) delay starts or reversals by a frame? The metrics show it.
3. **Server side.** Does the server's MSMoveToSync keep up with instant speeds? Matched drift and lag should stay under 0.1 m / ~1 frame in single player.
4. **Locomotion clips.**
   - Are the Start / End clips found for every race / body type (LocoSkip log)?
   - Does ×5 look right, or should they be skipped outright?
   - Does the blend go straight to the run cycle now that `Movement.Speed` is the target?
5. **Input.** Build 2 moves on the physical keys (see Playtest 1). Do the `input off` checks confirm BG3's vector was the one that flicked? Does the 120 ms gate still release cleanly in chat?

## Body facing from the camera (2026-10-13, static Ghidra, `bg3_dx11.exe`)

Developer: "rotating the camera in the air also rotates the character model", and "if not jumping, rotating the camera should rotate the character if past 30 degrees".

**BG3's steering machine** (`ecl::Character+0x80`) **[H]:**
- `0x141BBD130(machine, type)` returns its state of a type, creating it if needed. The pointers are at `+0x00` (type 2), `+0x08` (3), `+0x10` (4), `+0x18` (5) and `+0x20` (**6, look-at**). The look-at state is 0x30 bytes, vtable `0x1456508A0`.
- The active state is at `+0x38`; state 2 (turn to `SteeringComponent.TargetRotation`) runs below it at `+0x30`.
- **Push `0x142006580(_, machine, _, state)`:**
  - if the active state has the same type, it calls Continue (slot 3) and stops;
  - otherwise CanExit (slot 5), Exit (slot 6), set `+0x38`, counter into `state+0x14`, Enter (slot 2).
  - Pattern `48 89 6C 24 10 48 89 74 24 18 57 48 83 EC 20 48 8B 7A 38 49 8B F1 48 8B EA 48 85 FF 74 ?? 4D 85 C9 74 ?? 48 8B 07 48 8B CF 48 89 5C 24 30 FF 50 08` (unique). `0x1420064B0` shares the first 28 bytes: it is the movement machine's push (counter at `+0x10`).
- **Look-at set `0x141BEAA10(state, dir)`:** `state+0x18 = normalise(dir.x, 0, dir.z)`.
- **Look-at Update `0x141BEAA60`**, every frame while the direction is non-zero:
  - yaw = `atan2(−dx, −dz)` → `0x141BBD650(state 2, yaw, 1.0, 0)` (TargetRotation; 1.0 = the turn-rate multiplier);
  - pushes state 2 into `+0x30`;
  - sets `+0x10 = 1` when the direction moved more than about 25° from `+0x24`, most likely the sync of message 0x24.
- **The WASD MoveController** (`0x14425F2C0`, `0x14426001A..0x14426004A`) does exactly this every moving frame: GetState(6), look-at with the step direction, push.

**Built (build 11), `MoveFeel.cpp` `Facing()`:**
- Runs every frame from the camera hook, in direct mode with first person live. It points the look-at state along the camera's forward (direction write, then push if it isn't active). BG3's steering then turns the body at its own rate, with no second writer, and the rotation syncs like a walk's facing.
- **In the air** (`realjump::Active()`; the WASD controller sits out jumps, so nothing else writes): every frame. Data `move.face_air`.
- **Standing still** (no WASD held, measured speed ≤ 0.3 m/s): once the camera is more than `move.face_idle_deg` (30°) off the body, until it is within 4° (or 1.5 s, logged).
- **Moving on the ground:** untouched; the controller's own look-at faces the way you move.
- **The body's visible front is the Transform's local −Z** (playtest 10, from the log): walking forward with BG3's facing, then stopping, read as 180° off by `QuatYaw` (+Z). Build 11's self-check took that for a wrong look-at sign and flipped it, which turned the body around in the air and standing. Build 12 measures the facing as `QuatYaw + 180°`, keeps the look-at direction = the camera forward (+1, as the static reading said; the air turns before the flip were already right), and only logs a turn that ends facing away. **[H]** Instant facing (`move.turn instant`, `SetYaw(atan2(move dir))`) used +Z too, so it most likely faced the body backwards. That may be part of playtest 2's "body turned by others" fight; to check before that knob is ever used again.
- **Logs** (native.log): `MOVEFEEL: steering push at rva …`, `FACING: idle turn #n done, a deg -> b deg in N ms`, `FACING: air: the body followed the camera for N frames, at most N deg behind`, `FACING: couldn't point BG3's steering …`.
- **Thread:** the camera hook, the same place RealJump::Start pushes movement states from (stable since 2026-10-10).
