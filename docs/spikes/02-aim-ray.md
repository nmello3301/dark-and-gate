# Spike 2: Camera ray through screen centre → world point and character hit

**Status:** answered yes
**Date:** 2026-10-08 · **BG3 version:** Patch 8 · **Script Extender version:** v32

## Question
From the client Lua state, can we cast a ray from the camera through the screen centre into the world and get the hit point (position, normal, hit entity)?

## Why it matters
Spells aim at the crosshair; melee swings resolve against whatever's in front of the camera; the HUD shows a reticle that highlights what you'd hit. Without aim raycast, every "aim at X" feature stalls.

## Fallback if no
Native plugin raycast (same plugin as spike 3 / 11). Would also need to expose the camera position/forward if those remain unreadable from Lua.

## What we checked

- `reference/bg3se/Docs/API.md` §Levels, Pathfinding & Physics:
  - `Ext.Level.RaycastClosest(from, to, physicsType, collidesWith, ignoredGroups, maxHits): PhxPhysicsHit` — hit returns `Position, Normal, Distance, Shape, PhysicsGroup`.
  - Sibling helpers: `RaycastAny`, `RaycastAll`, plus Sweep/Test variants.
- `reference/bg3se/BG3Extender/GameDefinitions/Components/Camera.h` lines 112–125:
  - `rf::Camera` exposes `ViewMatrix`, `InvViewMatrix`, `ProjectionMatrix`, `InvProjectionMatrix` as `glm::mat4` fields. `InvViewMatrix[3]` is the camera's world position; `-ViewMatrix[2]` (or `-InvViewMatrix[2]`) is the forward direction. If SE's binding returns live values here, we have aim data without the native plugin.

Spike 11 showed that `WorldTransform.Translate` on cameras read back as zero. The matrices are a different field with a different access path, so this is worth probing before giving up.

## In-game proof

Probe `mod/DarkAndGate/Mods/DarkAndGate/ScriptExtender/Lua/Spikes/Spike2_AimRay.lua`, wired from `BootstrapClient.lua`. Console commands (invoked as `!dag2_...` from the `C >>` client prompt):

- `!dag2_dump` — walks every `CameraComponent` entity, logs:
  - `cam.Controller.Camera.InvViewMatrix` rows (camera position + axes)
  - `cam.Controller.FOV` and `AspectRatio`
  - the `cam.Controller.LookAt` field for comparison
  Picks the first `Active` camera and reports a derived position + forward.
- `!dag2_ray` — casts a ray straight down 100 m from an arbitrary known-good point (character approx: `(0, 100, 0)` → `(0, -100, 0)`). This proves the raycast API is callable with sensible results regardless of whether we have the real camera data.
- `!dag2_aim` — if the dump shows real values in `InvViewMatrix`, casts a ray from camera position along camera forward for 100 m and logs the hit.

### Test steps

1. Launch BG3, load DEV-SAVE.
2. `client` → `!dag2_dump`. Paste the output; I'm looking for non-zero matrix values.
3. `!dag2_ray` → should log a successful raycast result with `Position`, `Normal`, etc., even if the from/to are arbitrary.
4. If dump had real matrix values: `!dag2_aim`. Rotate camera to look at Gale, then run again — hit position should change to roughly where Gale is.

### What a "yes" looks like
- `InvViewMatrix` returns a plausible 4×4 with non-zero translation column and unit-length axis columns.
- `!dag2_ray` returns a `PhxPhysicsHit` with a `Position` matching ground height.
- `!dag2_aim` with FP camera on produces a hit whose Position moves as the player looks around.

### What a "no" looks like
- Matrices all zeros / nil — same binding gap as `WorldTransform`. Needs native plugin to expose camera position + direction.
- `RaycastClosest` returns nil / errors — physics raycast not available from client (unlikely but checkable).

## Result and recommendation

**Answered yes** on 2026-10-08. The aim-ray capability needs no native plugin.

### What works

- `cam.Controller.Camera.ViewMatrix` and `InvViewMatrix` are populated. SE binds them as flat 16-float column-major tables. For a glm::mat4 at column-major index `4*col + row + 1` (1-based Lua), camera world position is `invView[13..15]` and forward vector is `-invView[9..11]`. Values change frame-to-frame as the player rotates — verified by two consecutive dumps showing different positions and forwards.
- `Ext.Level.RaycastClosest(from, to, physicsType, collidesWith, ignoredGroups, maxHits)` returns a `PhxPhysicsHit` userdata. `physicsType` is `"Static"` or `"Dynamic"`; `collidesWith` and `ignoredGroups` take Lua arrays of flag names from the `PhysicsGroupFlags` alias (e.g., `{"Terrain", "Scenery", "Character", "Item"}`).
- Hit fields that return real values:
  - `hit.Distance` — a fraction in `[0, 1]` of the ray's `|to - from|` length. Reconstruct world position as `from + (to - from) * Distance`.
  - `hit.PhysicsGroup` — bitmask userdata that stringifies with flag names: `PhysicsGroupFlags(Scenery,CanClickThrough)` etc.
  - `hit.Shape` — a `phx::PhysicsShape` pointer; distinct between hits, so comparing it across frames can tell "did I hit the same thing?" even without resolving to an entity handle.

### What doesn't

- `hit.Position` and `hit.Normal` always read `(0, 0, 0)` — same vec3 binding gap we've documented. Reconstruct Position from the ray; Normal is unavailable from Lua (would need the native plugin). Not blocking, since the melee/spell "where did I hit" question only needs the position.
- `hit.Shape` is opaque — no SE helper found so far to walk it back to the owning entity. Spike 10 will test if iterating `GetAllEntitiesWithComponent("...")` and matching bounds against the reconstructed position is fast enough as a fallback, or if we need a Shape→Entity native lookup.

### What to build in M1

- Promote the aim ray into `Client/Aim.lua`:
  - Cache `activeCameraController()` lookup per frame.
  - Expose `GetAimRay() → from, dir` for melee swings and spells.
  - Expose `GetAimHit(reachMeters, groups) → {entity?, position, distance, group}` with the reconstructed position.
- Server-side spell targeting uses the aim ray carried over the net channel at cast time; server does its own authoritative raycast via Osiris/SE for validation.

### API notes added

Full details recorded in `docs/se-api-notes.md` under "Camera + aim ray from Lua" so the Aim module in M1 doesn't rederive the matrix layout and raycast argument shape.

