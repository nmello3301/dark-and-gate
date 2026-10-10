# Real vertical lift for the jump (static RE)

**Status:** static RE only, **unverified in-game**. Nothing here has been run.
**Date:** 2026-10-10 · **Binary:** `bg3_dx11.exe` Patch 8 (image base `0x140000000`). Tools: Ghidra (MCP, read-only decompile) plus pefile/capstone/numpy scans of the exe bytes (RIP-relative xref scanner, ECS type-name to type-id map built from the `ls::GetTypeName<…>` strings). No debugger, no game process.

All addresses are VAs. RVA = VA − `0x140000000` (`0x141bd7280` is RVA `0x1bd7280`). Patterns were checked for uniqueness in `.text` of this build. Confidence tags: **[H]** instruction-level reading, **[M]** decompiler reading plus inference, **[L]** guess.

## TL;DR

- The client already has an engine state that holds a character off the ground and moves it every frame: the **client `MSFalling` movement state** (type 6). Its Update integrates **`pos = Start + Vel·t + (0, −20·t², 0)`**, with gravity hard-coded at 40 m/s², and writes the real `ls::TransformComponent` through `ecl::Character::SetTranslate`. It ends when a downward ground probe (AI grid plus physics sweep) finds the floor under the current XZ. **[H]**
- Its fields include a **"velocity preset" flag**. With it set, the state launches with whatever start velocity we write, so an upward velocity is a real jump. **[H]**
- WASD walking (`MSMoveTo`) **never changes Y**: it steps XZ and keeps the current Y. When the character is above the ground by more than a threshold, `MSMoveTo` and the idle system hand it to `MSFalling`. A plain transform write is therefore pulled down by the engine within a frame. **[H]**
- When the controlled character enters `MSFalling`, the **client reports the fall's start and velocity to the server once**. The server replays the same parabola in its own `MSFalling` and replicates it to the other clients. A vanilla-parabola jump is therefore co-op visible for free. A custom curve needs the same warp applied on the host and on each client. **[M]**
- **Recommended lever (L1):** enter the client `MSFalling` from the DLL with the velocity-preset flag, and hook its Update (one vtable slot) so our DLL owns the curve, the WASD horizontal motion and a lateral obstacle check. The engine still does the landing probe, the land event and the server report.

## Q1. Where is the controlled character's Y decided each frame (client, WASD)?

**Chain:** `MoveController::Update` `0x14425f2c0` (see [move-speed.md](move-speed.md)) → MoveTo request `0x141bed4c0` into the client `MSMoveTo` state → `MSMoveTo::Update` **`0x141bee2c0`** → `ecl::Character::SetTranslate` **`0x141c655c0`** (ecl::Character vtable `0x1456576a0`, slot **+0xD8**) → `ls::TransformSystem` setter **`0x143c77bd0`**. The setter writes `TransformComponent.Translate` (`+0x10..+0x18`), records the change and fires the translate listeners (old position). **[H]**

- **The XZ step keeps Y.** `MSMoveTo::Update` reads the current translate (`GetTransform` = vtable +0xD0 `0x141c655b0` → `TransformComponent*`, `+0x10`) and steps toward the next path node `path+0x288 → +8 (x), +0x10 (z)`. The direction's Y component is multiplied by 0, and on node arrival the written position is `(node.x, current.y, node.z)` (`0x141beeefc..0x141bef03a`). The server's equivalent (`0x143060a30`) does the same. **[H]**
- **Y changes only through sub-states of the movement machine:**
  - **Falling** (type 6): entered when `ShouldFall` (`0x1411956d0`) says the character is above the ground.
  - **Climbing** (type 5): entered for path nodes flagged as climb links (`0x140fe4870` checks node flag `& 4`; set-up in `0x141bf0050`). Climbing interpolates Y itself. **[H]**
  - Teleports and the unstuck snap (`0x141ca3cf0`, which finds a valid nav position and calls SetTranslate). **[M]**
