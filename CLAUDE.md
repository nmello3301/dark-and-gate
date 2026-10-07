# Dark and Gate

A Baldur's Gate 3 mod that turns combat into first-person, real-time action: Dark and Darker–style weapon swings, BG3's own spells cast at the crosshair, a mana pool instead of spell slots, a 1–0 hotbar with a "Prepare Hotbar" tab, companions on a shared real-time AI, and co-op multiplayer.

- **Design:** `docs/DESIGN.md` is the source of truth. Read it before any feature work. Live version: https://claude.ai/code/artifact/d9d14ee0-9dac-4e0e-b924-4dc4b54b157a
- **Decisions:** `docs/DECISIONS.md`. Append a line whenever a design question is settled.
- **Progress:** `docs/ROADMAP.md`. Tick an item only after it is verified in-game, fill in milestone start and done dates, and record spike answers there. Keep it in sync whenever work finishes.
- **Current milestone:** M0 is engine-closed (spikes 1-7, 10, 11 answered 2026-10-08; 8 deferred to M4, 9 deferred to M2). Two M0 admin items still open: the fork-Brawl decision (see `docs/fork-brawl.md`) and revised M1+ estimates. M1 vertical slice starts once those are decided.

## Platform

Windows only. PC only; it requires the Script Extender. Every player (the developer and his friends) runs Windows.

The project folder path contains spaces (`Desktop\Dark and Gate`). Always quote paths in scripts and commands.

## Machine paths

Fill these in from `Initial todos.md`. Never guess a path; ask if one is missing.

| What | Path |
| --- | --- |
| Project folder | `C:\Users\nicol\Desktop\Dark and Gate` |
| BG3 install | `C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3` (Steam, Patch 8) |
| BG3 `bin` folder (bg3.exe, Script Extender) | `<BG3 install>\bin` |
| Mods folder (.pak files) | `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods` |
| Load order | `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\PlayerProfiles\Public\modsettings.lsx` |
| Saves | `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\PlayerProfiles\Public\Savegames` |
| Script Extender file output (`Ext.IO`) | `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender` (verify in M0) |
| divine.exe (LSLib) | `C:\Users\nicol\Desktop\Dark and Gate\tools\lslib\Packed\Tools\Divine.exe` (LSLib v1.20.4) |
| BG3 Mod Manager | `C:\Users\nicol\Desktop\Dark and Gate\BG3ModManager_Latest\BG3ModManager.exe` |
| GitHub repo | https://github.com/nmello3301/dark-and-gate |
| Downloaded mod archives | `C:\Users\nicol\Desktop\Dark and Gate\downloaded_mods` (git-ignored; never commit) |

## Dev save and installed mods

- **Dev save:** `DEV-SAVE`, just before the first goblin fight at the Emerald Grove entrance. Walking a little north triggers the cutscene and the fight. Use it for every combat test; never test on other saves.
- **Mod loader:** Ch4nKyy's Mod Loader (`bin\version.dll`) loads everything in `bin\NativeMods\`. Never add Native Mod Loader as well; two loaders can load the same DLLs twice.
- **Installed (2026-10-07):** Script Extender updater (`bin\DWrite.dll`, from `BG3SE-Updater-20260621`), `ScriptExtenderSettings.json` with the console on, Mod Configuration Menu 1.41.0 and AnimationUnlocker 1.0.5.5 (in the Mods folder), WASD Character Movement 1.9.9 (`bin\NativeMods`).
- **Still needed:** Native Camera Tweaks. Paks are only active once enabled in BG3 Mod Manager and exported.
- **Downloaded archives** live in `downloaded_mods/` (git-ignored). The developer's pre-project mods are backed up in `Desktop\BG3 mod backup 2026-10-07_0201`; don't restore from it unless asked.

## Mod identity

- Folder and ModTable name: `DarkAndGate`
- Mod UUID: `d5d298fd-ba29-4dc1-8346-6ac96b8c2cd7`. Never change it; saves and load orders reference it.
- Author: Nick

## Planned repo layout

```
docs/                    DESIGN.md, DECISIONS.md, spikes/, se-api-notes.md
mod/DarkAndGate/         the mod source (meta.lsx, ScriptExtender/, Stats/, data)
  ScriptExtender/Lua/
    BootstrapServer.lua  server entry
    BootstrapClient.lua  client entry
    Shared/              constants, data tables, net channel definitions
    Server/              combat director, damage, mana, spells, AI, saves
    Client/              input, aim, camera, swings, hotbar UI, HUD, effects
  data/                  weapon families, swing timings, mana costs, AI archetypes, encounter overrides
scripts/                 deploy.ps1, pack.ps1, read-log.ps1
reference/               third-party repos, read-only, git-ignored
tools/native/            native plugin, only if a spike proves it is needed
```

## Hard rules

