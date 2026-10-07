---
name: bg3-deploy-test
description: Build, pack and deploy the DarkAndGate mod into Baldur's Gate 3, then run a playtest round with the developer and read the mod's log. Use whenever a change needs to be tried in-game.
---

# Deploy and playtest

Claude writes and deploys; the developer plays. One round = deploy → test steps → developer plays → read log → next change.

## Before deploying

1. Confirm the paths in CLAUDE.md's **Machine paths** table are filled in. If one is missing, ask; never guess.
2. If the test writes to a save, check the dev save has a backup from today. If not, back it up into `backups/saves/<date>/` (git-ignored).
3. Make sure the game is **not running** if the deploy replaces a `.pak` (Windows locks open files). For a Lua-only change on a running game, skip deploying the pak and use the Script Extender console command `reset`.

## Deploying

`scripts/deploy.ps1` is the only way the mod reaches the game. If it doesn't exist yet, write it first. It must:

1. Pack `mod/DarkAndGate/` into `build/DarkAndGate.pak` with `divine.exe` (LSLib). Quote every path; the project path contains spaces.
2. Copy the pak into the Mods folder, overwriting only `DarkAndGate.pak`.
3. Never touch `modsettings.lsx` or other mods. The developer enables DarkAndGate in BG3 Mod Manager once; after that, the deploy only replaces the pak.
4. Print what it did, with file size and timestamp, and exit non-zero on any error.

During M0, also test the faster loose-files route (unpacked mod files that the game and Script Extender pick up without packing). If it works, add a `-Loose` switch to the script and record the verified layout in `docs/se-api-notes.md`.

## Writing the test steps

Give the developer numbered steps they can follow without thinking:

1. What to launch: the game, or `reset` in the Script Extender console.
2. Which save to load (the dev save) and where to go.
3. Exactly what to press, in order.
4. What **should** happen, so they can tell a pass from a fail.
5. What to report back. Usually just "done", plus how it felt, because the log covers the rest.

Keep a round to about five minutes of play. Split bigger tests.

## Logging and reading results

- The mod writes `DarkAndGate/session.log` through `Ext.IO` (verify the output folder in M0 and keep CLAUDE.md in sync). Every line has a timestamp, a `[Server]` or `[Client]` tag, the system name, and the event.
- Log every input event, net message, hit claim and result, mana change, and error, behind a debug flag in MCM so release builds stay quiet.
- `scripts/read-log.ps1` prints the latest session. Use `-Tail N` and `-Grep <system>` options rather than dumping the whole file.
- After the round, read the log **before** asking questions. Report: what passed, what failed, and the evidence (log lines).

## If the game crashes or the mod doesn't load

1. Read the log and the Script Extender console output, if the developer can copy it.
2. Check the mod is enabled and placed last in BG3 Mod Manager.
3. Check Script Extender and BG3 versions; a game patch can break the extender until it updates.
4. Roll back to the last committed build and redeploy to confirm the regression.

## After a successful round

Commit with a message that states what was verified in-game, for example:
`M0 spike 1: LMB/RMB and 1–0 captured on client, logged; default bindings not yet suppressed`.