- **How Y follows gentle slopes during plain walking was not found.** MoveTo, the movement systems and the transform setter don't project Y. It may be small falls (down) plus something unfound (up). **[L]** This matters only for where a landing settles.
- **`ShouldFall(aiGrid, physicsScene, pos, threshold, …, outGroundY*)` `0x1411956d0` [H]:**
  1. `gridY = AiGridHeight(pos)` (`0x140e329c0`).
  2. If `gridY − pos.y < 0` and `|…| > threshold`, it probes physics with `GroundProbe` `0x141196c70`.
  3. It returns true only if the physics floor is also below `pos.y` by more than `threshold`.

  It is called:
  - from `MSMoveTo::Update` every frame (call at **`0x141bee9a2`**), gated by a per-entity flag byte `& 4` from `0x140b1a850` and a physics scene being present;
  - from `ecl::movement::MSIdleSystem` (update `0x141935810`, call `0x14193612b`), which fills `ecl::movement::MSIdleComponent {vec3 pos; bool startFall @+0xC}`. The client Idle state (`0x141bf0d50`) turns that into a pushed `MSFalling`.
- **`GroundProbe(out, aiGrid, physicsScene, pos, radius, extraUp)` `0x141196c70` [H]:**
  - It reads the AI-grid floor under XZ.
  - Then it runs a physics sphere sweep through the scene vtable `+0x50`, collision mask `0x8100080`, radius `radius − 0.0005`. The sweep goes from `pos.y + max(2·radius, extraUp)` down to 0.5 m below the AI-grid floor.
  - It returns the hit Y, or the grid height if nothing is hit.

## Q2. An engine state that keeps a character off the ground: client `MSFalling`

### Client movement machine

`ecl::Character+0x78` (SE `AiMovement`) **[H]**:

| Offset | Contents |
| --- | --- |
| `+0x00..+0x28` | Cached states, filled by `GetState` |
| `+0x38` | **Layer 0**: MoveTo, Idle, MoveToSync |
| `+0x40` | **Layer 1**: Falling, Climbing, type-7 "moved/light" |
| `+0x48` | EntityHandle |

The transaction counter global is `0x145ed576c` (server: `0x145ed9ea8`).

- **`GetState(machine, type)` `0x141bd67c0`** returns the cached state, creating it on first use. Pattern: `48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 48 8B F9 33 F6 4C 8D 0D ?? ?? ?? ?? 83 FA 07 77 3D 48 63 C2 45 8B 84 81 08 6C BD 01` (unique). The cache slot for each type:

  | Type | State | Cache slot |
  | --- | --- | --- |
  | 2 | MoveTo | `[3]` |
  | 3 | MoveToSync | `[4]` |
  | 4 | Idle | `[5]` |
  | 5 | Climbing | `[0]` |
  | 6 | Falling | `[1]` |
  | 7 | type-7 | `[2]` |

- **State vtables** (SE order: dtor, GetType, Enter, Continue, Update, CanExit, Exit, …):

  | State | Vtable | GetType | Enter | Update |
  | --- | --- | --- | --- | --- |
  | MoveTo | `0x145650940` | 2 | `0x141bedd40` | `0x141bee2c0` |
  | MoveToSync | `0x145650608` | 3 | | `0x141be36d0` |
  | Idle | `0x145650988` | 4 | | `0x141bf0d50` |
  | Climbing | `0x145650a50` | 5 | | `0x141bf1520` |
  | **Falling** | **`0x14564f770`** | 6 (`0x14189c8b0`: `B8 06 00 00 00 C3`) | `0x141bd71f0` | **`0x141bd7280`** |
  | type-7 | `0x145650a98` | 7 | | `0x141bf2de0` (character light only) |

- **StopMovement(machine, force)** `0x141bd6ff0` sets layer 0 to Idle and layer 1 to type-7. Each replacement happens only if the current state's `CanExit` (vtable +0x28) is true or `force` is set. **[H]**

### Client `MSFalling` layout

0x58 bytes. **[H]** except where noted.

