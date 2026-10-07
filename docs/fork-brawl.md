# Fork Brawl, or start fresh?

**For:** Nick · **Decision owed by:** end of M0.
**Author:** Claude · **Date:** 2026-10-08.

## TL;DR

Three options. Your lean (fork the turn-based-escape + AI loop, write combat
fresh) is option B. My recommendation matches: **B, with a hard scope cap on
which Brawl modules we take**. The win is ~5 kLOC of battle-tested engine-
wrestling we don't want to re-discover; the cost is GPL-3 contagion we accept
because the mod isn't aiming at commercial distribution.

The scope-cap matters: Brawl's modules import each other heavily, and
"just the AI loop" realistically pulls six to eight files, not two.

## Brawl at a glance

~12 kLOC of Server Lua in `reference/Brawl/Brawl/Mods/Brawl/ScriptExtender/Lua/`.
GPL-3 (`reference/Brawl/LICENSE`). Features Dark and Gate re-uses or ignores:

| Brawl feature | Dark and Gate needs it? |
| --- | --- |
| Turn-based escape (pulse timers, pause handling, initiative gymnastics) | **Yes.** Core to real-time combat. |
| Real-time AI (target picking, spell selection, LOS, friendly fire) | **Yes.** Design calls for shared AI across sides. |
| Movement orchestration (move-into-position for melee / ranged / spells) | **Yes.** AI needs it; player movement uses WASD. |
| Spell + resource parsing (reads stats, finds spells by type) | **Yes.** Both AI and our hotbar system need this. |
| Swarm Mode | **No.** |
| Leaderboard | **No.** |
| Loadouts (preset party builds) | **No.** |
| Encounters/Spawn (custom spawn system) | **No.** M5's encounter overrides will be our own. |
| Melee hit resolution | **No** — Brawl keeps BG3 attack rolls; we replace with blade-path. |
| Mana / hotbar / first-person / weapon chains / spell cast-time / HUD | **No** — these are the mod. |

## Three options

### A — Fork wholesale (take all of Brawl)

- Pros: zero re-discovery; everything runs on day one.
- Cons: 12 kLOC burden; most of it isn't ours and will drift; Swarm Mode and
  Leaderboard are dead weight we'd have to maintain or gut.
- **Not recommended.**

### B — Fork the real-time-combat + AI subsystems only (your lean)

Minimum viable scope, by actual dependency walk:

| Must take | Why | Approx LOC |
| --- | --- | --- |
| `RealTime.lua` | Pulse-action timer per character; keeps engine in "combat" while running real time | 753 |
| `Pause.lua` | True-pause vs ersatz-TB handling; multiplayer-safe pause state | 557 |
| `TurnOrder.lua` | Initiative replication; keeps BG3 from reasserting its own order | 572 |
| `State.lua` | The shared singleton everything else reads. Can't avoid. | 592 |
| `Movement.lua` | Move-into-position for spells + melee; AI's hands and feet | 727 |
| `AI.lua` + `Pick.lua` + `Actions.lua` | AI decision loop + spell selection + applying actions | 207 + 663 + 409 |
| `Spells.lua` + `Resources.lua` | Spell data lookup and resource checks AI needs | 619 + 347 |
| `Roster.lua` | Participant tracking; required by RealTime + AI | 360 |
| `Utils.lua` + `Constants.lua` | Shared helpers everything imports | 937 + 464 |
| `Listeners.lua` | Osiris listener registry Brawl relies on | 1034 |
| **Total** | | **~8 240** |

What we **don't** take: `Swarm.lua`, `Leaderboard.lua`, `Loadouts.lua`,
`Encounters/*`, `Quests.lua`, `ECSPrinter.lua`, `Memo.lua`, `Commands.lua`,
`Pick.lua`'s Swarm paths, `Main.lua` (we have our own bootstraps).

Realistic trim: ~6–7 kLOC after we strip Swarm/Leaderboard references out of
the "must take" files (several of them have swarm branches we can delete).

Pros:
- The hardest 20% of the problem is already solved. Brawl's RealTime + Pause
  took its author months of trial-and-error against undocumented engine state.
- AI loop is a credible baseline. We can tune archetypes later.

Cons:
- **GPL-3 contagion.** Dark and Gate becomes GPL-3 as a whole. Not a problem
  for a free Nexus mod; forecloses commercial options forever.
- Tight coupling: `State.Session` is referenced everywhere. We can't "take
  just RealTime.lua" — the dependency graph bundles half the server code.
- Attribution: Brawl's author (tinybike) gets credit in the mod page and
  LICENSE. We're explicit about this.
- Code style and conventions differ from ours; we'll absorb Brawl's or spend
  weeks refactoring. Keep this ratio honest: more absorption, less refactor.

**Recommended if:** we're OK being GPL-3 forever, we're pragmatic about
Brawl's style, and we accept the full ~6-7 kLOC bundle rather than cherry-
picking.

### C — Start fresh (no Brawl code)

- Pros: no license encumbrance; our style; clean architecture from day one;
  no dead Brawl features to carry.
- Cons: 2–4 weeks (part-time) just to re-discover the turn-based-escape
  mechanics. Brawl's pulse-timer trick and initiative replication aren't
  documented anywhere; getting the engine to not reassert turn order under
  edge cases (loading saves, companion death, downed revival, cutscenes) is
  the kind of thing where "I thought I had this" happens many times.
- The AI loop is more re-inventable than the turn-based-escape — we could
  write a simpler, more focused AI if we didn't need Brawl's spell-selection
  machinery. But we still need target picking, LOS, friendly fire, melee
  vs. ranged choice. Not zero cost.

**Recommended if:** licensing matters (future commercial path) or you want
the architectural cleanliness enough to pay 2–4 weeks.

## My pick, if you want one

**B, with scope committed to the "must take" list above.**

The 2–4 week saving from not re-discovering the pulse-timer dance is the
single biggest schedule risk in M0→M1. We can accept GPL-3 and write clear
attribution; the mod is going to be free on Nexus anyway. We refactor
Brawl's style to match ours lazily — only when a Brawl file we're using
needs real changes, not up front.

**But if either of the following is true, flip to C:**

1. You want to eventually sell Dark and Gate or dual-license it.
2. You find Brawl's `State.Session` singleton + heavy Osi.* layering so
   uncomfortable to work in that absorption costs more than re-writing.

## If we pick B, what the first commit looks like

1. Copy the "must take" files into `mod/DarkAndGate/.../Server/Brawl/`
   verbatim (preserves attribution and makes it obvious what's imported).
2. Add `reference/Brawl/LICENSE` as `mod/DarkAndGate/Mods/DarkAndGate/LICENSE-brawl`,
   plus a top-level `LICENSE` saying Dark and Gate is GPL-3 and crediting
   tinybike.
3. Strip Swarm Mode and Leaderboard calls from `State.lua`, `RealTime.lua`,
   `Pick.lua`, `Movement.lua`. One commit per module, each committing after
   a smoke test confirms the game still boots.
4. Rename `State.Session` → `BrawlState.Session` so our own state table can
   coexist without name clashes.
5. Hook our net-channel handlers into Brawl's AI (`Pick.decideActionOnTarget`
   can call our mana check before accepting a spell).

Call it when you've picked.
