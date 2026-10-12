# Server/Brawl/ — Brawl imports

This directory holds files **imported verbatim** from
[tinybike/Brawl](https://github.com/tinybike/Brawl) at commit
`1ac3c7c1a6bc01cdc21cb9ec8a0f857210f0ef31` (2026-05-09, "Updated README").

License: GPL-3.0, same as the rest of Dark and Gate. See `/LICENSE` and
`/NOTICE` at the repo root.

**Wired 2026-10-12** by `Server/BrawlAdapter.lua` (real-time fights,
DECISIONS 2026-10-12). It loads these files in upstream `Main.lua` order and
assigns the same globals, with two differences: Brawl's `State` singleton is
`BrawlState` here, and settings come from `data/realtime.lua` instead of
Brawl's MCM page. `Memo.lua` and `Quests.lua` were imported verbatim the same
day (every module calls the `M.*` memo wrappers; RealTime calls the story
countdowns in Quests).

Every change on top of upstream is marked `-- DAG:` in the file:
- Swarm Mode, Leaderboard, Loadouts, Encounters, ECSPrinter and Brawl's
  keybind commands (`Commands.lua`) are stripped at each call site.
- Server-to-client messages: `SelectCharacter` and
  `DisableDynamicCombatCamera` are renamed `DAG_BrawlSelectCharacter` /
  `DAG_BrawlNoDynamicCamera` (handled by `Client/BrawlClient.lua`); the
  messages only Brawl's own client read are dropped.
- `Utils.debugDisplay` can route debug lines into our session log
  (`!dag_rt debug on`).
- `Memo.lua` finds the modules through the adapter's registry instead of
  `Mods.Brawl`.
- The rename, applied after the edits: every bare `State` token (not after
  `.`, `:`, a word character or a quote) became `BrawlState`; regex
  `(?<![.\w:"'])State`, skipping `Memo.lua` (its `State` key stays, callers
  use `M.State.*`).

The "must take" list (from `docs/fork-brawl.md`):

| File | Role |
| --- | --- |
| RealTime.lua | Pulse-action timer per character; the engine stays in "combat" while running real time |
| Pause.lua | True-pause vs. ersatz-TB handling; multiplayer-safe pause state |
| TurnOrder.lua | Initiative replication; keeps BG3 from reasserting its own order |
| State.lua | Shared singleton (`State.Session`, `State.Settings`) — the backbone everything else reads |
| Movement.lua | Move-into-position for spells + melee |
| AI.lua | Decision loop: pick target → pick action → act |
| Pick.lua | Spell selection and condition checking |
| Actions.lua | Applies the chosen action (useSpell, apply damage, etc.) |
| Spells.lua | Reads BG3 spell data; filters by type, cost, range |
| Resources.lua | Checks spell slots / sorcery points / mana equivalents |
| Roster.lua | Participant tracking |
| Utils.lua | Shared helpers everything imports |
| Constants.lua | Tuning constants and ids |
| Listeners.lua | Osiris / entity listener registry, routes events to RealTime |
| Memo.lua | Per-tick memo wrappers (`M.Osi.*`, `M.Utils.*`, ...) |
| Quests.lua | Story countdown events in real time (Nautiloid, Halsin, Ethel) |
| Constants.lua | Named numbers used across modules |
| Listeners.lua | Osiris listener registry |

Next passes (one per commit, each after a boot smoke test):

1. Strip Swarm Mode calls — `State.Session.SwarmMode`, `State.Settings.SwarmModeEnabled`, Swarm branches in `Pick.lua`/`Movement.lua`.
2. Strip Leaderboard calls — any `Leaderboard.*` reference.
3. Rename `State.Session` → `BrawlState.Session` so our own state table can live beside it.
4. Wire into our net channel: `Pick.decideActionOnTarget` consults our mana check before accepting a spell.

**Do not add Dark-and-Gate-specific logic to files in this folder.** Our
hooks go in `Server/BrawlAdapter.lua` (wired 2026-10-12).