| Off | Type | Meaning |
| --- | --- | --- |
| +0x08 | ptr | MovementMachine |
| +0x10 | int | TransactionId |
| +0x18 | float | Height (extra fall height, added to Start.y for the fall-height / animation calculation) |
| +0x1C | vec3 | **StartPosition** |
| +0x28 | vec3 | **Velocity** |
| +0x34 | vec3 | Current velocity (Y loses 20·dt per frame; used for the impact sound) |
| +0x40 | u8 | Hold landed: blocks state 2 → 3 |
| +0x41 | u8 | When 0, Enter sets GameplayController(`ecl::Character+0xB0`)`+0x18 |= 0x800000`; Exit clears it |
| +0x42 | u8 | Skips the template threshold calculation; also sent to the server |
| +0x43 | u8 | Fall sound started |
| **+0x44** | u8 | **Velocity preset.** When set, state 0 keeps +0x28 and clears the flag. When 0, it zeroes vx/vz and computes a push-off velocity via `0x140efb1d0` |
| +0x48 | float | **Time t** (`+= dt` each frame) |
| +0x4C | float | Time used for the sound trigger (≥ 0.15 s) |
| +0x50 | u8 | Play fall animation (from `0x141bd7f70`) |
| +0x54 | int | **State**: 0 init, 1 airborne, 2 landed, 3 done |

### `MSFalling::Enter` `0x141bd71f0`

1. Sets ecl::Character `Flags` (`+0x18`) bit **47** (`0x800000000000`).
2. Calls `SetTranslate(Start)`.
3. Applies the GameplayController flag (see +0x41).
4. Resets State, +0x40, +0x43, +0x4C, +0x50 to 0.

Pattern: `48 89 5C 24 08 57 48 83 EC 20 48 8B 51 08 48 8B D9 48 8B 05 ?? ?? ?? ?? 48 8B 52 48` (unique). **[H]**

### `MSFalling::Update(state, GameTime*)` `0x141bd7280`

Pattern `48 8B C4 48 89 70 20 55 57 41 54 41 56` (unique). `dt` = `GameTime+8`. **[H]**

- **Every frame:** `ground = GroundProbe(current pos)`.
- **State 0:**
  1. Resolves the velocity (see +0x44) and copies it to +0x34.
  2. Sets ecl `Flags` bit **48** (`0x1000000000000`).
  3. Fires the fall animation request into `ls::AnimationBlueprintSystem` (`0x141bd83c0`).
  4. Sets State = 1.
- **State 1:**
  1. `t += dt`.
  2. Computes `y = Start.y + Vel.y·t − 20·t²`, `x = Start.x + Vel.x·t`, `z = Start.z + Vel.z·t`. The `−20` is an inline literal: `mulss` with `20.0` here; server `0x14591d394` = −20.0.
  3. If `y > ground.y + 1e-7`, it calls `SetTranslate(x, y, z)` (call at **`0x141bd784c`**; site pattern `48 8D 54 24 40 E8 ?? ?? ?? ?? 49 8B 4E 18 48 8B C1` at `0x141bd7847`).
  4. Otherwise it calls `SetTranslate(ground)`, clears bit 48, sets State = 2 and sends the land event (`0x141bd85f0`).
- **State 2:**
  - If the character is above the ground again, it restarts from the ground position.
  - Otherwise State = 3, unless +0x40 is set.
- **State 3:** pops layer 1.
- **`CanExit`** (`0x141bd71e0`) returns `State == 3`. A fall can't be interrupted by MoveTo or StopMovement unless they force it. **[H]**
- **Exit** (`0x141bd7c10`) clears ecl `Flags` bits 47|48 and the GameplayController flag.

### How a fall is entered

The engine's own push sequence is in `MSMoveTo::Update` at `0x141bee9af..0x141beea5b`. The client Idle Update `0x141bf0d50` is the same pattern. **[H]**

1. `st = GetState(machine, 6)`.
2. Fill the state: `st+0x18 = 0`, `st+0x1C = current pos`, `st+0x28..+0x30 = 0`, `st+0x41 = 0`.
3. Push it into layer 1 (`machine+0x40`):
   - If layer 1 already holds `st`, call `vt[0x18]` (Continue; for Falling this returns true and resets nothing).
   - Otherwise, if layer 1 holds another state, require its `CanExit` (`vt[0x28]`), then call its `Exit` (`vt[0x30]`).
   - Then `machine+0x40 = st`, `st+0x10 = counter++`, `st+0x08 = machine`, and call `Enter` (`vt[0x10]`); clear layer 1 if Enter returns false.
