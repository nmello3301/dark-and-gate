# M1a — Camera follow (and mouselook): static analysis

**Date:** 2026-10-08 (initial pass) · 2026-10-08 (dev-review pass)
**BG3:** Patch 8 (bg3.exe, image base `0x140000000`)
**Method:** Ghidra static analysis via ghidra-mcp, cross-referenced with
`reference/BG3_NativeCameraTweaks` and `reference/BG3WASD`.
**Rule for this spike:** static only. No debugger, no attach, no game launch.

## Dev-review corrections (2026-10-08)

Six corrections / open questions from the dev review, resolved in-doc below:

1. **Up axis = Y**. BG3 world is Y-up (Osi.GetPosition returns `x, y, z` with
   `y` = height). Fixed in the pseudocode and the camera-field table.
2. **vt[0x58] commit semantics.** Analysed. See "Commit timing" section.
3. **Visual vs. simulation character position.** We read the Visual-side
   transform. See "Character position source" section.
4. **NCT conflict.** Analysed. See "NCT coexistence" section. Verdict:
   keep NCT installed, zero its offsets.
5. **Eye height as stopgap.** Per-race defaults table added. Separate
   spike doc `m1a-bone-reads.md` is planned under M1a, not deferred.
   DECISIONS line added.
6. **Mouselook scope.** SDL relative mode, pause-on-UI, character facing.
   BG3WASD composes for free. See "Mouselook" section.

## Short version

- NCT's camera hook signatures from Patch pre-8 still **all match** in our
  bg3.exe. Camera follow can hook the same call-sites.
- The function NCT calls `UpdateCamera` is `FUN_141e0f110`
  (4.2 KB, 33 callees). It writes the camera's **world position** at
  `camera + 0x48` (3 floats) and **forward unit vector** at `camera + 0x70`
  (3 floats) before returning. Those are the fields we overwrite.
- NCT's follow-lag comes from an engine-side lerp inside
  `FUN_141e0f110` of the form `pos = pos + damp * dt * (target - pos)`.
  Writing after this lerp — our post-hook — bypasses it, zero lag.
- Head-bone-accurate FP is **deferred to a follow-up spike**: BG3 uses
  Granny Animation 2.12 and routes bone reads through the behavior-tree
  node `GrannyNode_GrannyGetBoneWorldTransform`. The reflection slot is
  known; the node vtable's execute() needs its own spike.
- For M1a kickoff we aim the camera at `character_world_pos + eye_offset`.
  Visually acceptable for first-pass true-FP; swap to bone-accurate once
  the bone-read spike lands.

## Addresses and patterns (verified in Ghidra, confidence noted)

All addresses are in bg3.exe. Image base `0x140000000`; subtract that for
offsets relative to the module base when passed to DKUtil.

| What | Address | Confidence | Byte pattern (DKUtil) | Notes |
| --- | --- | --- | --- | --- |
| `FrameCameraUpdate` function | `0x141e0b4c0` | high | — | Only caller: `FUN_14075e270`. Hosts the five camera call-sites below. |
| `UpdateCamera` call-site (hook anchor) | `0x141e0c9bc` | **high** | `48 8D 8D F8 04 00 00 E8 ?? ?? ?? ?? E9 AF FD FF FF` | Pattern matches once (unique). CALL is at `+0`, LEA RCX,[RBP+0x4f8] is at `+5` to `+11`. |
| `UpdateCamera` target function | `0x141e0f110` | **high** | — | 4.2 KB. 33 callees. Writes final camera transform. |
| `HandleCameraInput` call-site | `0x141e0cbcf` | high | `E8 ?? ?? ?? ?? 0F B7 08 66 89 0B 80 3B 00` | 1 hit. |
| `CalculateCameraPitch` call-site | `0x141e1abc3` | high | `E8 ?? ?? ?? ?? 80 BF 4C 01 00 00 00` | 1 hit. |
| `UpdateCameraPitch` call-site | `0x141e0fad3` | high | `E8 ?? ?? ?? ?? 48 8B 46 70 4C 8D 45 90 0F 28 46 30` | 1 hit. |
| `AfterUpdateCameraZoom` call-site | `0x141e0fb8f` | high | `E8 ?? ?? ?? ?? 80 BF 54 02 00 00 00` | 1 hit. |
| `GetCurrentCameraDefinition` | `0x141c719a0` | high | `48 8B 05 ?? ?? ?? ?? 80 B8 32 13 00 00 00 74 07` | 1 hit. Returns active `CameraDefinition*` (combat / exploration / alt). |
| `GetCharacter`-ish call-site | `0x141e10549` | medium | `E8 ?? ?? ?? ?? 41 0F 28 45 40` | 1 hit. Pattern matches NCT's `GetCharacter` scan; haven't yet decompiled the target to confirm. |

