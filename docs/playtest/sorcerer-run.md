# Playtest: a sorcerer from game start to the end of the Emerald Grove fight (2026-10-13)

A new game, not the DEV-SAVE: it makes its own saves and touches no other playthrough. Rows 3 and 4 were checked on the nautiloid (2026-10-13: HP 8 -> 12, the F fixes); the rest is built but not verified in-game yet (DECISIONS 2026-10-12: play mode, max HP bonus, the 4 s pace, companions and allies fighting, 70 m / 30 m spell ranges).

## Setup (once)

1. Start BG3 (the deploy launches it).
2. In the main menu or at any point in the game, open the SE console and type `client`, then `!dag_play`. A toast says "play mode ON". From now on the whole mod is on in every game and every load: first person by itself, real-time fights, your own spells on 1–0. `!dag_play status` shows it, `!dag_play off` goes back to manual (`!dag_full_pov` etc.).
3. Once you control your sorcerer on the nautiloid: `!dag_hp 50` (+50 % max HP for your character; `!dag_hp 50 party` for the companions too, `!dag_hp off` to stop). It is kept for every save on this PC, follows level-ups, and a full character stays full.

## The run

| # | Do this | It should | Log lines |
| --- | --- | --- | --- |
| 1 | New game, create a sorcerer. | Character creation looks vanilla (no first person, no hotbar input). | client.log `PlayMode: level SYS_CC_I = character creation, first person waits` (the level name may differ) |
| 2 | Finish creation; the nautiloid starts. | First person turns on by itself once you can move (after the opening scene). Your hotbar has your own spells: damage cantrips first, then level 1 spells. | `PlayMode: first person ON by itself (level TUT_Avernus_C)`, `Hotbar: no saved layout for … -> your own spells (!dag_play): …` |
| 3 | `!dag_hp 50`. Open the character sheet. | Max HP is 1.5× (a level 1 sorcerer: about 8 -> 12); HP stays full. | server.log `HpBonus: <you> -> DAG_HP_BONUS_50 (max HP N before; !dag_hp)`, `Damage: <you> gets N HP back (max HP … with the bonus)` |
| 4 | **Verified 2026-10-13** (second nautiloid run). Nautiloid, F on things (2026-10-13 fixes). Look at the brain jars, the jars named "Mind Sanctuary" and the tentacle aquariums; climb the first vine ("Arterial Mesh") with F; in the lab, look at Myrnath (the man in the chair with his brain exposed). | Jars and other decorations get no "[F]". One F climbs the vine once and you stay at the top; F again climbs back down once. "[F] Talk to Myrnath" starts his dialogue (our HUD steps aside). Chairs say "[F] Sit on". | server.log `Interact: Brain Jar (…) is none (BG3 use actions none)`, `Interact: Tav finished using Arterial Mesh (ok) -> its use task ended so BG3 can't run it again`, `Interact: Myrnath (…) is talk -> "[F] Talk to" (has a dialog)`. Bad sign: `started using … AGAIN on its own` |
| 5 | Nautiloid fights (imps, the intellect devourer, the helm). | Real time. Enemies act at your difficulty's pace (Explorer 10 s, Balanced 6 s, Tactician 5 s, Honour 4 s); Lae'zel (and Shadowheart once freed) every 4 s, never idle. | `Pace: enemies act every N s (<difficulty>, …), your side every 4.0 s` at each fight start; `AI: fight roster: …` with each fighter's pace; any `did nothing this pulse` / `no AI pulse` line names why one idles |
| 5b | Go down in a fight (the helm: Zhalk hits for about 11; or `!dag_downme`). | The downed camera shows your character **with its head**. You stay on your own body: Lae'zel keeps fighting and comes to revive you. Enemies leave your body alone and go for whoever stands. If Lae'zel goes down too, **no game over** until the last bleed-out timer ends (3 min), and a **Give up** button appears under the banner (G works too): press it twice and BG3's game-over screen comes up at once. `!dag_downme all` downs the whole party to test it. | server.log `Downed: BG3 moved control from Tav (downed) to Lae'zel -> back to Tav …` then `control is back on Tav`; `BG3's game over waits while a party member bleeds out`; Lae'zel's `AI:` lines keep coming; no `AI: <enemy> … at Tav` after you're down. client.log `FullPov: your head shown (downed camera)`, `Spike11: head shown on …`; Give up: client.log `nobody in the party is standing -> Give up offered`, `Give up armed`, `Give up confirmed`; server.log `Downed: GAME OVER (Tav gave up)` |
| 6 | Cast your spells at range. | Single-target spells (Fire Bolt, Ray of Frost, Magic Missile) reach up to 70 m; Sleep and area spells up to 30 m (cones like Burning Hands keep BG3's length). | `SpellRange: … shot spells (70 m), … area / multi-target spells (30 m)` at start |
| 7 | Crash site, beach, the road to the grove: recruit companions, rest at camp, travel. | First person comes back by itself after every load and region change; your spell layout stays (it re-reads your spells until you bind a slot yourself with H). | `PlayMode: level … -> first person on when ready` on each level start |
| 8 | Level up (sorcerer 2). | The new spells show up on the hotbar after the next load (if you haven't bound a slot yourself), and in the H menu at once. Max HP stays +50 %. | `HpBonus:` no new line needed (the status scales by itself) |
| 9 | Emerald Grove gate fight (the cutscene starts it). | The tieflings / druids fight on your side, your companions too, everyone at the 4 s pace; the fight ends when the goblins are dead or more than 30 m away for 4 s. | `AI: fight roster:` lists `ally` / `companion` / `enemy`; `FightEnd: …` |

## If something is off

- First person doesn't come on: `!dag_play status` (client), then `!dag_full_pov` by hand. Logs: `PlayMode: first person waits: <why>` every 15 s.
- Your character keeps doing something on its own (climbing a vine back and forth, using a lever again): `client`, then `!dag_unstick` clears its task list (server.log `Interact: !dag_unstick -> …`).
- A companion stands idle: its `AI: <name> (companion) did nothing this pulse: <why>` or `has had no AI pulse for N s (…)` lines.
- Too hard / too easy: change BG3's difficulty (the enemies' pace follows it from the next fight), `!dag_enemy_pace <s>` (`auto` = by difficulty again), `!dag_hp 75` / `!dag_hp 100` / `!dag_hp 25`; `!dag_ai_interval <s>` is your companions' and allies' pace.
- The game over came while someone was still downed, or never came with everyone dead: server.log `Downed: BG3's game over …` and `BG3's game-over check after the death (party: …)` lines.
- Logs: `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\DarkAndGate\` (server.log, client.log, native.log).
