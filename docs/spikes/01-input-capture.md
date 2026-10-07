# Spike 1: Can scripts capture left and right click and keys 1 to 0, and suppress BG3's default bindings in first person?

**Status:** answered yes
**Date:** 2026-10-08 · **BG3 version:** Patch 8 · **Script Extender version:** v32

## Question
From the client Lua state, can we observe every LMB, RMB and 1–0 key event, and prevent BG3's default handler from acting on them (so a left-click swings our weapon instead of selecting a party member)?

## Why it matters
Melee swings fire on LMB press, hotbar slots fire on 1–0. Without suppression, our handlers would run *in addition to* BG3's defaults — a click would both swing and open context menus. Without observation, we have no handlers at all.

## Fallback if no
Native input hook (from the design doc). Same native plugin would also cover the spike 11 camera-follow gap.

## What we checked

- `reference/bg3se/BG3Extender/IdeHelpers/ExtIdeHelpers.lua`:
  - `Ext.Events.EclLuaKeyInput` (line 35367): subscribable with event `{ Key: SDLScanCode, Modifiers: SDLKeyModifier, Pressed: bool, Repeat: bool }`.
  - `Ext.Events.EclLuaMouseButton` (line 35370): subscribable with event `{ Button: int32, Clicks: int32, Pressed: bool, X: int32, Y: int32 }`.
  - `Ext.Events.EclLuaMouseWheel` (line 35373): scroll events, out of scope but good to know.
  - `LuaEventBase.CanPreventAction` (line 19362) + `PreventAction()` method (line 19365) — the suppression lever.
- Brawl: not checked yet; it's a server-side combat loop and shouldn't own input.
- Other mods on disk: WASD Character Movement is a native plugin — hooks input at the engine level, so we can't learn the Lua suppression semantics from it. AnimationUnlocker is pure animation data, no input.

## In-game proof

Probe `mod/DarkAndGate/Mods/DarkAndGate/ScriptExtender/Lua/Spikes/Spike1_Input.lua`, wired from `BootstrapClient.lua`. Subscribes to both input events at load. Four SE console commands (invoked as `!dag1_...` from the `C >>` client prompt):

- `!dag1_log_on` / `!dag1_log_off` — enable/disable the event log. Default off so the log file doesn't flood when the mod loads.
- `!dag1_suppress_on` / `!dag1_suppress_off` — when on, every LMB, RMB and 1–0 key event has `PreventAction()` called. If BG3 respects the flag, those actions should produce no in-game effect.

### Test steps (one play session)

1. Launch BG3, load DEV-SAVE.
2. `client` → `!dag1_log_on`.
3. Click LMB, RMB, press 1 2 3 4 5 6 7 8 9 0, press and release each with and without Shift. Watch the log fill with one line per event. Confirms observation.
4. `!dag1_suppress_on`.
5. Click LMB on the ground — the character should **not** move/attack. Right-click an NPC — context menu should **not** open. Press 1 — hotbar slot 1 should **not** fire its action. If any of these still happens, the Lua suppression doesn't actually suppress the engine-side default.
6. `!dag1_suppress_off`. Normal BG3 bindings return.

### What a "yes" looks like
- All 12 input types produce a log line (10 keys + 2 mouse buttons).
- With suppress on, the default BG3 actions don't fire for those 12.
- `Ext.Timer.MonotonicTime()` deltas show handler latency well under 16 ms per event.

### What a "no" looks like
- Suppress has no effect → engine ignores `PreventAction()` for input events; need the native hook.
- Only some inputs are suppressed (e.g. keys but not mouse) → partial; probably still points to native.

## Result and recommendation

**Answered yes** on 2026-10-08. All 10 digit keys and both mouse buttons produce one subscriber call per press and release, with modifiers and click position. `event:PreventAction()` fully blocks each: in-game, pressing 1–0 did not fire any hotbar slot and clicking LMB/RMB did not move the character or open context menus. Toggling suppress off restored normal BG3 behaviour immediately.

### Corrections to the IDE helpers

Two naming gaps in `reference/bg3se/BG3Extender/IdeHelpers/ExtIdeHelpers.lua` cost one iteration each; recorded in `docs/se-api-notes.md`:

- The IDE helpers list the events as `Ext.Events.EclLuaKeyInput` and `Ext.Events.EclLuaMouseButton`. The runtime names in `LuaClient.cpp:161,171` are `KeyInput` and `MouseButtonInput`.
- The digit-row scancodes stringify as `NUM_1`..`NUM_0`, not `Key1`..`Key0` as the helpers' `SDLScanCode` enum suggests.

### What to build in M1

- Promote the probe into a client-side `Input` module under `Client/`. Keep the suppress list declarative so swing / hotbar bindings live in `data/` not in Lua.
- Suppress needs to be scoped to "while in first-person mode" (toggleable via MCM), so the player can still use the vanilla UI in menus / tabs.
- The probe currently prints every event. The real module should log at debug level only, since input events are hot.