Bookmarks for all five anchors + the UpdateCamera target + the camera
definition getter are stored in the BG3 Ghidra project under category
`DarkAndGate`.

### UpdateCamera signature and camera object layout

Decompiled from `FUN_141e0f110`:

```c
void FUN_141e0f110(longlong *param_1,     // scene / world
                   undefined8 *param_2,   // some context ptr
                   longlong param_3,      // &frameInfo (reads [+0xc]=dt)
                   longlong *param_4);    // &cameraSlot (reads [6]=cameraObject)
```

- `pfVar22 = (float*)param_4[6]` — the camera object our hook writes to.
- Confirmed field offsets (floats, so `pfVar22[k]` is 4*k bytes):

| Offset | Float idx | Field (inferred) | Confidence |
| --- | --- | --- | --- |
| `+0x48` | `[0x12]` | World position (x,y,z) | **high** — the function's final virtual call is `(*vt[0x58])(sys, slot, &localPos, pfVar22+0x12)` |
| `+0x5c` | `[0x17]` | Pitch (radians) | medium — written from `pitchClose`/`pitchFar` tables, same path NCT patches |
| `+0x70` | `[0x1c]` | Forward unit vector (x,y,z) | **high** — SLERP'd each frame against `+0x7c` and renormalised via `FUN_140e5eba0` |
| `+0x7c` | `[0x1f]` | Forward SLERP target (x,y,z) | high — same SLERP pair |
| `+0xa4` | `[0x29]` | Pitch damping scalar | medium |
| `+0xa8` | `[0x2a]` | Mode flags (bit0 = combat) | high — switches between `+0x79c`/`+0x930` offsets on the camera-def singleton |
| `+0x14c` | `[0x53]` | "Mouse rotating" bool | medium — `uVar12=1` iff `param_4[10]!=0 && *(char*)param_4[10]` |
| `+0x168` | — | Zoom-reset trigger bool | low |

### The follow-lag source

Inside `FUN_141e0f110`, after mouse / character-position computations:

```c
fVar28 = fVar28 + *(float *)(lVar15 + 0xf8) * *(float *)(param_3 + 0xc)
                * (fVar29 - fVar28);
```

This is the classic exponential-decay smoothing applied to the camera
`pfVar22[0x29]` on exploration/combat scene changes. There are at least
3 similar lerps across the function body. For true-first-person we want
**zero smoothing**: our post-hook writes the character's eye position
directly, which replaces the lerp's output for that frame.

## Commit timing — zero-frame lag reasoning

The last meaningful write in `FUN_141e0f110` is a virtual call:

```c
local_3c8 = param_4[0xe];        // slot token (name/id)
local_3c0 = param_1[1];          // scene ptr
(**(code **)(*param_1 + 0x58))(  // param_1 = R13 = CameraSystem
    param_1,
    &local_3c8,                  // RDX: slot token (16B)
    &local_508,                  // R8:  new position (xyz, 12B)
    pfVar22 + 0x12               // R9:  out pos = cam + 0x48
);
```

Shape: `CameraSystem::CommitSlotTransform(sys, slotToken, newPos, outPos)`.
`outPos = cam+0x48` is written by this call; the function clearly treats
`cam[]` as the authoritative storage, since the whole body wrote to
`cam[0x17]` (pitch), `cam[0x1c..0x1e]` (forward), `cam[0x1f..0x21]`
(SLERP target) directly before this commit.