4. Then layer 0 is set to Idle (`GetState(machine, 4)`) by the same protocol.

**Re-seeding hazard [M]:** both pushers (MoveTo's fall check and Idle's `startFall`) overwrite **Start and Velocity** of an already-running fall, but not `t` or `State`. If either runs during our jump, a vanilla Update would jump. A hook that owns the position every frame (L1) is immune. Whether this happens during a vanilla fall depends on the `& 4` gates noted in Q1; it's in-game question 2.

### Other "off the ground" mechanisms (none usable as a lever)

- **BG3's Jump spell flight** is a **projectile**: the character rides an attached projectile. **[M]**
  - `ecl::jump::TrajectoryAnimationStateSystem` (registered around `0x140740dc6`) depends on `ecl::ProjectileManager` and `ls::TransformSystem`, and queries `ecl::Projectile`, `ecl::projectile::AttachmentComponent`, `eoc::jump::StateComponent` and `eoc::jump::InfoComponent`, plus the jump Takeoff/Land one-frame events. The server has the matching `esv::jump::*`.
  - It is destination-based, starts from a spell cast and is server-authoritative. The curve is the projectile's (`Projectile_Jump`); the integrator was not traced. Not a WASD lever.
  - `esv::JumpFollowComponent` / `esv::following::JumpFollow*` is the follower AI that re-casts that jump.
- **`eoc::GravityDisabledComponent` / `GravityDisabledUntilMovedComponent` / `esv::GravitySystem`** are item gravity: "placed in mid-air until moved". The query pairs `TranslateChangedOneFrame + GravityDisabledUntilMoved + Transform`, and `esv::GravitySystem` holds `SetGravityActive` / `SetGravityType` requests. Not used by character movement. **[M]**
- **`eoc::FloatingComponent`** appears in the server `esv::falling::DataComponent` query, next to stats, health, boosts and chasm data. It looks like fall-damage and chasm bookkeeping (and the "floating" creature tag), not a hover integrator. **[L]**

## Q3. Server side and multiplayer

**The client drives its controlled character and reports state changes to the server. Per-frame Y is never sent. [M]**

- **Client sync builder `0x141fe0520`** (pattern `48 89 5C 24 10 48 89 74 24 18 48 89 7C 24 20 55 41 54 41 55 41 56 41 57 48 8D AC 24 50 F9 FF FF 48 81 EC B0 07 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 85 A0 06 00 00 4C 8B E1`):
  - It allocates messages 0x2B (`NETMSG_CHARACTER_USE_MOVEMENT`), 0xCC and 0xEB, and sends them to the server peer (`0x144031600(net, net+0x418, msg)`).
  - **Falling block at `0x141fe0c5f`** (pattern `48 C1 E8 2F A8 01 0F 84 ?? ?? ?? ?? 41 80 BD CD 01 00 00 06`):
    1. If ecl `Flags` bit 47 is set (the fall was entered) and it wasn't yet reported (`netState+0x1CD != 6`), it marks the fall as reported.
    2. It reads the client `MSFalling`: Height, Start, Velocity, +0x41, +0x42.
    3. It appends the 0x28-byte entry `{entity, Height, Start, Velocity, flags}` to message **0xCC** via `0x141fe22e0`.
  - SE's `NetMessage.inl` numbering does not match Patch 8 here (SE says 204 = LEVEL_SWAP_COMPLETE, 237 = CHARACTER_MOVEMENT_FALLING), so the name is unconfirmed. The 0xED ctor `0x1411a7db0` sits next to the 0xEB one. **[M]**
- **Server `MSFalling`:**
  - Vtable `0x1457e9e08`, GetType 6, Enter `0x143063eb0`, **Update `0x143064030`** (pattern `48 8B C4 48 89 58 10 48 89 70 18 48 89 78 20 55 41 54 41 55 41 56 41 57 48 8D A8 B8 FE FF FF`).
  - Same math: −20 constant at `0x14591d394`.
  - Enter sets the esv flag bit 57 (`0x200000000000000`) and calls the esv SetTranslate (`0x1435e37b0`).
