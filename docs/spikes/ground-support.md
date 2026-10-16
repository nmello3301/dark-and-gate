# Spike: standing on what the jump reaches (ground support)

**Date:** 2026-10-13. **Build:** BG3 Patch 8, `bg3_dx11.exe`, static analysis only (Ghidra). **Decision:** DECISIONS 2026-10-13, "You can stand on what your jump reaches".

> **Status: dropped (2026-10-13).** The developer had all ground-support code removed after builds 5–7 made jumping feel worse. It is now a known limitation (DESIGN, Campaign compatibility). This note stays as the research record.
>
> What came out of it and stays:
> - the jump's **sync guard** (Playtest 5: the server's flag-0x20 reset; it removed the take-off flicker);
> - the RealJump diagnostics (`RJUMP exit … callers`, `RJUMP interrupted …`);
> - the MoveFeel check `moving off the keys`.

Confidence tags: **[H]** read in the code, **[M]** inferred from the code and the logs, **[L]** a guess to check in-game.

## Question

Playtest 4 (developer): "We should be able to stand on rocks, just stay up. Have the hitbox for this be around the character's feet, a rectangle extruded sideways … keep it centered on character z axis. Currently rocks are super glitchy, we are partially going into them."

## How BG3 keeps a character on the ground

From [real-lift.md](real-lift.md) Q1–Q2, plus this spike:

- **Walking (`MSMoveTo`)** follows a nav path on the AI grid. It never lifts a character onto a physics surface above the grid. Walking onto a rock's edge (grid-walkable, rock mesh above it) leaves the feet inside the rock. **[H]**
- **The fall checks** (`ShouldFall` `0x1411956D0`, from MSIdleSystem and MSMoveTo) ask physics only when the character is above the grid by more than their threshold. They then ask `GroundProbe`. **[H]**
- **`GroundProbe(out, aiGrid, scene, pos, radius, extraUp)` `0x141196C70`** **[H]**:
  - It sweeps **one sphere down the character's centre**, from `pos.y + max(2·radius, extraUp)` to 0.5 m under the grid floor, through the scene vtable `+0x50` with mask `0x8100080`.
  - Output: `out = { x, groundY, z, byte @+0xC }`.
    - The byte is 1 (and the rest zero) when the grid has no cell there.
    - Otherwise `groundY` = the hit point's Y (sweep result `+0x10`; the result is normal `+0x00`, point `+0x0C`, distance `+0x18`, `FLT_MAX` = no hit), or the grid height if nothing was hit.
  - Prologue `48 8B C4 55 53 56 57` (7 whole instructions, no RIP-relative operand).
  - **Verified in-game 2026-10-15** (the uphill jump fix, RealJump.cpp `FollowSlope`): the falling Update's probe answer `out + 4` is the ground under the jump; uphill jumps logged the floor rising up to +1.93 m along it.
  - Callers: client `0x141195788` (ShouldFall), `0x141BF0281`, `0x141BF02C0`, `0x141BD7480` (the falling Update), `0x141BF1912`; server `0x14305F7BA`, `0x14305F7F9`, `0x1430605D0`, `0x1430630FA`, `0x1430632D1`, `0x143064209`.
- **So:**
  - a character whose centre is past a rock's edge falls off it;
  - a jump lands only where the centre sphere touches;
  - nothing ever lifts a walking character onto a rock.
- **Client movement states** (machine = `ecl::Character + 0x78`):
  - MoveTo is cached at `+0x18` (vtable rva `0x5650940`, Update `0x141BEE2C0`);
  - Idle is cached at `+0x28` (vtable rva `0x5650988`, Update `0x141BF0D50`);
  - layer 1 is at `+0x40`;
  - a state's `+0x08` is its machine. **[H]**
- **`SetTranslate`** = `ecl::Character` vtable `+0xD8` (`0x141C655C0`, `(character, vec3*)`). It is the same call MSMoveTo moves a character with (`0x141BEEFEB`). **[H]**

## What the DLL does (`Hooks/GroundSupport.cpp`)

Only for the WASD character, only in the client physics scene, only while first person is live, `move.ground.support`:

1. **Probe detour.** An entry detour on `GroundProbe`, found through RealJump's falling-Update call, its bytes checked.
   - It runs when the scene is the client's (learned from the falling Update's call) and the probe's position is within 0.35 m of our character.
   - It then also sweeps the **four corners of the foot box**: `foot_box_w × foot_box_l`, 0.30 × 0.40 m, centred on the character's vertical axis and turned with its body; spheres of 0.06 m.
   - Each sweep runs from `step_up_m` (0.45 m) above the feet down to the engine's own answer. The highest corner hit replaces the engine's floor when it is higher.
   - Effects:
     - **standing:** you stay up while any corner is on something;
     - **jumping:** a jump lands on the box;
     - **plain terrain:** unchanged, because ShouldFall only asks physics above the grid.