The question is: does `vt[0x58]` *also* mirror these values into a cached
view matrix the renderer reads independently? Static analysis alone can't
rule it out (`vt[0x58]` is reached indirectly, we'd need to resolve the
vtable instance to decomp it).

**Two mitigations, both cheap, applied together:**

A. **Post-hook writes `cam[]` directly after `UpdateCamera` returns.**
   If `cam[]` is the renderer's source, we win here — zero-frame lag.

B. **If a mirror exists, we re-invoke `vt[0x58]` with our position.**
   We hold `param_1` (CameraSystem) and can reconstruct the slot token
   from `param_4[0xe]` + `param_1[1]`. Cost: one virtual call per
   frame (~1 µs on modern x64).

Taken together, zero-frame lag is deterministic without proving which
scenario holds. **In-game smoke test to confirm:** walk the character
in a straight line at the fastest run speed. If the camera visibly
trails by one frame at the start-of-run or stop-of-run acceleration
spike, the mirror exists and we re-commit; otherwise (A) was enough and
we can drop (B) to save the virtual call.

Pitch field (`cam+0x5c`) and forward vector (`cam+0x70`) are written by
`UpdateCamera` in the body (not by `vt[0x58]`); overwriting them in our
post-hook is sufficient. We **always** write them to match the forward
we chose, so the engine can't reconstruct a conflicting pitch from the
forward or vice versa.

## Character position source

BG3 characters hold two transforms:

- `ls::TransformComponent` — simulation position, written by the physics
  tick (confirmed via string at `0x1454d6880`).
- `ls::VisualComponent` → `.VisualTransform` / `.VisualTransform3D` —
  render-interpolated position, exposed by name at `0x14531c7b8` and
  `0x14531c7d0` (reflection surface, used by the engine's own
  serializers).

**We read `VisualComponent.VisualTransform`**, not `TransformComponent`.
Rationale: the simulation tick runs at a fixed rate (BG3's physics is
60 Hz typical); between ticks the renderer interpolates. Reading sim
position means the camera snaps once per physics tick while frames
in between still render — classic 1-tick stutter when sim rate <
frame rate (e.g. 144 Hz display).

The camera object already holds a character pointer at
`cam+0x220` (`pfVar22[0x44]`), likely the "active character to follow"
and already used by `UpdateCamera` for position-based zoom math.

**TODO at implementation time (not blocking the spike close):** confirm
the VisualTransform offset *on the character* and whether the camera's
`cam+0x220` ptr targets the character or its VisualComponent. One
decompilation of `GrannyNode_GrannyGetBoneWorldTransform`'s callee (or
any existing site that reads a character's visual transform) nails it;
pattern search for `char + <small offset>` reads tagged by the string
xrefs above. Keep the lookup in `offsets.h` so it's one line to swap.

## NCT coexistence

NCT loads from `<BG3>/bin/NativeMods/BG3NativeCameraTweaks.dll` via
Ch4nKyy's loader. Ch4nKyy iterates `NativeMods/*.dll` **alphabetically**,
so load order is deterministic:

```
BG3NativeCameraTweaks.dll   loads first
BG3WASD.dll                 loads second
DarkAndGate.dll             loads last
```

NCT's `Hooks.cpp` installs its UpdateCamera hook via DKUtil
`write_call<5>(callAddr, Hook_UpdateCamera)` on the exact same 5 bytes
at `0x141e0c9bc`. When we install our hook, DKUtil's `write_call<5>`
captures the **current** target at `callAddr` (which is NCT's trampoline
address, not the real `FUN_141e0f110`) and stores it in our
`_UpdateCamera`. Chain safely:

```
UpdateCamera call-site (bg3.exe)
  → OurHook  (reads _UpdateCamera, calls it)
      → NCT's Hook_UpdateCamera
          → NCT's _UpdateCamera (real FUN_141e0f110)
          → (NCT applies pitch/zoom/FOV/offset tweaks here)
      → (NCT returns)
  → (we overwrite cam[] with our pin)
```

