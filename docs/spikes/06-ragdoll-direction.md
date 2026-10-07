# Spike 6: Can we push the ragdoll in the direction of the killing blow?

**Status:** answered partial — can ragdoll, cannot control direction from Lua
**Date:** 2026-10-08 · **BG3 version:** Patch 8 · **Script Extender version:** v32

## Question

When a hit lands the final blow, can we make the body fall in the direction
of that blow? The design pillar is Blade & Sorcery–style heft without
simulating a full physics body; a directional ragdoll push is the single
clearest visual cue of impact weight.

## What we did

`Spike6_Ragdoll.lua` registers `!dag6_push` behind MCM toggle `spike6`.
The server-side handler picks the nearest hostile (same path as Spike 5,
30 m radius via `Osi.IsPlayer == 0` + `Osi.GetDistanceTo`), then calls
`Osi.ApplyStatus(targetUuid, "KNOCKED_DOWN", 1)`. The client sends a
direction vector `dir=(0,0,1)` with the request, but Osiris has no API that
takes a push vector.

Verified 2026-10-08 on `CombatSaveGood` against goblins in the Emerald Grove
fight. Enemy was alive at the time of the call.

## Result

**Partial.**

- Status-based ragdoll via `KNOCKED_DOWN` works: enemy visibly ragdolled on
  the first `!dag6_push`. Called on living targets — this is "knock down",
  not "push the corpse direction".
- The `dir=(0,0,1)` the client sent was ignored. `Osi.ApplyStatus` has no
  direction argument, and no other Osiris function in Brawl's usage set
  accepts an impulse vector. The engine picks the fall direction itself.
- Dead bodies already ragdoll in vanilla BG3 on death; the open question is
  only "can we steer the fall vector", and the answer is no from Lua.

## Design pivot (dev call, 2026-10-08)

Use **directional death animations** instead of a physics-impulse push.
Each weapon family + hit direction maps to a canned death animation picked
by the server at the moment of the killing blow. That gives us the Blade &
Sorcery feel without needing engine access to the ragdoll impulse.

Rationale:
- The authoring cost is bounded (10 weapon families × 4 directions = 40 clips).
- It composes cleanly with the per-weapon hit-reaction set M1 already needs.
- Physics-impulse control stays optional and can be added to the native
  plugin later if the canned animations don't feel heavy enough.

## Native plugin impact

**No scope change today.** A `PushRagdoll(entity, vec3, force)` export is a
candidate for the native plugin only if the directional-animation approach
turns out to look weak in M1 playtests. Not committed yet.
