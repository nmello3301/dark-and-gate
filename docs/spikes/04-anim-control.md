# Spike 4: Can scripts play an animation at a chosen speed and cancel it?

**Status:** answered partial — can trigger; speed: see the 2026-10-09 update (Genome `PlayRate` variable); cancel still no clean Lua path
**Date:** 2026-10-08 · **BG3 version:** Patch 8 · **Script Extender version:** v32

## Question

From Lua, can we (a) start a specific animation on a character, (b) scale its
playback speed, and (c) interrupt it at a chosen point so the next chain step
can start? These are the three levers a Dark-and-Darker swing chain needs.

## What we did

`Spike4_Anims.lua` sends `DAG_PlayAnimRequest` through the shared net channel.
The server handler calls `Osi.PlayAnimation(hostUuid, animUuid, "")`. Three
commands behind MCM toggle `spike4`:

- `!dag4_play` — play a probe animation UUID.
- `!dag4_play_fast` — same, then attempt to write a playback-speed value
  into every candidate field on every candidate animation component on the
  client-controlled entity.
- `!dag4_cancel` — fire a different animation to interrupt the first.

Component matrix tried for speed:
- `AnimationSet`, `AnimationBlueprint`, `Animation`, `ActiveAnimationSlots`
- Fields: `PlaySpeed`, `Speed`, `Rate`, `TimeScale`, `PlaybackRate`

Verified 2026-10-08 on dev save, Gale as host character.

## Result

**Partial. The trigger lever works; speed and cancel do not have a Lua path.**

### (a) Trigger — ✅ works

`Osi.PlayAnimation(Gale, "01932f4d-a39b-4ea8-96ba-aef3e6b4c2d8", "")`
produced a visible brief twitch each time, confirmed in-game. The engine
accepts the UUID and runs it. Any animation UUID BG3 ships (or we author in
Toolkit later) can be triggered this way.

### (b) Speed — ❌ no Lua path

Every (component, field) pair returned `read_ok=false`. SE threw
`Property does not exist: AnimationSetComponent::PlaySpeed` (and the same
for every other field name and the `AnimationBlueprint` component). The
runtime components exist on the entity but do not expose a timescale field
to the Lua binding.

### (c) Cancel — ❌ no clean Lua path

The only lever we have is firing another `PlayAnimation` on top. That likely
restarts the state machine, but we can't observe the clip's current time or
blend state from Lua to detect "did it actually interrupt?" The twitch
behaviour suggests the engine's own anim graph is stomping our calls anyway.

## Decision

Rolls into the already-decided native plugin (see `DECISIONS.md`
2026-10-08). The plugin's existing scope — camera follow, bone reads, hit
normals — grows by two exported functions:

- `SetAnimPlaySpeed(entity, mult)` — writes the engine-side playback rate.
- `CancelAnim(entity)` — interrupts whatever clip the character is in and
  returns control for the next chain step to start cleanly.

The trigger side stays in Lua via `Osi.PlayAnimation`.

## Does spike 4 need the Toolkit?

No. The probe uses an existing BG3 animation UUID. Toolkit matters only
once M1 authors our own swing clips.


## Update 2026-10-09: speed may be reachable from Lua after all

The "no Lua lever" result above only tried top-level fields on
`AnimationSet` / `AnimationBlueprint`. QSAT (Nexus 17737) changes playback
speed by writing the **Genome blueprint variable `PlayRate`** through
`ent.AnimationBlueprint.Instance.Variables[i] = { Type, Value }`, client side
-- on photo-mode dummies. Whether gameplay characters' blueprints expose
the same variable is the open question; `!dag_anim_vars playrate` answers
it. Details, credits and the fallback options: [anim-speed.md](anim-speed.md).