That's the behaviour we want. DKUtil's capture-current-target idiom is
documented and both NCT and WASD rely on it.

**Startup check:** at DLL load, read the 5 bytes at `0x141e0c9bc`. If the
displacement in the CALL doesn't resolve to `FUN_141e0f110`, log a
`[Native] Camera call-site already hooked by another mod — chaining via
captured target`. Not a warning in the error sense — just a log line so
future-us can tell what happened.

**Should NCT stay installed once our follow works?** **Yes, with its
offsets zeroed.** NCT provides four things we want for free:

- `ExplorationFOVClose = 90.0` — FP-friendly FOV, we'd otherwise have
  to hook `AfterUpdateCameraZoom` ourselves.
- `ExplorationUnlockPitch = true` + wide pitch limits — mouselook needs
  this; otherwise the engine clamps pitch to the normal isometric range.
- `ExplorationZoomMin = 0.0` — pushes the camera into the character
  (so the engine's own "camera inside geometry" fallback doesn't fire).
- `MouseCameraRotationMult`, `MousePitchMult` — handy backstops.

What fights us:

- `ExplorationHorizontalOffsetMult`, `ExplorationVerticalOffsetMult`
  must be `0.0` when our FP mode is active. If not, NCT adds its offset,
  then we overwrite with character+eyeHeight, net result is the engine
  reads character+eyeHeight correctly but there's an extra lerp step
  per frame we don't want. Zero them in `BG3NativeCameraTweaks.toml`
  while FP is on. Document in `tools/native/README.md`.

If NCT turns out to constrain our mouselook (fighting over pitch), we
patch the dependency by disabling NCT's pitch hook; but that's a bridge
to cross if we hit it, not up front.

## Head bone — deferred to a follow-up spike

What the search found:

- `Dummy_HeadFX` string at `0x14565b948` (one of the player's head socket
  names, mentioned in Spike 11's visual dump).
- `Dummy_NeckFX` string at `0x145500078`.
- BG3 uses **Granny Animation 2.12.0.9999** (RAD / Larian). Pose and
  bone transforms live in Granny-side structs.
- Larian wraps Granny in behavior-tree nodes. The reflection registry
  function `FUN_143a1b0c0` registers these node names, and three of them
  are directly relevant:
  - `GrannyNode_GrannyGetBoneWorldTransform` → reflection ID at `DAT_14617af18`
  - `GrannyNode_GrannyGetBoneComponentTransform` → `DAT_14617af1c`
  - `GrannyNode_GrannyGetBoneLocalTransform` → `DAT_14617af20`
- The actual `execute()` for each node is reached through the node's
  vtable. We'd need to find the node class instance (xref the reflection
  slot), extract its vtable, and reach the implementation. Non-trivial;
  belongs behind its own spike (`m1a-bone-reads.md`), not the camera
  critical path.

**M1a camera's first-pass (Y-up corrected):**
`eye = character.VisualTransform.pos + (0, eye_height_m, 0)` — eye
height adds to **y**, not z. Per-race defaults go in config since the
Granny bone read isn't live yet:

| Race | Eye height (m) | Note |
| --- | --- | --- |
| Human / Half-Elf / Tiefling | 1.68 | baseline |
| Elf / Drow | 1.75 | taller / willowy |
| Dragonborn | 1.90 | tallest |
| Half-Orc | 1.80 | |
| Githyanki | 1.78 | |
| Dwarf (any) | 1.12 | ~2/3 human height |
| Halfling | 0.90 | |
| Gnome | 0.88 | |
| Default fallback | 1.65 | if race-lookup fails |

Resolved by reading the character's `RaceComponent` (string tag). The
exact offset-to-tag lookup lands at implementation time; we can also
start by hard-coding one value and tune after a quick in-game read.

**The eye-height path is a stopgap.** Head-bone-accurate FP remains the
goal; see `docs/spikes/m1a-bone-reads.md` (sibling spike, scheduled
inside M1a, not after). DECISIONS.md carries the one-liner.

