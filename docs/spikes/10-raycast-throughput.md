# Spike 10: Geometry raycast fast enough for wall-bounce checks every tick?

**Status:** answered yes
**Date:** 2026-10-08 · **BG3 version:** Patch 8 · **Script Extender version:** v32

## Question
Can `Ext.Level.RaycastClosest` be called often enough per tick to drive wall-bounce / melee blade-path / line-of-sight checks without crushing the frame budget?

A conservative target: ~20 rays per client tick (= 10 blade-path samples × 2 passes, or 20 LoS probes), with handler cost under ~2 ms.

## Why it matters
The melee blade-path check in M1 samples the sword edge at several positions during the swing and raycasts between them. Spells aimed at the crosshair raycast through the view frustum. If each ray costs even ~0.5 ms, 20 rays blow the budget.

## Fallback if no
Native plugin raycast. Same plugin as spike 3 / 11.

## What we checked
- Spike 2 proved `Ext.Level.RaycastClosest` works and returns usable `Distance` + `PhysicsGroup` + `Shape`.
- SE's event-dispatch tracing already warned on our camera tick when handler cost crossed ~2 ms — we have the same signal here if we overrun.

## In-game proof

Added `!dag2_bench <n>` to the Spike 2 probe. Casts `n` rays (default 100) with the same from/to as `!dag2_ray`, times the batch with `Ext.Timer.MonotonicTime()`, logs total + per-ray micros.

### Test steps

1. Launch BG3, load DEV-SAVE.
2. `client` → `!dag2_bench` (100 rays). Record total ms + per-ray micros.
3. `!dag2_bench 1000` for a bigger sample. Should scale roughly linear.

### What a "yes" looks like
- Per-ray cost under ~50 µs on a modern machine → 20 rays/tick costs ~1 ms, comfortable.

### What a "no" looks like
- Per-ray cost above ~200 µs → 20 rays/tick costs 4+ ms, eats a quarter of the frame budget. Promote to native.

## Result and recommendation

**Answered yes** on 2026-10-08. Benchmark in DEV-SAVE:

| Rays | Total | Per-ray |
| --- | --- | --- |
| 10 000 | 5 ms | 0.5 µs |
| 100 000 | 59 ms | 0.6 µs |

`Ext.Timer.MonotonicTime()` has 1 ms resolution so the 100- and 1000-ray runs both reported 0 ms, but the 10 k and 100 k runs give a steady ~0.6 µs. 20 rays per client tick costs ~12 µs — well under any reasonable budget. Raycast does not go into the native plugin.

### What to build in M1
- `Client/Physics.lua` wraps `Ext.Level.RaycastClosest` with the Dark-and-Gate flag presets so swing / spell / LoS code doesn't repeat the full argument list.
- Keep the Shape→Entity resolution open; if we end up iterating entities every ray, that's where cost could creep in, not in the raycast itself.

