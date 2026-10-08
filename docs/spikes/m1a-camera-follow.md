# M1a — Camera follow (and mouselook): static analysis

**Date:** 2026-10-08 · **BG3:** Patch 8 (bg3.exe, image base `0x140000000`)
**Method:** Ghidra static analysis via ghidra-mcp, cross-referenced with
`reference/BG3_NativeCameraTweaks` and `reference/BG3WASD`.
**Rule for this spike:** static only. No debugger, no attach, no game launch.

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

**M1a camera's first-pass:** target the character's eye position via a
cheap offset from character world position:
`eye = character.world + (0, 0, eye_height_m)` with `eye_height_m` tuned
in config (default 1.65). That gives us a camera that pins to the head
without needing the Granny read. The visible drop vs. bone-accurate:
head bob doesn't propagate, which is actually desirable for FP comfort.

Finding the player character pointer from inside the hook: the camera
object already carries a character handle. From `FUN_141e0f110`'s body:
- `*(longlong *)(pfVar22 + 0x44)` — "ActiveCharacter" (confidence medium,
  xref'd in SLERP code with char* `[0xf]` and `[0x79]` state bytes)
- `*(longlong *)(pfVar22 + 0x48)` — alternate character ptr (secondary)

We read the former; its world position is at `character + <TBD>` — need
one more decompilation pass to confirm the character's transform offset,
but that's a 5-minute dig once we're hooking.

## Proposed hook plan

**One hook, placed at `0x141e0c9bc` — the `UpdateCamera` call-site.**

DKUtil `write_call<5>` wraps the 5-byte CALL. Our trampoline:

```c++
void Hook_UpdateCamera(void* scene, void** ctx, uintptr_t frameInfo, void** cameraSlot)
{
    // 1. Let the engine do its full update (zoom, pitch, scene blending,
    //    HUD sync, companion placement, sound-listener updates).
    _UpdateCamera(scene, ctx, frameInfo, cameraSlot);

    // 2. Gate on config: only active in true-FP mode.
    if (!g_config.cameraFollow.enabled) return;

    // 3. Reach the camera object and the active character.
    float* cam = (float*)cameraSlot[6];
    void*  character = *(void**)((uintptr_t)cam + 0x220);  // pfVar22[0x44*2]
    if (!character) return;

    // 4. Read character world position (offset TBD — one more decomp
    //    pass; stored on the character's TransformComponent, likely
    //    the "GrannyNode_GrannyGetBoneWorldTransform" world root).
    Vec3 charPos = ReadCharWorldPos(character);
    float eyeHeight = g_config.cameraFollow.eyeHeight;  // default 1.65m

    // 5. Compute forward from accumulated mouse delta owned by this DLL
    //    (set by our SDL mouse hook; see BG3WASD InputHook.cpp for the
    //    template). Yaw/pitch -> unit forward.
    Vec3 fwd = YawPitchToForward(g_mouselook.yaw, g_mouselook.pitch);

    // 6. Overwrite the engine's output for this frame. No lerp here --
    //    straight write, so the engine's smoothing from step 1 is
    //    bypassed and the camera is pin-sharp to the head.
    cam[0x12] = charPos.x;
    cam[0x13] = charPos.y;
    cam[0x14] = charPos.z + eyeHeight;

    cam[0x1c] = fwd.x;  cam[0x1d] = fwd.y;  cam[0x1e] = fwd.z;
    // Clear the SLERP target so next frame doesn't drift back.
    cam[0x1f] = fwd.x;  cam[0x20] = fwd.y;  cam[0x21] = fwd.z;
}
```

### Why this beats NCT's follow

NCT applies its offsets *into* the engine's camera update: the game's
own smoother then still runs on top, which is where lag enters. We call
the original first and overwrite *after* it, so there's no code path
after our write that can smooth the result for this frame. Each frame
starts fresh from the engine's view of truth and ends with our pin.

### Mouselook

One extra hook, templated from BG3WASD's `InputHook.cpp`: subscribe to
the SDL mouse-motion delta before the engine consumes it, accumulate
yaw += dx * sens, pitch += dy * sens (clamped to ±89°). The engine's
own camera-rotation input (the `HandleCameraInput` call-site we have
confirmed) stays disabled by NCT's config — we don't need to override
it, we just stop feeding it. Mouselook is driven by our yaw/pitch
accumulator alone.

### Risks

| Risk | Mitigation |
| --- | --- |
| `pfVar22[0x44]` character pointer wrong in some scenes (cutscenes, flight) | Fall back to no-op when character is null; disable follow during cutscene state (detect via existing camera-def toggle at scene-def `+0x1332`). |
| Character world-position offset not yet confirmed | One more decomp pass against `FUN_141e0f110`'s "move camera toward character" branch nails it before we write code. |
| Engine other-frame systems (companion follow, HUD anchor) read the smoothed camera, not our pinned camera | We overwrite after their reads inside UpdateCamera. If something downstream re-reads next frame, no harm — it sees our pin. |
| `UpdateCamera` runs on cameras we don't want to touch (minimap, cinematic) | `cameraSlot[?]` identifies the slot. Spike 11b's camera dump already distinguishes "exploration" vs "tactical" slot; same check here. |
| Pattern drift on BG3 Patch 9 | All six patterns are unique one-hits today, so breakage will be loud. Keep them in one `offsets.h`. |

## Next steps (pending your OK)

1. One more Ghidra pass to nail: character-world-position offset on the
   character pointer, and the exact scene check for "FP eligible". ~30
   min of static work.
2. Start the DKUtil skeleton in `tools/native/src/Hooks/Camera.{h,cpp}`
   with `Hook_UpdateCamera` as above. Config lives in
   `Script Extender/DarkAndGate/native-config.toml`.
3. Separate `tools/native/src/Hooks/Mouselook.{h,cpp}` with the SDL
   motion delta.
4. Smoke-test flow: deploy DLL, launch BG3, enable `follow` in config,
   watch camera pin to character + eye height. Mouselook tested with
   `yaw+=1°/frame` self-rotation sanity check before wiring mouse delta.

I will **not** touch the binary (no renames, no comment edits that
patch bytes — only Ghidra project metadata). I will not launch the
game. Waiting for your OK before I write the hook.