Finding the player character pointer from inside the hook: the camera
object already carries a character handle. From `FUN_141e0f110`'s body:
- `*(longlong *)(pfVar22 + 0x44)` (= `cam+0x220`) — "ActiveCharacter"
  (confidence medium, xref'd in SLERP code with char* `[0xf]` and
  `[0x79]` state bytes).
- `*(longlong *)(pfVar22 + 0x48)` (= `cam+0x240`) — alternate character
  ptr (secondary; probably "target of look-at"; ignore for FP).

## Mouselook

**Scope:**
- SDL relative mode: `SDL_SetRelativeMouseMode(SDL_TRUE)` when FP is
  active and no modal UI is open. Cursor hidden, locked to the window,
  per-frame mouse delta accumulates yaw/pitch.
- Pause states (relative mode OFF, cursor shown, our yaw/pitch frozen):
  - Any BG3 UI panel open (character sheet, inventory, map, journal,
    tutorial).
  - In dialogue (we subscribe to the same hook BG3WASD uses:
    `DialogStatusChangedHook.cpp` — flips a bool; we read it).
  - In a cutscene / timeline (BG3WASD's state machine already tracks
    this; we mirror).
  - At the main menu / in load screens (sanity: cam ptr null).
- Pitch clamp: ±89°. Yaw unbounded.
- Sensitivity + invert in `native-config.toml`:

```toml
[dag.mouselook]
enabled = true
sensitivity_yaw = 0.12    # deg per mouse-count
sensitivity_pitch = 0.12
invert_pitch = false
pause_in_ui = true
```

**Character facing follows yaw automatically.** `FUN_141e0f110` doesn't
turn the character — it just updates the camera. The character turns
through BG3's own "camera-forward movement" command, which BG3WASD has
remapped: `CharacterMoveForward -> CameraForward` (confirmed in
`reference/BG3WASD/src/InputconfigPatcher.cpp:54`). The engine reads
the camera forward vector (which we overwrite) and translates it into
character motion. **No extra hook needed from us** to make W/A/S/D
drive the character relative to our new yaw.

Caveat: for stationary 180° turns in place (no WASD held), the
character stays facing its last movement direction. That's a known
BG3 behaviour and we live with it for M1a; M1b combat can revisit.

**Mouselook hook anchor:**
We re-use NCT's existing anchor at `0x141e0b4ca ... 0x141e0b4d0`
region or hook SDL's own `SDL_PumpEvents` entry via a trampoline on
the WASD-style `InputHook.cpp` pattern. Preferred: hook the game's
own mouse-delta ingestion point so we see the delta regardless of SDL
relative-mode state. Pattern-scan belongs in `offsets.h` once we
decompile one more call-site; not needed to start the DKUtil
scaffolding.

## Proposed hook plan (Y-up corrected, with vt[0x58] re-commit)

**One hook, placed at `0x141e0c9bc` — the `UpdateCamera` call-site.**

DKUtil `write_call<5>` wraps the 5-byte CALL and chains cleanly through
NCT if NCT loaded first (see NCT coexistence).

