# Dark and Gate

A Baldur's Gate 3 mod that turns combat into first-person, real-time
action: Dark and Darker-style weapon swings, BG3's own spells cast at
the crosshair, a mana pool instead of spell slots, a 1-0 hotbar with
a "Prepare Hotbar" menu, companions on a shared real-time AI, and
co-op multiplayer.

**Status:** 0.1.0 alpha, the first public build. Real-time fights,
melee, spells, bows and the HUD work through Act 1's opening; co-op
is next. See [`docs/ROADMAP.md`](docs/ROADMAP.md) and
[`CHANGELOG.md`](CHANGELOG.md).

## Playing it

Download it from Nexus Mods. The install guide, requirements and
controls are in [`scripts/release/README.md`](scripts/release/README.md),
the same README that ships in the download.

Windows PC only, DirectX 11. Requires Script Extender, Ch4nKyy's Mod
Loader, WASD Character Movement, Native Camera Tweaks, Mod
Configuration Menu and AnimationUnlocker.

## Documents

- [`docs/DESIGN.md`](docs/DESIGN.md): design document, the source of truth.
- [`docs/ROADMAP.md`](docs/ROADMAP.md): milestones and progress.
- [`docs/DECISIONS.md`](docs/DECISIONS.md): one-line decision log.
- [`docs/spikes/`](docs/spikes/): engine spikes with in-game findings.
- [`docs/se-api-notes.md`](docs/se-api-notes.md): Script Extender APIs we've verified.
- [`docs/release.md`](docs/release.md): how a build is released.

## Building

```powershell
# Pack the mod (Lua + data) and install the pak into BG3's Mods folder
powershell -ExecutionPolicy Bypass -File .\scripts\deploy.ps1
# Build the native DLL (Visual Studio C++), deploy it and the pak
powershell -ExecutionPolicy Bypass -File .\scripts\pov-build-deploy.ps1
# Package the Nexus release files into build\release\
powershell -ExecutionPolicy Bypass -File .\scripts\make-release.ps1
```

Lua changes need a re-pack and a relaunch: the Script Extender reads
mod Lua from the installed pak. See the header of `scripts/deploy.ps1`.

## Credits and AI disclosure

Dark and Gate includes code from
[tinybike/Brawl](https://github.com/tinybike/Brawl) (GPL-3.0) at commit
`1ac3c7c1a6bc01cdc21cb9ec8a0f857210f0ef31`. Full credits in
[`NOTICE`](NOTICE).

Designed, directed and playtested by Nick. Most of the code was
written with Anthropic's Claude (Claude Code); the HUD art was
generated with OpenAI's image model.

## License

GPL-3.0-or-later. See [`LICENSE`](LICENSE).
