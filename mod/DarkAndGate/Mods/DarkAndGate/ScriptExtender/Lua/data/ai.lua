-- SPDX-License-Identifier: GPL-3.0-or-later
-- Enemy (and companion) AI on our combat rules (Server/Combat/NpcCombat.lua,
-- DECISIONS 2026-10-12). NPCs must not aim better than a decent player.
-- Per-difficulty tables come later; these are the one set for now.
-- Live knobs (server, also from the client console): !dag_ai_aim <deg>,
-- !dag_ai_react <ms>, !dag_ai on|off, !dag_ai_debug on|off.
--
-- Ranged (archers, projectile spells) shoot through our projectile system:
--   reaction_ms        time between deciding to shoot and releasing; the aim
--                      is taken at the START of this delay, like a human
--                      committing to a shot, so the target can move meanwhile
--   reaction_jitter_ms random extra delay, 0..this
--   aim_error_deg      the shot leaves inside a cone of this half-angle
--                      around the aimed direction (uniform over the disc)
--   lead_skill         0 = shoots where the target IS, 1 = perfect lead on
--                      the target's current velocity; the actual lead is
--                      this times a random lead_jitter[1]..lead_jitter[2]
--   aim_height         where on the target's body they aim, fraction of the
--                      cylinder height (0.6 = upper chest)
-- Melee goes through our swing system:
--   weapon             data/weapons/<name>.lua chain (timings, reach, arcs),
--                      the player's own swing data
--   reaction_ms /      decision -> swing start (the NPC turns to face you)
--   reaction_jitter_ms
--   anim_lead_ms       added to the windup: BG3's attack animation (the
--                      visual clone DAG_V_Target_MainHandAttack, cast through
--                      the request queue) starts about this much later
--   commit_turn        the swing direction is fixed at windup start; a
--                      target that steps out of the arc during the windup
--                      is missed (dodgeable)
--   damage             "weapon" = the NPC's equipped weapon damage dice +
--                      STR (DEX for finesse / ranged), no attack roll
--   unarmed_damage     dice with no melee weapon equipped
--   fallback_damage    when the weapon's stats can't be read
--   eye_frac           the attacker's eye height, fraction of its hitbox
-- Spells that are neither (BG3 casts them):
--   cast_time_s        our cast time before BG3's cast goes out; area / cone
--                      spells commit their target point (with aim_error_deg)
--                      at the start of it, so you can step out of the area
--   busy_pad_ms        after an action, before Brawl's next pulse may act
-- Targets:
--   skip_downed_targets  nobody attacks a downed character: hits can't kill one
--                      (our bleed-out, Server/Combat/Downed.lua), so enemies go
--                      for whoever still stands (playtest 2026-10-13: the imps
--                      kept shooting a downed player for 3 minutes)
-- The pace (data/realtime.lua: your side action_interval_s, enemies
-- enemy_pace_s by BG3's difficulty, Server/Combat/Pace.lua):
--   pace.slack_ms      a pulse less than a pace (minus this) after the
--                      fighter's last action started, or while that action
--                      still runs, waits: the fighter acts as soon as both
--                      are over (+ pace.retry_pad_ms), not a whole pace later
-- Your side (developer 2026-10-12: companions and allies "play for the
-- players side"), companions and NPC allies:
--   side.fallback      when Brawl's AI finds nothing for one to do, it attacks
--                      the nearest enemy in sight within side.fallback_range_m
--                      with its weapon: its bow / crossbow when its archetype
--                      is ranged and the enemy is farther than side.melee_m,
--                      else its melee weapon (our swing / shot)
--   side.log_every_s   why one did nothing is logged once per reason, and
--                      again after this long
--   side.stall_paces   one that got no AI pulse for this many paces (at least
--                      side.stall_min_s) in a fight is logged with its state,
--                      and its pulse is restarted when Brawl would run it
return {
    enabled = true,
    ranged = {
        reaction_ms = 350,
        reaction_jitter_ms = 250,
        aim_error_deg = 3.0,
        lead_skill = 0.6,
        lead_jitter = { 0.6, 1.2 },
        aim_height = 0.6,
    },
    melee = {
        weapon = "longsword",
        reaction_ms = 200,
        reaction_jitter_ms = 150,
        anim_lead_ms = 150,
        commit_turn = true,
        damage = "weapon",
        unarmed_damage = "1d4",
        fallback_damage = 4,
        eye_frac = 0.85,
    },
    cast_time_s = 1.5,
    busy_pad_ms = 300,
    skip_downed_targets = true,
    pace = { slack_ms = 250, retry_pad_ms = 50 },
    side = { fallback = true, fallback_range_m = 25, melee_m = 3.0, log_every_s = 15, stall_paces = 3, stall_min_s = 10 },
    log = true,
}
