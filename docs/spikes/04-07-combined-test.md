# Spikes 4 + 5 + 6 + 7 — combined probe test sheet

**Date opened:** 2026-10-08 · **BG3 version:** Patch 8 · **SE:** v32

One probe build, four spikes, one test sheet. Each spike is gated behind an
MCM toggle so the dev can enable them individually without a redeploy.

## What this probe answers

| # | Question | MCM key | Console commands |
| --- | --- | --- | --- |
| 4 | Play an animation at a chosen speed, cancel at a combo point | `spike4` | `!dag_spike4 [on\|off]` · `!dag4_play` · `!dag4_play_fast` · `!dag4_cancel` |
| 5 | Cast a BG3 spell at a world point from script | `spike5` | `!dag_spike5` · `!dag5_firebolt` · `!dag5_fireball` · `!dag5_mistystep` |
| 6 | Push the ragdoll in the direction of the killing blow | `spike6` | `!dag_spike6` · `!dag6_push` |
| 7 | Freeze one character's animation for a few frames | `spike7` | `!dag_spike7` · `!dag7_freeze [ms]` |

All commands are client-side (`C >>` prompt). The server receives intents
through the shared net channel defined in `Shared/Net.lua`; its handlers log
every incoming message and queue Osiris calls to the next tick so they never
run in a restricted context.

Does spike 4 need the Toolkit? **No.** The spike points at an existing BG3
animation UUID and probes the control surface (`Osi.PlayAnimation`, speed
component writes). The Toolkit only matters once M1 authors our own swing
animations.

## Setup

1. `scripts\deploy.ps1` to pack and install the mod.
2. Launch BG3. On the main menu, press `~` to open the SE console.
3. **Verify plumbing before any spike:**
   - Type `client` to switch the console to the client Lua state.
   - Type `!dag_ping`.
   - Expected log line in `client.log`:
     `Client Net: PingReply nonce=... roundtrip=Nms server_dt=Mms`
   - If that line is missing, stop and debug the net plumbing before running spikes.
4. **Dump the Osiris function list:**
   - `server` → `!dag_osidump`
   - Writes `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\DarkAndGate\osiris-functions.txt`
   - If the SE API path is missing, run `scripts\extract-story.ps1` and open
     `tools\extracted-story\story.div.osi` in LSLib's Osiris Debugger.
5. Load **DEV-SAVE** (Emerald Grove entrance, before the goblin cutscene).

## Spike 4 — animation playback

1. Walk north until you can see at least one goblin.
2. `client` → `!dag_spike4 on`.
3. `!dag4_play`. Watch the character.
   - **Report:** did a visible animation play? Was it the swing-style clip,
     the loop clip, or nothing?
4. `!dag4_play_fast`. Same clip, speed-write attempt.
   - **Report:** did the clip play visibly faster? If identical speed, speed
     writes don't take and spike 4's answer leans "needs native".
5. `!dag4_play` and within ~0.5 s press `!dag4_cancel`.
   - **Report:** did the first clip visibly cut off, or play to completion?

Log lines to copy: everything starting with `Spike4:` and `Net: PlayAnim`.

## Spike 5 — cast spell at crosshair

1. `!dag_spike5 on`. Stand facing a goblin, don't trigger the cutscene yet.
2. `!dag5_firebolt`. Look at a goblin's chest.
   - **Report:** did a Fire Bolt projectile fire? From the character, toward
     the crosshair, hitting the goblin?
3. `!dag5_fireball`. Aim at the ground 10 m ahead.
   - **Report:** did a Fireball land where you aimed, or at the caster, or
     not at all?
4. `!dag5_mistystep`. Aim at a reachable patch of ground.
   - **Report:** did the character teleport to the aim point?

Log lines: `Spike5:` and `Net: UseSpell`.

## Spike 6 — directional ragdoll push

1. `!dag_spike6 on`. Approach a goblin close enough to see it clearly.
2. Kill the goblin with any means (reset the fight by reloading if needed).
3. While it's falling, `!dag6_push`.
   - **Report:** did the body visibly move in the direction you were facing,
     or did it fall as it would have anyway?

Log lines: `Spike6:` and `Net: RagdollPush`.

## Spike 7 — hit stop

1. `!dag_spike7 on`.
2. In the goblin fight, as you take or deliver a swing, press `!dag7_freeze 150`.
   - **Report:** did the local character's animation visibly pause for ~0.15 s
     and then resume? If nothing paused, speed writes don't take from Lua.
3. Try `!dag7_freeze 50` and `!dag7_freeze 300` to see if duration tracks.

Log lines: `Spike7:` and `Net: HitStop`.

## After the test

Send me the merged log (`scripts\read-log.ps1`) plus one short line per spike
with the "report" answers above. I'll write the four `docs/spikes/0N-*.md`
notes from that, tick ROADMAP, and roll the native plugin scope forward if
any of 4/6/7 need it.