- **Server → clients:** the server `NETMSG_CHARACTER_UPDATE` builder `0x14306f590` (block around `0x14306fd70`) sends the same fall parameters to the clients when bit 57 is set. The clients replay the parabola locally. **[H]** for the payload, **[M]** for direction.
- **Server movement:**
  - Server GetState: `0x14301a880` (pattern `48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 48 8B F9 33 F6 4C 8D 0D ?? ?? ?? ?? 83 FA 07 77 3D 48 63 C2 45 8B 84 81 A8 AC 01 03`).
  - Type-3 Update `0x143060a30` follows a path id with the same Y-keeping step and its own `ShouldFall` check, using the server's own position.
  - esv `SetTranslate` `0x1435e37b0` queues `{entity, old, new, flags}` into `esv::CharacterManager` (`+0x160`) and writes the TransformComponent.
- **What this means for each approach:**

  | Approach | What the server and other players get |
  | --- | --- |
  | **Vanilla parabola** (client MSFalling with preset velocity) | The reported Start and Velocity make the **host's server character rise on the same parabola**, and the other clients get it through `CHARACTER_UPDATE`. Co-op visible with no extra work. **[M]** Open question 3: whether the server accepts an *upward* velocity, and rubber-banding at landing. |
  | **Custom curve / time-warp / mid-air WASD** (client-only) | The server and other players see the vanilla parabola from the reported launch velocity, without the steering. Keeping them identical needs (a) the host DLL to apply the same warp to the server MSFalling of that character, and (b) each client DLL to apply it to the remote jumper's client MSFalling. Jump parameters travel over our existing `DAG_JumpStart` / `DAG_JumpNotify`; the warp is deterministic from `(t0, duration, height)`. Mid-air XZ steering would need our own 10–20 Hz position broadcast for remote views. |
  | **Raw client transform writes** (no falling state) | Never reported. The server stays on the ground. |

- **Fall damage [L]:** the client fall height is `Start.y + Height − ground`, not the apex. Server fall damage (`esv::FallingSystem`, `esv::falling::DataComponent`) was not traced. A 5.5 m apex may or may not hurt (open question 4).

## Q4. Collision while lifted

- **Walking (MSMoveTo) [H]:**
  - XZ follows a nav path on the **AI grid**. The WASD target is path-corrected against the grid (`0x1442603b0`, move-speed spike), and walkability checks run with the character's own grid footprint disabled around them (`0x14420af70(char, 0/1)` around `0x140e3ad30`).
  - The character's current height plays no part in passability: ground-level obstacles stay blocked whatever Y is.
  - A lifted character in MoveTo is handed to MSFalling anyway (Q1).
- **Falling (MSFalling) [H]:**
  - **No lateral collision at all.** XZ is pure `Start + Vel·t`.
  - The only test is the vertical ground probe under the current XZ, which starts at `y + max(2r, extraUp)`.
  - So an airborne character passes over obstacles lower than its height and **lands on top of them** (on their physics surface).
  - It also **passes through walls**. If it enters geometry whose top is within the probe's start margin, it snaps up onto it.
  - Our DLL must add a lateral check, for example blocking an XZ step when `GroundProbe` at the new XZ returns a floor above the current feet height.

## Ranked levers

