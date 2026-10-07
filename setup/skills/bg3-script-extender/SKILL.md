---
name: bg3-script-extender
description: Conventions for writing BG3 Script Extender Lua in the DarkAndGate mod — file layout, client/server split, net channels, data tables, MCM settings and how to look up APIs. Use before writing or reviewing any Lua in mod/.
---

# Script Extender Lua for DarkAndGate

## Look it up, don't guess

Before using any `Ext.*` or Osiris call:

1. Search `reference/bg3se/Docs/` and the IDE helper definitions in `reference/bg3se`.
2. Search `reference/Brawl` for a working example of the same call.
3. Check `docs/se-api-notes.md` for our verified notes.

If none of these confirm the API, say so, write a tiny probe that logs what it returns, and verify it in-game (`bg3-deploy-test`) before building on it. Add confirmed APIs to `docs/se-api-notes.md` with the Script Extender version and the date.

## Mod structure

```
mod/DarkAndGate/
  meta.lsx                         mod metadata; UUID d5d298fd-ba29-4dc1-8346-6ac96b8c2cd7
  ScriptExtender/Config.json       RequiredVersion, ModTable "DarkAndGate", FeatureFlags ["Lua"]
  ScriptExtender/Lua/
    BootstrapServer.lua            requires Shared/ then Server/; nothing else
    BootstrapClient.lua            requires Shared/ then Client/; nothing else
    Shared/Net.lua                 every net channel, defined once
    Shared/Data.lua                loads data/ tables
    Shared/Log.lua                 the session logger (both sides)
    Server/<System>.lua            one file per system
    Client/<System>.lua            one file per system
```

Keep `RequiredVersion` at the lowest Script Extender version we have verified everything on.

## Client / server rules

- **Server:** damage, hit validation, mana, cooldowns, charges, spell casts, AI, hotbar and companion-mode state, anything persisted.
- **Client:** input, camera, aim ray, own swing animation, the first blade-path check, HUD, effects.
- A client file never changes game state directly. It sends a request; the server decides and broadcasts the result.
- Single player still runs client and server separately. Always test that a feature works with the logic on the right side; never shortcut through shared globals.

## Net channels

- Define all channels in `Shared/Net.lua` with `Ext.Net.CreateChannel(ModuleUUID, "<Name>")`. Don't use the deprecated `Ext.ServerNet` / `Ext.ClientNet` message functions.
- Channel names and payloads follow the design doc's message table: SwingStart, HitClaim, HitResult, CastRequest, CastResult, ManaSync, HotbarSync, ModeChange.
- Payloads are small plain tables: ids, numbers, short strings. Never send whole entities.
- Every server handler validates its input: does the character belong to the sending player, is it in range, is the timing plausible, is there enough mana. Log and drop anything invalid.

## Data and settings

- Every tunable number lives in `data/` (weapon families, swing timings, hit zones, mana constants and costs, AI thresholds, encounter overrides). Lua reads it through `Shared/Data.lua`.
- Anything a player might tune is also an MCM setting, with the `data/` value as its default.
- Don't edit BG3's own stats in place. Override or add stats entries in our mod's `Stats/` files so uninstalling restores the game.

## Persistence

- Per-character state (hotbar, companion mode, mana) is stored through the Script Extender's mod-variable or persistent-storage API. Verify which one in M0 and record it in `docs/se-api-notes.md`.
- On load, rebuild runtime state from what was saved. If combat state can't be restored, end the fight cleanly.

## Style

- One `local M = {}` module table per file, returned at the end. No new globals except the ModTable.
- Name things after the design doc: `ComboWindow`, `HitClaim`, `CasterLevel`, `ManaRegen`.
- Every system logs through `Shared/Log.lua` with its system name. Detailed logging sits behind the MCM debug flag.
- Guard every event handler with `pcall` and log errors, so one broken system doesn't take down the rest.
