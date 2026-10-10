# Player WASD ground speed: native lever (static RE)

**Status:** static RE only, unverified in-game. **Confidence:** high on the input → speed path inside the client `MoveController` (instruction-level, and the numbers check out against BG3WASD's 0.3 walk default). Medium on what happens downstream of the MoveTo request (the consumer of the explicit speed was not traced to the integrator). Low on MP authority (not traced at all).
**Date:** 2026-10-09 · **Binary:** `bg3_dx11.exe` Patch 8 (image base `0x140000000`) · Ghidra (MCP, read-only decompile; the project was still auto-analysing, and four degenerate 1-byte functions were re-created so they would decompile) plus capstone/pefile on the exe bytes. No debugger, no game process.

All addresses are VAs at image base `0x140000000`. Subtract the base to get the RVA (`0x14425f2c0` → RVA `0x425f2c0`).

## 1. How BG3WASD applies WalkSpeed

- `OverrideMovementInputHook` replaces the four `call GetInputValue` sites (`0x1440efb10`) inside `GetMovementInputWorldVec` (`0x14425e7f0`). Those sites read input commands `0xA0`, `0x9F`, `0x9D` and `0x9E`, which are the forward, back, left and right axes.
- After calling the original, the hook multiplies the returned `Vector2` by `settings->walk_speed` when `walking_toggled ^ walking_held`.
- `walk_speed` is bound as `config.Bind<0.0, 1.0>(walk_speed, 0.3)`, so it is clamped to the range 0..1.
- **Why it can't go above 1:**
  - `GetMovementInputWorldVec` forms the 2D vector `(fwd−back, left−right)` and normalises it to length 1 when it is longer than 1.0 (constants `1e-7` at `0x14591ca54` and `1.0` at `0x14591cde8`). It then rotates the vector by camera yaw into a world vec3.
  - Downstream, the input magnitude is clamped again to 0.1..0.9 (see §2).
  - So scaling the input can only slow the character down, within the template's Stroll..Run band.
- **Why it can't be reached from outside:** the state (`State::walking_*`) and the setting live inside BG3WASD's own DLL. It has no exports and no IPC; the setting comes only from its INI/MCM. Our DLL can't drive it. Hooking the same `call` sites ourselves would chain with BG3WASD's hook, which is order-dependent and fragile.

## 2. Input → speed path (client, `ecl` side)

`GetMovementInputWorldVec(out vec3*, short playerId, bool)` is `0x14425e7f0`. It has three callers, all methods of one vtable at `0x14591a158`. An ASCII tag right before the vtable reads **`MoveController`**:

| VA | vtable slot | Role (inferred) |
| --- | --- | --- |
| `0x14425ec30` | `0x14591a190` | "Should WASD start?" It polls the four axes. If the world vec² ≥ 0.01, it calls `0x141cab8e0` (start move; this checks that the resolved speed type Walk is > 0 via `0x141bf6ac0`). |
| `0x14425f160` | `0x14591a220` | Enter/refresh. It writes the input into the per-entity WASD state component (see below). |
| `0x14425f2c0` | `0x14591a228` | **Per-frame WASD update.** `param_1` = controller (`+0x68` = `ecl::Character*`, `+0x100` = byte passed to the input reader). `param_2+8` = dt. |

Inside `0x14425f2c0`:

1. `tmpl = 0x141c6b540(character, …)` at **`0x14425f428`**. This resolves the character's effective `CharacterTemplate*`: a transform/polymorph override if one exists, otherwise `ecl::Character+0x58` (`Template`). The function then reads:
   - `xmm14 = tmpl+0x590` = **MovementSpeedStroll**
   - `xmm12 = tmpl+0x5a0` = **MovementSpeedRun**
2. `ws = 0x140705ea0(world, entity)` is the per-entity WASD state component. Layout, as far as this function shows it:

   | Offset | Contents |
   | --- | --- |
   | `+0x00` | input magnitude (0..1) |
   | `+0x04..+0x0C` | normalised direction |
   | `+0x10..+0x18` | raw world input vec |
   | `+0x1C..+0x24` | step direction |
   | `+0x28..+0x30` | computed target position |
   | `+0x34..+0x3C` | "carrot" offset ahead of the character |
   | `+0x5C..` | look-at |
   | `+0x80` | timer |

3. **Speed is continuous, not a walk/run switch.** At `0x14425f944..0x14425f99b`:

   ```
   t     = (clamp(ws.mag, 0.1, 0.9) − 0.1) / 0.8      ; consts 0.9 @0x14591cda8, 0.8 @0x14591cd88
   speed = Stroll + t · (Run − Stroll)                 ; result in xmm7
   ```

   Check against the defaults (Stroll 1.4, Walk 2.0, Run 3.75): BG3WASD's 0.3 gives t = 0.25, so speed = 1.99 ≈ MovementSpeedWalk. That is why its default "walk" looks right. Full stick gives 3.75, which is Run.
4. The carrot offset `ws+0x34` is moved toward `speed · dir` by at most `16 · dt` m per frame. `0x1442603b0` (called at `0x14425fae5`) then path-corrects the target against the nav grid and writes two outputs:
   - the target position to `ws+0x28`
   - **`|carrot|` (the commanded m/s) to its 5th arg**. Near walls this is scaled by `0.1 + 0.9·k`.
5. A speed request `{u8 1, u8 1, float speed, u8 kind=1}` is built at `rbp+0x18` and sent to `0x141bed4c0(moveTask, &moveParams, 400, 1, &req)` at **`0x14425feb9`**. The move task lives on `ecl::Character+0x78` (`AiMovement`, a MovementMachine); its constructor is `0x141bed320`. The request is stored at `task+0xb2..+0xb8`. The task's "current" copy is at `task+0x12c`.
6. On task (re)start (`0x141bedd40` / `0x141bee030`), the speed request is resolved by `0x141bf6e60(…, task+0x12c)`:
   - `kind == 1`: the explicit float is returned **unchanged**.
   - `kind == 0`: a template speed is chosen by enum. 1 = Stroll `+0x590`, 2 = Walk `+0x598`, 3 = Run `+0x5a0`, 4 = Sprint `+0x5a8` (Dash is at `+0x5b0`). The enum matches SE `MovementSpeedType`.

   The result is written by `0x144203c10` into a component float at `+0x44` (unidentified component; it fires change listeners).

**Multipliers:**

- `ecl::Character::SpeedMultiplier` (`+0x148`, which matches the SE layout) is applied only in the sibling resolver `0x141bf6ac0`. That resolver also clamps to `CanMove.SpeedLimit` and applies a status-driven slow-down. Its only caller is `0x141cab8e0`, the "can start moving" check.
- The WASD explicit-speed path (`0x141bf6e60`) does **not** apply `SpeedMultiplier` and does **not** clamp to `SpeedLimit`.
- Whether the component `+0x44` consumer multiplies or clamps again is **not traced**.
- `esv::Character::GeneralSpeedMultiplier` is server side. Nothing on this client WASD path touches it.
- *Guess:* WASD movement for the local player is simulated on the client (the whole chain above is `ecl`), and the server receives positions. Not traced.

## 3. Candidate levers (ranked)

| # | Where | Pattern (unique in Patch 8) | What to do | >1? | Scope | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| **1** | Template fetch in `MoveController` update, call at **`0x14425f428`** | `E8 ?? ?? ?? ?? F3 44 0F 10 B0 90 05 00 00 F3 44 0F 10 A0 A0 05 00 00` (offset 0) | `write_call<5>` to a thunk with the same signature: `(rcx=char, rdx, r8, r9, byte [rsp+0x20])`. Call the original. If `char` is our player, return `shadow − 0x590`, where `shadow[0]` = our Stroll and `shadow[4]` (+0x10) = our Run. For walk, set Run to the walk speed (or Stroll = Run = walk); for run, scale Run. The returned pointer is used only for those two loads (rax is overwritten at `0x14425f43f`). | Yes | Only the WASD-driven character on this client | Low. A single call site, same style as BG3WASD's hooks. It does not touch the shared template, and click-to-move is unaffected. |
| 2 | Lerp result, **`0x14425f984`** (`speed` in xmm7 after `0x14425f99b`) | `F3 41 0F 5C FB F3 0F 5E 3D ?? ?? ?? ?? F3 45 0F 5C E6 F3 41 0F 59 FC F3 41 0F 58 FE` | A mid-function detour after `addss xmm7,xmm14` (at +0x1C = `0x14425f9a0`, `0F 28 CF` + `F3 41 0F 59 4E 0C`; needs a 9-byte stolen-bytes trampoline) to `mulss xmm7, factor`. | Yes | Same as #1 | Medium: trampoline. Gives no more than #1. |
| 3 | MoveTo request, **`0x14425fea0`** (call at +0x19 = `0x14425feb9`) | `41 B8 90 01 00 00 48 8D 45 ?? 48 89 44 24 20 41 B1 01 48 8D 55 ?? 48 8B CF E8` (offset 25) | `write_call<5>`. Before calling the original, scale `*(float*)(req+4)` (the 5th arg) when `req[8]==1`. | Yes | Same as #1 | Low. The carrot/lookahead stays at the unscaled speed (it is just the target distance), so steering feel may differ slightly. Good fallback, or stack it with #1 for a final multiplier. |
| 4 | `CharacterTemplate` fields via `ecl::Character+0x58`: `+0x590` Stroll, `+0x598` Walk, `+0x5a0` Run, `+0x5a8` Sprint, `+0x5b0` Dash | none (data write) | Write the floats (or via SE Lua, if `Template.MovementSpeedRun` is writable; **guess**, untested). | Yes | **Every character that shares that template object** on this client. Also affects click-to-move. | Medium-high: templates may be shared (generic player races). Server-side templates are separate. |
| 5 | `ecl::Character::SpeedMultiplier` `+0x148` (SE `ClientCharacter.SpeedMultiplier`?) | none | Write via SE Lua or the DLL. | Yes | One character | **Probably no effect on WASD.** It is applied only in `0x141bf6ac0`, which this path doesn't use for its speed. Cheap to test in Lua first. |

The function entry points, for hooking whole functions:

- `MoveController::Update` `0x14425f2c0`: the prologue `48 8B C4 48 89 58 10 48 89 70 18 48 89 78 20 55 41 54 41 55 41 56 41 57 48 8D A8 68 FE FF FF` is **not unique**: it also matches `0x141c88ed0`. Use the vtable slot `0x14591a228` or the call-site patterns above instead.
- explicit-speed resolver `0x141bf6e60`: `48 83 EC 48 0F B6 42 04 84 C0 0F 85 ?? ?? ?? ?? 48 8B 41 10` (unique).

**MP:** levers 1–3 run in our client DLL on each player's machine and affect only the character that player drives. That is the same model under which BG3WASD's walk works in co-op (*believed*, not verified here). If the server validates or simulates player movement speed, it could rubber-band. That is the main in-game question. Server-side speed (companions on Brawl AI, NPCs) would need `esv` levers; those are not covered here.

## 4. Reading the actual ground speed (for animation sync)

In order of preference:

1. **Position delta per frame.** Read the character's world transform each frame (we already read positions for the camera/bones) and take |Δpos.xz| / dt. This is ground truth, whoever moved the character. Recommended.
2. **Commanded speed:**
   - Read |`ws+0x34..+0x3C`| (the carrot length, which is exactly the m/s fed to the MoveTo request) from the WASD state component that `0x140705ea0(world, entity)` returns.
   - Or capture the float in lever #1/#3's thunk; that is free and already in our hook.
   - This is the target speed and leads the real speed (acceleration, `MovementAcceleration` at `+0x588`).
3. **SE `eoc::MovementComponent`** (`entity.Movement.Speed` / `.Acceleration` / `.Direction`, offsets `+0x10` / `+0x0C` / `+0x00`). It may be cheap to log from client Lua. Whether the local player's client updates it during WASD is **unverified**.

## 6. Built (2026-10-09, movement round)

Lever **#1** is in `tools/native/src/Hooks/MoveSpeed.cpp`: the call at the template-fetch site is patched at DLL load (`InstallFarCall5`). The hook calls the original and, when a multiplier is active, returns a private block whose `+0x590` / `+0x5a0` hold:

- `Run' = Run × runMult`
- `Stroll'` chosen so BG3WASD's walk (lerp `t` from its `WalkSpeed`, read from `NativeMods\BG3WASD.toml`) lands on `naturalWalk × walkMult`: `Stroll' = (W − t·Run') / (1 − t)`, clamped to ≥ 0.05 (logged once when the walk is limited by a much faster run).

Lua (`Client/Movement/Movement.lua`) sends the effective multipliers (`move_walk`, `move_run` in `native-pov.txt`). The DLL's status line reports `move=`, `tmplStroll=`, `tmplRun=`, `walkT=`, `outStroll=`, `outRun=`, `moveCalls=`. Locomotion sync sets the character's play rate to the current gait's multiplier through the PlayAnimation-node hook; `rateHits=` on the status line shows whether locomotion clips go through that hook at all.

## 5. Open questions (in-game)

1. Do levers #1/#3 actually change ground speed? Specifically, does the `+0x44` consumer or the integrator clamp to Run, Sprint or `CanMove.SpeedLimit` (in combat, encumbered)? Test with factor 1.5 and 2.0 and log Δpos/dt.
2. In co-op, does the host see the client's faster movement without rubber-banding? Is movement for player-driven characters client-authoritative?
3. Does SE expose a writable `ClientCharacter.SpeedMultiplier` / `Template.MovementSpeed*`? Does writing it change WASD speed (expected: no for SpeedMultiplier)?
4. Is the `ecl::Character+0x58` template object shared between party members (custom characters of the same race)? This only matters for lever #4.
5. Is `eoc::MovementComponent.Speed` live on the client during WASD (for the cheap Lua read)?
6. How does the locomotion blendspace pick walk/run/sprint at speeds above Run? It may need our AnimRate to cover the overshoot.
