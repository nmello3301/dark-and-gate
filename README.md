# Dark and Gate

A Baldur's Gate 3 mod that turns combat into first-person, real-time
action: Dark and Darker-style weapon swings, BG3's own spells cast at
the crosshair, a mana pool instead of spell slots, a 1-0 hotbar with
a "Prepare Hotbar" tab, companions on a shared real-time AI, and
co-op multiplayer.

**Status:** M0 engine spikes complete. M1 vertical slice in progress.
See `docs/ROADMAP.md`.

## Documents

- [`docs/DESIGN.md`](docs/DESIGN.md) — design document, source of truth.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — milestones and progress.
- [`docs/DECISIONS.md`](docs/DECISIONS.md) — one-line decision log.
- [`docs/spikes/`](docs/spikes/) — engine spikes with in-game findings.
- [`docs/se-api-notes.md`](docs/se-api-notes.md) — Script Extender APIs we've verified.
- [`docs/fork-brawl.md`](docs/fork-brawl.md) — fork-Brawl analysis.

## License

GPL-3.0-or-later. See [`LICENSE`](LICENSE). This mod is free and open
source; the repo goes public with the first shared build.

Dark and Gate includes code from
[tinybike/Brawl](https://github.com/tinybike/Brawl) (GPL-3.0) at commit
`1ac3c7c1a6bc01cdc21cb9ec8a0f857210f0ef31`. Full credits in
[`NOTICE`](NOTICE).

## Platform

Windows PC only. Requires Script Extender, Mod Configuration Menu,
AnimationUnlocker, Native Camera Tweaks, WASD Character Movement, and
Ch4nKyy's Mod Loader. See [`CLAUDE.md`](CLAUDE.md) for the full
install table.

## Building

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\deploy.ps1
```

Lua changes require re-running deploy and relaunching BG3. See the
header of `scripts/deploy.ps1` for the trade-off.
