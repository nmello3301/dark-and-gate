-- SPDX-License-Identifier: GPL-3.0-or-later
-- Real-time fights: Brawl's loop (Server/Brawl/, wired by Server/BrawlAdapter.lua).
-- These replace the settings Brawl read from its own MCM page.
--
--   enabled             false = BG3's vanilla turn-based fights (also !dag_rt off|on)
--   round_s             one BG3 turn in seconds. Statuses, recharges and
--                       concentration tick once per round (DECISIONS 2026-10-12).
--   action_interval_s   Brawl's AI acts every this many seconds per character,
--                       faster for a high initiative roll, never under 1 s
--                       (TurnOrder.calculateActionInterval).
--   companion_ai        companions fight on Brawl's AI (the character you
--                       control never does).
--   companion_tactics   "Balanced" | "Offense" | "Defense" (Brawl's Pick.lua).
--   defensive_tactics_max_distance   how far "Defense" companions leave the party, m.
--   companion_ai_max_spell_level     highest spell level companions cast on their
--                       own; 0 = cantrips and level-0 abilities only (spell slots kept).
--   true_pause          Brawl's force-turn-based pause machinery (no key bound to it).
--   max_party_size      nil = leave BG3's party size alone (Brawl forced 4).
--   hitpoints_multiplier  Brawl's HP scaling for everyone in a fight (1 = vanilla).
--   log_rounds          log every 6 s round turnover (noisy; off by default).
return {
    enabled = true,
    round_s = 6.0,
    action_interval_s = 6.0,
    companion_ai = true,
    companion_tactics = "Balanced",
    defensive_tactics_max_distance = 15,
    companion_ai_max_spell_level = 0,
    true_pause = true,
    max_party_size = nil,
    hitpoints_multiplier = 1.0,
    log_rounds = false,
}