2. **Step-up.** The client MoveTo and Idle Updates (vtable slot 4) are wrapped. After BG3's own Update, a surface under the box's **centre** between `step_min_m` (0.06) and `step_up_m` (0.45) above the feet lifts the character onto it (`SetTranslate`).
   - Only the centre counts: on a slope the uphill corner touches terrain above the feet.
   - The grid already carries you along terrain.
   - `step_min_m` keeps the small differences between grid and terrain out.
3. **Take-off.** On a real jump's first steered frame (game thread), a take-off from inside a surface (centre sweep) starts on top of it. Otherwise the falling state's first ground probe finds that surface above the feet and the jump "lands" on its second frame (playtest 4: `landed early … at u=0.01`).

**Logs (native.log):**
- `GROUND: GroundProbe entry detour …` at load;
- `GROUND: MoveTo / Idle Updates hooked …` once the character is known;
- `GROUND: ON|off (foot box …)`;
- `GROUND step-up #n (walk|standing): … m onto …`: the first 8, then every 100th;
- `GROUND so far: N probe answers raised …, N step-ups`: every 30 s when they changed;
- status line `gs=on lifts= steps=`.

**Knobs:**
- `data/movement.lua` move.ground: support, foot_box_w, foot_box_l, step_up_m, step_min_m;
- `!dag_ground on|off|status`.

## Limits and risks

- **The server isn't told the new floor [M].**
  - A position written on the client never reaches the server ([real-lift.md](real-lift.md) Q3). The server's copy follows the synced path and its own falling, so on a rock it may stand at the grid height under you.
  - Effects: our server-side hit checks and enemy line of sight see you lower. In co-op, the others may see you lower.
  - Fix later if it shows: send the lift like `JumpLift` does during jumps.
- **Walking on top [L].** On a rock top that isn't on BG3's walkable map, WASD's move target is corrected toward walkable ground. Pressing a key may walk you toward the nearest walkable edge (and off it) rather than straight ahead. Standing, turning and jumping work.
- **Enemies** path on the grid: they can't climb up to you. Melee may not reach; archers and casters still can.
- **Props** up to 0.45 m (crates, steps) can be walked onto.

## Playtest 6 (build 6): the flicker is gone; the ground code was idle

**Report.**
- `!dag_jump_sync_guard` removed the flicker ("worked perfect").
- Rocks behave exactly as before: you sink to the waist on the beach rock.
- Walking and jumping on the beach, the direction sometimes changes completely after stepping on debris ("never happened before").

**Log evidence:**
- **Sync guard:** the server set flag 0x20 at 61–79 ms after every take-off, and back about 1.33 s later (sometimes again at ~1.56–1.78 s). Every reset inside the window was skipped. `RJUMP exit` only appears while the guard was switched off for the comparison. **[H]**
- **Ground code:** the status line ended at `gs=on lifts=0 steps=0 walls=0`. It never changed the height or held a step back all session.
  - So neither it nor the sync guard (which only acts during jumps) caused the direction changes.
  - One jump landed at y = 1.25 (the rock top), from a take-off at y = 1.07. There is no height log after it.
- **Most likely mechanism for the sinking [M]:** once you stand on the rock top, BG3's MoveTo / Idle step puts you back at the walkable map's height under the rock (ground level, waist deep). Build 6 only lifted you for surfaces up to 0.45 m above the feet.
- **Most likely mechanism for the direction change [L]:** jumps now complete instead of being cut off at 60 ms, so you land on debris more often. Off BG3's walkable map, the MoveTo path to `pos + carrot` heads for walkable ground, wherever that is.

**Build 7:**
- **Hold the floor (`HoldFloor`).**
  - The feet are read before BG3's MoveTo / Idle Update. If the Update dropped them more than 0.20 m in one frame (not a fall, not a teleport), and the foot box (centre and corners) still finds a surface within 0.08 m of the old height, the character is put back on it.
  - Logged: `GROUND hold #n …`, or `GROUND drop #n …` when nothing was under the box.
  - Only big one-frame drops: on slopes the engine lowers you a few cm a frame.
- **Knee sweeps counted:** `walls=hits/sweeps` on the status line, and in `GROUND so far`. That shows whether the side sweeps run and hit at all.
- **New MoveFeel check `moving off the keys`:** the real movement (over ≥ 0.1 s) is more than 60° away from the keys held steady for 0.3 s, above 1 m/s. Logged with the position.

## Playtest 5 (build 5): what ends the jumps, and why the box came off in the air

**Report.**
- The flicker is still there.
- The foot box during the jump is "really bad": it clipped on the smallest rocks, and more jumps failed.
- Standing on a rock: "phased down to my waist".
- Enemies not climbing after you is fine. Later they get height awareness and use spells and arrows on you up there.

**Log evidence:**
- **9 jumps "landed" on their 2nd frame** (`landed early … u=0.01`), all near the rock.
  - The corners found the rock face within 0.45 m above the feet, so the engine's landing test ended the jump at once.
  - **Change:** no corners while our character falls (layer 1 = falling, any fall). The box holds you up where you stand. A jump lands where its centre touches.