```c++
// Y-UP WORLD. All positions are (x, y, z) with y = height.
void Hook_UpdateCamera(void* scene, void** ctx, uintptr_t frameInfo, void** cameraSlot)
{
    // 1. Let the engine (and NCT, if present) do their full update:
    //    zoom, pitch, scene blending, HUD sync, companion placement,
    //    sound-listener setup. We'll overwrite the final transform.
    _UpdateCamera(scene, ctx, frameInfo, cameraSlot);

    if (!g_config.cameraFollow.enabled) return;
    if (IsCutsceneOrLoading(scene)) return;  // flag at scene+0x1332

    float* cam = (float*)cameraSlot[6];
    if (!cam) return;

    void* character = *(void**)((uintptr_t)cam + 0x220);
    if (!character) return;

    // 2. Visual (render-interpolated) position, NOT sim position.
    //    Avoids 1-tick stutter when sim rate < frame rate.
    Vec3 charPos = ReadCharVisualPos(character);         // VisualComponent.VisualTransform
    float eyeHeight = GetEyeHeightForRace(character);     // per-race table + config

    // 3. Forward from our own yaw/pitch accumulator.
    //    Y-up: forward = (cos(pitch)*sin(yaw), sin(pitch), cos(pitch)*cos(yaw))
    Vec3 fwd = YawPitchToForwardYUp(g_mouselook.yaw, g_mouselook.pitch);

    // 4. Overwrite cam[] -- Y gets the eye offset.
    cam[0x12] = charPos.x;                  // +0x48
    cam[0x13] = charPos.y + eyeHeight;      // +0x4c   (Y is up)
    cam[0x14] = charPos.z;                  // +0x50

    cam[0x1c] = fwd.x;  cam[0x1d] = fwd.y;  cam[0x1e] = fwd.z;   // +0x70 forward
    cam[0x1f] = fwd.x;  cam[0x20] = fwd.y;  cam[0x21] = fwd.z;   // +0x7c SLERP target (prevents drift-back)

    // Keep pitch field consistent with the forward we wrote, so the
    // engine's downstream readers don't rebuild a different direction.
    cam[0x17] = g_mouselook.pitch;          // +0x5c

    // 5. Re-commit via vt[0x58] IF the mirror-cache path exists.
    //    Smoke test determines whether we keep this call.
    if (g_config.cameraFollow.recommit_vt58) {
        RecommitCameraSlot(scene, cameraSlot, cam);  // calls (*(void*)*scene)[0x58]
    }
}
```

### Why this beats NCT's follow

NCT writes *into* the engine's camera update; the engine's smoother then
runs on top with NCT's inputs. We call the original first and overwrite
*after* it, so no code path downstream of our write can smooth the
result. The optional `vt[0x58]` re-commit covers the mirror-cache case
without introducing lag.

### Mouselook

See the "Mouselook" section above. Separate hook on the game's mouse
ingestion point feeding `g_mouselook.{yaw,pitch}`. State machine mirrors
BG3WASD's pause-on-UI logic so dialogue and panels don't jerk the view.

### Risks

| Risk | Mitigation |
| --- | --- |
| `pfVar22[0x44]` character pointer wrong in some scenes (cutscenes, flight) | Fall back to no-op when character is null; disable follow during cutscene state (detect via existing camera-def toggle at scene-def `+0x1332`). |
| `vt[0x58]` writes a mirror the renderer uses | Optional re-commit path (`g_config.cameraFollow.recommit_vt58`) calls `vt[0x58]` again with our position. Enabled by default; smoke test confirms whether needed. |
| Character VisualTransform offset not yet confirmed | Keep in `offsets.h` — one-line change once an in-game read nails it. First build can hard-code a plausible offset and iterate. |
| `UpdateCamera` runs on cameras we don't want to touch (minimap, cinematic) | `cameraSlot[?]` identifies the slot. Spike 11b's camera dump already distinguishes "exploration" vs "tactical" slot; same check here. |
| NCT or another mod hooks the same call-site | Chain through DKUtil's captured target. Log a line at load if the 5 bytes differ from the known-good disassembly. |
| NCT's vertical/horizontal offset mults fight our pin | Zero them in `BG3NativeCameraTweaks.toml` while FP is on. Document in `tools/native/README.md`. |
| Pattern drift on BG3 Patch 9 | All six patterns are unique one-hits today, so breakage will be loud. Keep them in one `offsets.h`. |

## Next steps (approved)

1. Build Camera.{h,cpp} and Mouselook.{h,cpp} under
   `tools/native/src/Hooks/` with every pattern in `offsets.h`.
2. Off by default via `native-config.toml`. First commit stops when the
   DLL compiles — no in-game testing until the dev quits League.
3. In-game smoke tests follow the "zero-frame lag" and
   "mouselook-pauses-on-UI" test shape.

Static-only pass complete. Writing hook next.
