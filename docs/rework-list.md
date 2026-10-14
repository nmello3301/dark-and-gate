# Rework list: rules that lose meaning in real time

Started 2026-10-12 ([DECISIONS](DECISIONS.md), [design/combat-rules.md](design/combat-rules.md)). Fights run in real time at **1 BG3 turn = 6 s** (durations, recharges, concentration), with every other rule kept exactly as BG3 has it. The entries below don't translate cleanly. Each has a status and a note on what a rework could look like. The developer grows this list.

Status: **disabled** (switched off in fights for now), **as is** (works, but means something different in real time), **open** (not decided).

## Reactions

All reactions are **disabled** in fights for now (Server/Combat/NoReactions.lua). Shield and Counterspell are the first to come back, much later.

| Reaction | Status | Rework note |
| --- | --- | --- |
| Opportunity attacks | disabled | Real-time melee has no "leaving reach" moment. Could come back as a free swing when an enemy turns its back inside your reach. |
| Riposte (Battle Master) | disabled | Would fit a parry window (M2, block / parry). |
| Shield (spell) | disabled | First to return: a short timed window after a hit lands (key press, mana cost), like an active block. |
| Counterspell | disabled | First to return: needs enemy cast bars (M4) so a player can see what to counter, then a key during the enemy's cast time. |
| Hellish Rebuke | disabled | Automatic retaliation on being hit, with a cooldown? |
| Other reaction interrupts (Uncanny Dodge, Deflect Missiles, Cutting Words, Sentinel, Mage Slayer, Warding Flare…) | disabled | One by one. Most become an "on hit" choice that real time can't pause for: either automatic with a cooldown, or a key in a short window. |
| Interrupts that cost no reaction (Divine Smite prompts, Lucky, Portent, Bardic / Combat Inspiration, Tides of Chaos…) | switched off (2026-10-14) | `DAG_NO_REACTIONS` doesn't block them (148 of the 253 interrupts cost no reaction), and enemy AI casts real BG3 spells, so they did prompt: Tides of Chaos on an Acid Splash save in the gate fight. Now every interrupt's switch in BG3's reaction settings is off in real time (`Server/Combat/NoReactions.lua`, DECISIONS 2026-10-14). Class by class later, e.g. Wild Magic. |

How it's done: every fighter in a real-time fight gets the hidden status `DAG_NO_REACTIONS` (`Public/DarkAndGate/Stats/Generated/Data/DAG_Combat.txt`): `ActionResourceBlock(ReactionActionPoint)`, BG3's own "can't take reactions" lever (Shocking Grasp), plus `ActionResourceBlock(SneakAttack_Charge)`.

## Damage features

| Feature | Status | Rework note |
| --- | --- | --- |
| Sneak Attack | disabled | Could trigger on hits from behind or on targets that don't see you (stealth, Part 5 detection), once per 6 s. |

## Action economy

| Feature | Status | Rework note |
| --- | --- | --- |
| Bonus actions | open | No turn means no "bonus" slot. Bonus-action spells cast like any other spell (cast time + mana); class bonus actions (Cunning Action, off-hand attacks) need a per-ability cooldown. |
| Haste's extra action | as is (no effect) | Make it attack and cast speed instead (shorter cast times, faster swings). |
| Action Surge | as is (no effect) | A short burst: faster swings and casts for a few seconds. |
| Extra Attack | as is (Brawl repeats the hit for NPCs) | For the player, maybe a longer swing chain. |

## Movement

| Feature | Status | Rework note |
| --- | --- | --- |
| Dash | open | Sprint: a speed boost for a few seconds (`Movement.AddModifier`). |
| Disengage | open | No opportunity attacks anyway (disabled); could become a short dodge-back. |
| Movement-budget boosts (Longstrider, Mobile, Boots of Speed…) | open | Movement is uncapped in real time; turn them into a walk / run speed modifier. |

## Timing and initiative

| Feature | Status | Rework note |
| --- | --- | --- |
| "Until the end of your next turn" effects | as is (about 6 to 12 s) | Check each one: some become a fixed duration. |
| Initiative effects (Alert, initiative bonuses) | open | No turn order in real time; maybe a faster first action when a fight starts. |