| # | Lever | Where / pattern | What to do | Cost / frame | MP | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| **1** | **Own the client MSFalling** (enter + Update hook) | Enter via `GetState` `0x141bd67c0` + the layer-1 push protocol (Q2). Update: patch the MSFalling vtable slot **+0x20**. Get the vptr at runtime from `*(void**)GetState(machine, 6)`; validate `vt[1]` bytes `B8 06 00 00 00 C3` and `vt[4]` == the Update pattern. ecl::Character* comes from the MoveSpeed thunk (rcx of the template fetch = the WASD character) or Lua. SetTranslate = `ecl::Character vtable +0xD8` (bytes start `48 8B C4 48 89 58 10 48 89 68 18 48 89 70 20 57 48 81 EC 10 01 00 00`; not unique on its own, so resolve through the vtable). | **Start:** Start = current position, Velocity = (0, v0, 0), `+0x44 = 1`, `+0x18 = 0`, push. **Hook**, only for our state while the jump is active: `y = startY + curve(u)`; XZ = current + WASD world vector (WASD state component `0x140705ea0`, or `GetMovementInputWorldVec` `0x14425e7f0`) × our speed × dt, blocked by a `GroundProbe` lateral check; call SetTranslate; keep `+0x54 = 1`. **End:** set Start = current position, Velocity = (0, vy_now, 0), `+0x48 = 0`, then call the original, which falls the rest, lands on the probe hit and sends the land event. | 1 hook call + 1–2 physics sweeps for one character | The server sees the reported launch only (vanilla arc). For an identical curve the host warps the server MSFalling of that entity (server vtable `0x1457e9e08` +0x20) and each client warps remote jumpers. | **Medium.** Layer-protocol replication; re-seed hazard harmless because we own the position; flags 47/48 may block input or actions; BG3 fall/land anim events. |
| 2 | **Vanilla ballistic + time-warp** (subset of 1) | Same entry. Optional Update hook that only edits `GameTime.dt`, or sets `+0x48` so that the parabola hits our curve | `v0 = √(80·h)`. Time scale `k = v0 / (20·T)` gives airtime `T`. Steer by rewriting `Start.xz`. Landing, probe, sound, anim and server report all stay vanilla. Without a hook: h = 5.5 m ⇒ v0 = 20.98 m/s, T = 1.05 s (`h = 5·T²`). | ~0 | Identical on all peers if every DLL applies the same `k` (or no warp at all) | **Low–medium.** Parabola shape only; no lateral collision. |
| 3 | Server MSFalling (host) for companions and NPCs | GetState `0x14301a880`, Update `0x143064030`, Enter `0x143063eb0`, esv SetTranslate `0x1435e37b0` (pattern `48 89 5C 24 10 48 89 74 24 18 48 89 7C 24 20 55 41 56 41 57 48 8D 6C 24 C1 48 81 EC 00 01 00 00`) | Same as 1/2 on the server. Replicated to all clients through `CHARACTER_UPDATE`. | ~0 | Authoritative | Medium. For player-driven characters the owning client's machine is authoritative and would fight it. |
| 4 | "Hover" by suppressing the fall check | Hook `ShouldFall` `0x1411956d0` (pattern `40 53 55 56 57 41 56 48 81 EC 80 00 00 00 0F 29 7C 24 70`) or its MoveTo call site `0x141bee995` (`4C 8D 45 90 48 8B 55 B0 48 8B 4C 24 60 E8 ?? ?? ?? ?? 84 C0 0F 84 ?? ?? ?? ?? BA 06 00 00 00`) and the idle-system site `0x141936107` (`F3 0F 10 9E C0 05 00 00 49 8B CE 48 89 7C 24 38 F3 0F 11 74 24 28 F3 0F 11 4C 24 20 F2 0F 11 45 C0 89 45 C8 E8 ?? ?? ?? ?? 84 C0 74`). Return false for our entity, and SetTranslate the lifted Y each frame. | MoveTo keeps walking at the lifted Y (it preserves Y). | ~0 | Never reported: the server stays on the ground | **Does not clear obstacles** (XZ still on the ground-level nav path). Fallback only. |
| 5 | Raw transform write each frame | ecl SetTranslate | (none) | (none) | Not reported | **Rejected:** MoveTo and MSIdleSystem push MSFalling within a frame (g = 40). Matches the 2026-10-09 decision. |

## Open in-game questions (numbered for the playtest)

1. With L2 and no warp (push MSFalling, v0 = 21 m/s), does the character really rise?
   - Does SE `Transform.Translate[2]` change on the client?
   - Do the engine camera pivot, the body (no VisualLift) and the head bone follow?
   - Does it land back cleanly?