1. **Never modify the game install or another mod's files.** The only exception is `ScriptExtenderSettings.json` in `bin`. All deployment goes through `scripts/deploy.ps1`. To return the game to vanilla, the developer runs `scripts/reset-bg3-to-vanilla.ps1` (moves, never deletes). We tried a loose-files `-Loose` deploy mode and it did not work — BG3 reads mod Lua from the installed pak by GUID, not from `Data\Mods\<Folder>\`. See `docs/se-api-notes.md`.
2. **Never commit or ship game files, decompiled code, or other mods' assets.** The mod ships our own code, our own data and patches only.
3. **`reference/` is read-only and git-ignored.** Brawl is GPL-3.0: until the fork decision is logged in `DECISIONS.md`, read it to learn from it but don't copy its code into `mod/`.
4. **Never reimplement another game's assets.** Dark and Darker and Blade & Sorcery are design references only: no animations, sounds or art from them.
5. **Back up saves before any test that writes to a save.** Use the dev save, never the developer's real playthroughs.
6. **Don't guess Script Extender APIs.** Look them up first (see below). An API that "should exist" usually doesn't.

## Architecture rules

From the design doc; enforce these in every change.

- **Server owns truth:** damage, hit validation, mana, cooldowns, charges, spell casts, AI, hotbar and mode state, anything saved.
- **Client owns feel:** input, camera, aim ray, its own swing animation and the first blade-path check, HUD and effects.
- **Build it as multiplayer from day one.** Client → server only through Script Extender net channels (`Ext.Net.CreateChannel` with our mod UUID), even in single player. No client code writes game state.
- **Tuning lives in `data/`.** Swing timings, hit-zone multipliers, mana formula constants and costs, AI thresholds. No magic numbers in Lua; anything a player might tune is also exposed in MCM.
- **Spells stay BG3 data.** We change how a spell is aimed, timed and paid for, never its effects.
- **One BG3 turn = 6 seconds** wherever turn durations are converted.

## Looking up Script Extender APIs

In this order:

1. `reference/bg3se/Docs/` (API.md and the rest), then the generated IDE helpers in `reference/bg3se`.
2. How `reference/Brawl` does the same thing. It solved real-time combat, AI polling, pause and net sync.
3. `docs/se-api-notes.md`: our own notes on APIs verified in-game. Add every API we confirm, with the Script Extender version.
4. The engine binary, only through the `bg3-spike` skill.

Lua reloads in-game with the Script Extender console command `reset`. Prefer that over restarting the game when only Lua changed.

## The playtest loop

Claude can't play the game; the developer is the playtester. Every change that needs in-game verification ends with this:

1. Deploy with `scripts/deploy.ps1`, or say `reset` is enough when only Lua changed.
2. Give **numbered test steps**: what to load, where to stand, what to press, what should happen.
3. The mod logs through `Ext.IO` to `DarkAndGate/server.log` and `DarkAndGate/client.log` (one file per Lua state, since `Ext.IO.SaveFile` has no append mode). `scripts/read-log.ps1` merges them by their monotonic timestamp. Don't ask the developer to copy console output.
4. Ask only what the log can't show: how it *felt*, and whether it looked right.

The `bg3-deploy-test` skill has the details.

**Playtest handoff convention.** When a round is ready for the developer, Claude runs `powershell -ExecutionPolicy Bypass -File scripts\notify.ps1` once. That plays `scripts\notify.mp3` and launches BG3 through its Steam URL, so the developer gets an audible cue and doesn't have to click through the Start menu. Never call it in a loop and never from inside a running playtest — one call per handoff.

## Skills

Project skills in `.claude/skills/`. They ship in `setup/skills/`; if `.claude/skills/` is missing, copy them over first.

| Skill | Use it when |
| --- | --- |
| `bg3-deploy-test` | Building, packing, deploying, and running a playtest round |
| `bg3-script-extender` | Writing or reviewing any Script Extender Lua: structure, net channels, client/server rules |
| `bg3-spike` | Answering one of the M0 engine questions, or any "can the engine do X?" question |
| `bg3-tuning-data` | Changing swing timings, mana numbers, weapon families, AI archetypes or encounter overrides |

From the **universal-modder** plugin (install it from `Initial todos.md`): `mod-any-game` (its BG3 playbook and safety rules), `reverse-engineering`, `game-automation` (screenshots of the running game, windowed mode) and `showcase-video` (clips for friends). Use its knowledge base for prior BG3 field notes before solving something from scratch.

If **ghidra-mcp** is registered later, use it only inside a `bg3-spike`, and record what it found in the spike's notes.

## Working style

- Keep changes small and testable in one play session.
- When a change contradicts `docs/DESIGN.md`, stop and ask before building. If the developer agrees, update the design doc and `DECISIONS.md` in the same change.
- Commit after each working step, with a message that says what was verified in-game.
- PowerShell is the default shell for scripts in `scripts/`.
