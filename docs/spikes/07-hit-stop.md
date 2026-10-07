# Spike 7: Can we freeze one character's animation for a few frames?

**Status:** answered no — needs native plugin
**Date:** 2026-10-08 · **BG3 version:** Patch 8 · **Script Extender version:** v32

## Question

The design calls for 2–4 frames of per-character animation freeze on heavy
hits ("hit stop"). Can we achieve that from Lua by scaling one character's
playback speed to 0 for ~50–100 ms, without touching the global time scale?

## What we did

`Spike7_HitStop.lua` iterates the local `ClientControl` entity's animation
components, probes a candidate matrix of speed fields, and writes 0 to any
that read successfully; after `durationMs` it restores the saved value via
`Ext.Timer.WaitFor`.

Components tried: `AnimationSet`, `AnimationBlueprint`, `Animation`,
`ActiveAnimationSlots`.
Fields tried on each: `PlaySpeed`, `Speed`, `Rate`, `TimeScale`, `PlaybackRate`.

Verified 2026-10-08 on `CombatSaveGood`.

## Result

**No Lua path.**

Log output on `!dag7_freeze 300`:

```
Spike7: ClientControl entities found=1
Spike7: ent[1].AnimationSet present=true
Spike7: ent[1].AnimationBlueprint present=true
Spike7: ent[1].Animation present=false
Spike7: ent[1].ActiveAnimationSlots present=false
```

The two animation components attached to the local character exist, but
every speed-field read on them throws `Property does not exist:
AnimationSetComponent::<field>` (same binding gap we confirmed in
[spike 4](04-anim-control.md)). No visible pause. Nothing to restore
afterwards.

## Decision

Already folded into the native plugin scope (`SetAnimPlaySpeed` from
[spike 4](04-anim-control.md) in `DECISIONS.md` 2026-10-08). Hit stop uses
the same export:

```
NativePlugin.SetAnimPlaySpeed(entity, 0.0)
Ext.Timer.WaitFor(50, function()
    NativePlugin.SetAnimPlaySpeed(entity, 1.0)
end)
```

No new native functions added by spike 7; it just confirms the lever
already decided for spike 4 is the lever hit stop needs too.
