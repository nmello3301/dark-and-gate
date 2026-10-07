# Spike 3: Can scripts read weapon bone positions every frame?

**Status:** answered no
**Date:** 2026-10-08 · **BG3 version:** Patch 8 · **Script Extender version:** v32

## Question
From the client Lua state, can we read the current world position of a named bone (specifically the weapon's blade bones) every tick, cheaply enough to use for hit checks?

## Why it matters
The core melee feel of the mod is Dark-and-Darker-style: a swing has a blade path, and anything the blade sweeps through takes a hit. The client-side blade-path check sits in `Client/`; the server validates. Without live bone reads, the "where was the blade this frame?" question has no answer in Lua and the hit check has to move to a native plugin.

## Fallback if no
From the design doc: "Native plugin for the hit check." The same native plugin would also cover the spike 11 camera-follow gap, so the plugin decision explicitly depends on this spike's outcome.

## What we checked

- `reference/bg3se/BG3Extender/GameDefinitions/Render.h`:
  - `AnimatableObject : RenderableObject` (line 688) has `OverrideTransformCount` + `glm::mat3x4* OverrideTransforms_Mat3x4` — the live per-bone transform array.
  - IDE helpers at `ExtIdeHelpers.lua:2010` type `OverrideTransforms_Mat3x4` as a `mat3x4` (singular), suggesting SE's binding exposes it either as the raw first entry or as something indexable.
- `reference/bg3se/BG3Extender/GameDefinitions/Skeleton.h`:
  - `Skeleton.Bones` is `[[bg3::hidden]] SkeletonBone* Bones` — probably not exposed to Lua.
  - `Skeleton.BoneGroups: HashMap<FixedString, Array<FixedString>>` — named groups of bones, exposed. May give us bone names without walking Bones directly.
  - `Skeleton.Sockets: Array<SkeletonSocket>` — each socket has a name, a bone index, and a `Transform`. If the live Sockets transforms are populated, this is a cleaner path than mapping bone names to indices into OverrideTransforms.

### Known concern

Spike 11 showed that `Visual.WorldTransform.Translate` reads as `(0,0,0)` through SE's Lua binding even though the engine clearly knows the real position. Bone transforms may be in the same bucket — populated in the GPU-side skinning pipeline, not where the Lua binding looks. If so, this spike also answers "no, needs native."

## In-game proof

Probe `mod/DarkAndGate/Mods/DarkAndGate/ScriptExtender/Lua/Spikes/Spike3_BoneReads.lua`, wired from `BootstrapClient.lua`.

Console command (from the `C >>` client prompt):

- `!dag3_dump` — one-shot. Finds the local character, walks its visual tree to the weapon sub-visual (templated on `WPN_HUM_Quarterstaff_...` on the dev save), logs:
  - the first `AnimatableObject` ObjectDesc's `OverrideTransformCount` and the translate columns of the first 4 `OverrideTransforms_Mat3x4` entries,
  - the weapon's `SkeletonSlots[0].Skeleton.BoneGroups` keys (if any),
  - `SkeletonSlots[0].Skeleton.Sockets[*].Name` and `Transform.Translate` (if readable).

### Test steps

1. Launch BG3, load DEV-SAVE (Gale has a quarterstaff).
2. `client` → `!dag3_dump`.
3. Read `client.log` via `scripts\read-log.ps1` and report:
   - the OverrideTransformCount,
   - whether the sample mat3x4 translations are non-zero,
   - whether BoneGroups keys and Socket names/translations are readable.

### What a "yes" looks like
- `OverrideTransformCount` > 0 and sample translates are non-zero + plausible (close to the character's world position).
- Or Sockets expose non-zero translates with named entries like `WPN_Blade_Tip`.

### What a "no" looks like
- Count > 0 but translates all zero → same WorldTransform-is-stale bug; needs native.
- Count == 0 or array not readable → SE doesn't expose it in this version; needs native.
- Sockets array empty / translates zero → same.

## Result and recommendation

**Answered no** on 2026-10-08. From client Lua, we can read bone transforms **only** when the renderable owns its own `OverrideTransforms_Mat3x4` array — in practice that happens for cloth-driven meshes (e.g. Gale's robe reported `OverrideTransformCount=24` with real non-zero mat3x4 values). The weapon's quarterstaff renderable reports `OverrideTransformCount=0`, meaning its bones are animated through the shared character skeleton pose (`Visual.MeshBinding → Pose* Pose1/Pose2`), and `Pose` is `[[bg3::hidden]]` in SE — never exposed to Lua.

Named sockets (`Skeleton.Sockets[i].Transform.Translate`) read back as `(0,0,0)` even for the player character, same SE binding bug we hit on `Visual.WorldTransform.Translate` in spike 11. `Skeleton.BoneGroups` returns opaque UUID keys, not usable bone names. No viable Lua path to the weapon blade position.

**Recommendation:** commit to a native plugin for M1. The spike 11 note already predicted this; it's now firm.

### Native plugin scope (what it needs to expose to Lua)

The same plugin addresses two of M0's "may need native" gaps at once:

1. **Camera follow** (spike 11 gap): hook the engine camera update to position the camera at a specific bone/world point each frame, no spring. Covers Dark-and-Gate's true-first-person requirement cleanly.
2. **Bone world-position lookup** (this spike): expose a function `GetBoneWorldPos(entityHandle, boneName) → vec3` that reads the shared skeleton pose and returns the live transform. Covers both the weapon blade-path check and anything else that needs a named-bone position.

Both of these touch the same `Visual → MeshBinding → Pose` chain inside the engine, so one hook can read what the other writes. Native Camera Tweaks already hooks the camera update at a similar point; its source at `https://github.com/ersh1/BG3_NativeCameraTweaks/tree/main/src` is a reasonable template for the build setup.

### Spikes 7 and 10 still outstanding

Spike 7 (hit-stop / per-character timescale) and spike 10 (geometry raycast throughput) are the remaining "may need native" questions from spike 11's note. Both should be run before we build the native plugin — if either also needs native, the plugin bundles them in; if either turns out to work in Lua, we only pay the native cost for 3 and 11.

