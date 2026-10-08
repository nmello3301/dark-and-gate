# M1a — Head bone read (planned spike)

**Status:** not started
**Scheduled inside M1a**, running in parallel with camera follow.
Closes before M1a → M1b transition.

## Why

[m1a-camera-follow.md](m1a-camera-follow.md) uses
`character.VisualTransform + eye_height` as a stopgap. Head-bone-accurate
FP is the goal — the camera sits on the head bone exactly, follows head
yaw/tilt from animations (combat idles, injury reactions), and gives us
accurate "where the eyes are looking from" for the blade-path hit check
in M1b.

## What we need to export from the DLL

```c
// Returns true on success; writes world-space xyz into out.
bool GetBoneWorldPos(void* character, const char* boneName, Vec3* out);
```

Called with `"Dummy_HeadFX"` for the camera and (later, M1b) with
`"WPN_Blade_Tip"`, `"WPN_Blade_Base"`, etc. for the swing hit check.

## What's already known from static analysis

- BG3 uses **Granny Animation 2.12.0.9999** (RAD Game Tools). All
  skeleton + pose data lives in Granny-side structs.
- Larian wraps Granny in behavior-tree nodes. Three reflection slots
  are directly relevant, registered by `FUN_143a1b0c0`:
  - `GrannyNode_GrannyGetBoneWorldTransform` → `DAT_14617af18`
  - `GrannyNode_GrannyGetBoneComponentTransform` → `DAT_14617af1c`
  - `GrannyNode_GrannyGetBoneLocalTransform` → `DAT_14617af20`
- The actual `execute()` for each node is reached through the node's
  vtable. The reflection registry holds a type ID, not a function
  pointer — the implementation sits in a class elsewhere.
- Granny ships a canonical API: `GrannyGetWorldPoseComposite4x3`,
  `GrannyFindBoneByName`, `GrannyGetBoneCount`. These are strong
  candidates to appear verbatim in bg3.exe (RAD typically statically
  links Granny), but we haven't searched for them yet.

## Plan

1. **String search:** look for `GrannyGetWorldPose`, `GrannyFindBone`,
   `GrannyGetBoneCount` and the exported-function signature pattern
   RAD uses (`granny_` prefix in `.rdata`). Confidence that at least
   some Granny API strings survive: high — the error-message trail
   (`granny_skeleton.cpp`, `granny_local_pose.cpp`) already confirms
   Granny is statically linked.
2. **Behaviour-tree node resolve:** find where the reflection slot
   `DAT_14617af18` is read, trace back to the class it instantiates,
   extract its vtable, locate the `execute()` method. That tells us
   how Larian walks from `(character, boneName)` to a world transform.
3. **Smaller probe path:** search for strings `"Dummy_Head"` and
   `"Dummy_HeadFX"` and chase xrefs to see where the game converts a
   bone name → bone index → transform. If the lookup table lives on
   the character's VisualComponent we don't need Granny internals at
   all.
4. **DLL export:** once (1-3) land, implement `GetBoneWorldPos` in
   `tools/native/src/BoneRead.{h,cpp}`, swap `GetEyeHeightForRace`
   out of the camera hook, read the head bone directly.

## Confidence

- (1) is a 10-minute search; Granny symbols are usually present.
- (2) is 1-3 hours of static analysis (reflection registry walk +
  vtable extraction).
- (3) is a hedge if (2) proves too fragile across BG3 patches.
- (4) is one afternoon once the API is pinned.

## Risk if this spike slips

Zero. The eye-offset stopgap in `m1a-camera-follow.md` is sufficient
for an M1a→M1b handoff; bone-accurate FP is a *polish* on top. If this
spike runs long, we ship M1a with the stopgap and finish bone reads
during M1b combat work (which needs the same code for the blade-path
hit check — so it must land before Gate 1 either way).