2. Log `Start`, `Velocity`, `t` and `State` of our MSFalling every frame. Are they re-seeded mid-air by MoveTo or Idle (the hazard in Q2)? Does WASD (MoveController) keep fighting, or is it blocked by flag bit 47/48?
3. Host server: does the esv character's Transform Y rise too (SE server Lua)? Is an upward reported velocity accepted? Any rubber-band or teleport at landing? In co-op, does the other client see the arc?
4. Fall damage after a 5.5 m apex?
5. Does BG3's own fall/land animation (AnimationBlueprint events `0x141bd83c0` / `0x141bd85f0`) override our JumpFlight phase clips?
6. Lateral behaviour: does a jump into a wall pass through it? Does a jump onto a crate land on top? Does the landing on a non-nav surface trigger the unstuck snap?
7. Is the `ShouldFall` gate byte (`0x140b1a850 … & 4`) set on the dev save's level? If not, MoveTo never hands off to falling.
8. Hitbox and aim: once Y is real, drop the visual-lift offset from `Shared/Hitbox.lua` and the eye (the pivot follows the real transform).

## Confidence summary

| Claim | Confidence |
| --- | --- |
| Client MSFalling layout, math, entry/exit and ShouldFall/GroundProbe logic | **[H]** |
| MoveTo keeps Y | **[H]** |
| Layer semantics and the push protocol | **[M]** |
| Client reports the fall to the server, server replays it | **[M]** (code path seen; message not named; acceptance of an upward velocity untested) |
| How walking follows slopes | **[L]** |
| Fall damage | **[L]** |
| Jump spell = projectile attachment | **[M]** (integrator not traced) |

## Built (2026-10-10, first pass, unverified)

Lever **L1** in `tools/native/src/Hooks/RealJump.cpp`, behind `!dag_jump_mode real`:

- **Enter:** `GetState(machine, 6)` (pattern), validated by the vtable rva (`0x564F770`), GetType bytes and the Update pattern. Start = current position + 3 cm, Velocity 0, `+0x44 = 1`. Then the engine's layer-1 push (CanExit / Exit / counter / Enter) and Idle on layer 0.
- **Update hook (vtable slot 4):** each frame it rewrites Start / Velocity / t so the original's integrator lands on our point: `Start = (x, y + 20·dt², z)`, `Vel = 0`, `t = 0`. y = take-off Y + curve(u); x/z = take-off momentum, steered by WASD (physical keys, camera yaw).
- **Hand-back:** at u = 1 the state goes back to the engine with our horizontal velocity and the curve's final vertical speed, and the engine falls the rest. If the engine lands earlier (state ≥ 2, on something), steering stops.
- **Character:** the `ecl::Character*` comes from the MoveSpeed template-fetch hook (the WASD character), validated by vtable `0x56576A0`. So you must move once before the first real jump.
- **While a real jump runs:** the visual lift, the camera lift and the server hitbox lift are off, because the real position carries all of them.
- **Logs:** `RJUMP start …`, `RJUMP end … re-seeds=…`, `RJUMP landed early …`.

## Collision and landing (2026-10-10, second pass, unverified)

- **Physics scene:** the falling Update's call to `GroundProbe` (`0x141bd7480`, unique pattern `4C 8B 42 30 4C 8D 4D 60 48 8B 92 80 00 00 00 48 8D 4D 70 F3 0F 11 74 24 28 F3 0F 11 44 24 20 E8`, +31) is patched to learn the physics scene (r8).
- **Sweep:** `scene->vt[0x50](scene, float radius, vec3* from, vec3* to, Result*, 5, 0x20, 0x8100080, 1, -1, -1)`, read from GroundProbe. `Result` is 0x40 bytes; distance at +0x18, `FLT_MAX` = no hit.
- **Walls:** sphere r = 0.25, swept along the frame's step + 0.35 m at feet + 0.45 m and feet + 1.5 m. A hit stops horizontal motion (`RJUMP wall …`).
- **Ceiling:** while rising, a sweep from head (feet + 1.6 m) to the next head height + 0.15 m. A hit hands the state back with vy = 0, so the engine's gravity takes over (`RJUMP ceiling …`).
- **Landing:** hand-back fall speed capped (`jump.land_speed`, 3 m/s; the k = 3 curve ends at about 13 m/s). Lua clears the last jump clip at touchdown (`__stop__`).