- **Nearly every other jump was hit at u ≈ 0.05 (10–14 frames).** The stack is the same every time: `RJUMP exit … callers 0x1BD7190 0x1FE2224 0x1FDE05E 0x4034BA7 …`. **[H]**
  - `0x141BD7190` is inside **StopMovement** `0x141BD6FF0`.
  - It is called with force 1 from **`0x141FE20D0`**. That function:
    - clears the character-light block at `character + 0xA8` (`+0x48`, `+0x6C`, `+0xC4` and three entries from `+0x18`);
    - optionally calls `+0xA0`'s vtable `+0x40`;
    - exits the action layer (`character + 0x70`, `+0x38`);
    - force-stops the movement machine;
    - tail-calls the steering stop `0x141BBD500(steering, 1)`.
  - It is called from the character sync handler `0x141FDCC60` at `0x141FDE059`, only when:
    1. the message says character flag **0x20** changed (message dword bit 1; the new value is byte `+0x5E` bit 1);
    2. the client flag differs (`character + 0x18` bit 5; set / cleared by `0x141C65480` / `0x141C65520`);
    3. the character has **HasCharacterLight** (`0x2000`, SE's `ecl::CharacterFlags`).
  - The type-7 movement state's Update (`0x141BF2DE0`) also sends the character-light event only while flag 0x20 is clear.
  - The engine's own fall check often re-pushed the fall right after, so many jumps survived with a hiccup. In builds 3–4 the jumps where it didn't were the "cut-off" ones.
- **Cause [M]:** the server changes that flag on you about one round trip after take-off. The only server action at that moment is the jump clip: `PlayAnimRequest` → `PurgeOsirisQueue`, `FlushOsirisQueue`, `Osi.PlayAnimation`, in vanilla and direct mode alike.
  - The light reset on that path is the likely **take-off flicker**: the world re-lit for a moment, while the sun shadow stays.
  - Not proven: `!dag_jump_play_anims off` would show it (not run yet).
- **The waist-deep sinking:** with the jumps dying, the walk took you into the rock's footprint. BG3's walkable map allows it there, and the step-up (≤ 0.45 m) can't lift you onto a taller face. Only 1 step-up was logged.

**Changes (build 6):**
- **Sync guard (`RealJump.cpp`).** An entry detour on `0x141FE20D0`: for our character, from take-off until 0.6 s after the jump's planned end, the reset is skipped. The flag itself still changes. Pattern `41 56 48 83 EC 40 48 8B 82 A8 00 00 00 4C 8B F2 48 89 5C 24 50 B9 03 00 00 00`, unique; entry `push r14; sub rsp, 40h`.
  - Logged: `RJUMP sync #n: the server set flag 0x20 = … ms after take-off … skipped`, and `… reset runs` outside jumps.
  - Knobs: `data/movement.lua` jump.sync_guard, `!dag_jump_sync_guard on|off`.
- **No foot box in the air** (above).
- **Faces taller than a step hold you back when walking** (`WallCheck`).
  - After BG3's step, a 0.10 m sphere is swept at knee height (feet + step_up_m + 0.12 m) from where you stood to the new spot plus 0.25 m.
  - A hit slides the step along the face (the hit normal, result `+0x00`), or takes it back.
  - Logged: `GROUND wall #n …`; `walls=` on the status line.
  - Low rocks (≤ step_up_m) still lift you; taller ones need a jump.

## Playtest 4 findings on the jump (same round)

- **Cut-off jumps:** 5 of 47 jumps were cut off at **u ≈ 0.04 (9–10 frames, ~60 ms)** with 0 re-seeds, so the frozen ground controller is ruled out. All took off from raised ground (y 0.73–0.99: the slope by the beach rock and two other spots).
  - Something takes our falling state off layer 1 about 60 ms after take-off. That is about one server round trip after the jump clip's request (`PlayAnimRequest` → server `Osi.PlayAnimation`, after `PurgeOsirisQueue` / `FlushOsirisQueue`).
  - The client's teleport system `0x141CA5BD0` → `0x141FA9100` (rotation, position, then `StopMovement(machine, 1)`) is one engine path that does that.
  - **Build 5 logs the culprit:**
    - `RJUMP exit seq=… at u=… (callers rva …)`, a stack from a hook on the falling state's Exit (vtable slot 6);
    - `RJUMP interrupted … now layer 0 type N, layer 1 type N`.
- **The take-off flicker:** in vanilla and direct mode alike, at every jump. The world looks re-rendered for 10–50 ms, while the character's shadow stays steady. So it is the jump itself, not the WASD controller. Candidates **[L]**:
  1. The server-played jump clip reaching the client 50–60 ms after take-off.
  2. Our falling state replacing the layer-1 type-7 state, whose Update `0x141BF2DE0` sends the character's per-frame event `0x2E` through `0x141C6AAB0` (the "character light" state in real-lift.md).
  - **Bisect, no build needed:** `!dag_jump_play_anims off` (no jump clips at all) and `!dag_jump_mode visual` (no falling state). Whichever stops the flicker names it.
