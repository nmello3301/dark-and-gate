-- SPDX-License-Identifier: GPL-3.0-or-later
-- Real-time fights: Brawl's loop (Server/Brawl/, wired by Server/BrawlAdapter.lua).
-- These replace the settings Brawl read from its own MCM page.
--
--   enabled             false = BG3's vanilla turn-based fights (also !dag_rt off|on)
--   round_s             one BG3 turn in seconds. Statuses, recharges and
--                       concentration tick once per round (DECISIONS 2026-10-12).
--   action_interval_s   your side's combat pace: your companions and NPC allies
--                       start an action every this many seconds
--                       (TurnOrder.calculateActionInterval), never under 1 s.
--                       An action that runs longer (a bow's 3 s draw, a cast)
--                       is followed by the next as soon as it ends, not a whole
--                       pace later (Server/Combat/NpcCombat.lua). 2026-10-12:
--                       6 s felt turn-based, then 2.5 s; the developer set 4 s.
--                       !dag_ai_interval <s> (from the next fight).
--   enemy_pace_s        the enemies' pace by BG3's difficulty (developer
--                       2026-10-13: the difficulty scales the enemies' combat
--                       pace; enemy and ally stats come later). A custom
--                       difficulty counts as its AI lethality setting
--                       (Server/Combat/Pace.lua). !dag_enemy_pace <s>|auto.
--   initiative_spread   a high initiative roll makes a fighter's pace a little
--                       faster, a low one slower: Brawl's rescaling factor
--                       (it shipped 0.3: about -20 %..+15 % for usual rolls;
--                       0.1 keeps a 4 s pace within about 3.7..4.4 s).
--   move_gait           how every fighter moves in a real-time fight: the
--                       exploration run ("Run"), not Brawl's distance-based
--                       Sprint (developer: "the same as out of combat move speed").
--   companion_ai        companions fight on Brawl's AI (the character you
--                       control never does). When Brawl finds nothing for a
--                       companion or an NPC ally to do, it attacks the nearest
--                       enemy with its weapon (data/ai.lua side).
--   companion_tactics   "Balanced" | "Offense" | "Defense" (Brawl's Pick.lua).
--   defensive_tactics_max_distance   how far "Defense" companions leave the party, m.
--   companion_ai_max_spell_level     highest spell level companions cast on their
--                       own; 0 = cantrips and level-0 abilities only (spell slots kept).
--   true_pause          Brawl's force-turn-based pause machinery (no key bound to it).
--   max_party_size      nil = leave BG3's party size alone (Brawl forced 4).
--   hitpoints_multiplier  Brawl's HP scaling for everyone in a fight (1 = vanilla).
--   log_rounds          log every 6 s round turnover (noisy; off by default).
--   fight_end           a fight ends when no enemy in it has been within near_m
--                       of the party for grace_s (checked every check_s;
--                       Server/Combat/FightEnd.lua, !dag_fight_end). Developer
--                       2026-10-12: "make sure the fight ends once there are no
--                       enemies aggroed around 30m".
return {
    enabled = true,
    round_s = 6.0,
    action_interval_s = 4.0,
    enemy_pace_s = { explorer = 10.0, balanced = 6.0, tactician = 5.0, honour = 4.0 },
    initiative_spread = 0.1,
    move_gait = "Run",
    companion_ai = true,
    companion_tactics = "Balanced",
    defensive_tactics_max_distance = 15,
    companion_ai_max_spell_level = 0,
    true_pause = true,
    max_party_size = nil,
    hitpoints_multiplier = 1.0,
    log_rounds = false,
    fight_end = { enabled = true, near_m = 30, grace_s = 4, check_s = 1.0 },
}
