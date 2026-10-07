# Server/Brawl/ — Brawl imports

This directory holds files **imported verbatim** from
[tinybike/Brawl](https://github.com/tinybike/Brawl) at commit
`1ac3c7c1a6bc01cdc21cb9ec8a0f857210f0ef31` (2026-05-09, "Updated README").

License: GPL-3.0, same as the rest of Dark and Gate. See `/LICENSE` and
`/NOTICE` at the repo root.

**Rule:** our bootstraps do not `Ext.Require` any file in this folder
yet. They sit here as a quarantined baseline so we can diff against
upstream when we strip Swarm Mode and Leaderboard references, and when
upstream patches arrive.

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
| Constants.lua | Named numbers used across modules |
| Listeners.lua | Osiris listener registry |

Next passes (one per commit, each after a boot smoke test):

1. Strip Swarm Mode calls — `State.Session.SwarmMode`, `State.Settings.SwarmModeEnabled`, Swarm branches in `Pick.lua`/`Movement.lua`.
2. Strip Leaderboard calls — any `Leaderboard.*` reference.
3. Rename `State.Session` → `BrawlState.Session` so our own state table can live beside it.
4. Wire into our net channel: `Pick.decideActionOnTarget` consults our mana check before accepting a spell.

**Do not add Dark-and-Gate-specific logic to files in this folder.** Our
hooks go in `Server/BrawlAdapter.lua` (to be created in M1b).
