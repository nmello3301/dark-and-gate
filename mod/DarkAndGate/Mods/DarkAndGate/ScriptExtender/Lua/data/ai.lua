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
--   targets            the enemies' target choice (playtest 2026-10-14: "all the
--                      enemies target or wanted to target me, ignoring their
--                      closest opponents"; Server/Combat/NpcCombat.lua). Brawl
--                      kept an enemy's first pick while it stayed within 12 m.
--                      Now every action re-checks every opponent in the fight
--                      (each player, companion and NPC ally) by an effective
--                      distance: metres away
--                        - threat_m   it attacked this enemy in the last threat_s
--                        + spread_m   per other enemy already on it (at most
--                                     spread_max), so a pack spreads over your side
--                        - stick_m    it is the current target (no flip-flopping)
--                      Brawl's own weighing (it also prefers wounded opponents
--                      and those in sight, and picks heals) gets this distance;
--                      a better opponent than the current one makes it pick
--                      again. Opponents farther than max_m (Brawl's engagement
--                      range) don't count. log: each pick and switch, with the
--                      distances and why. !dag_ai_targets on|off (off = Brawl's
--                      sticky first pick, as before).
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
-- Following, out of fights (Server/Companions.lua; playtest 2026-10-14: "I
-- went up the cliff and Shadowheart did not follow me"). Follow is BG3's own
-- party follow (the companion chained to its player): it walks the nav grid,
-- climbs and takes the long way. BG3's followers also jump after a leader who
-- uses BG3's Jump, but our real jump is not that action, so a ledge reached by
-- jumping leaves them below. follow.assist watches each Follow companion
-- (every check_s; not in fights, dialogues, camp, or when its player unchained
-- it):
--   near_m             closer than this: BG3's follow is doing its job
--   stuck_s            farther than near_m and not closing in by progress_m
--                      for this long, BG3's pathfinder is asked (every
--                      path_check_s, ladders allowed, never while its player
--                      is in the air): no walking path twice in a row, it is
--                      caught up: teleported to its player (BG3's TeleportTo)
--   catchup_m          when BG3 does find a walking path (or can't tell), it
--                      is caught up only from this far, after path_stuck_s
--                      without closing in (BG3 may be taking the long way)
--   cooldown_s         after a catch-up, it is left alone this long
--   after_scene_s      quiet after a dialogue / level start
--   wait_hold_s        Wait: BG3 re-chaining a companion this soon after V is
--                      undone, at most wait_redetach_max times (playtest
--                      2026-10-14: Wait detached Shadowheart and Gale and BG3
--                      chained them again at once)
--   log_every_s        a companion left alone for a reason is logged once,
--                      and again after this long
-- !dag_follow [status|on|off] (server or client console).
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
    targets = { enabled = true, stick_m = 2.0, threat_m = 4.0, threat_s = 8, spread_m = 1.5, spread_max = 3, max_m = 40, log = true },
    pace = { slack_ms = 250, retry_pad_ms = 50 },
    side = { fallback = true, fallback_range_m = 25, melee_m = 3.0, log_every_s = 15, stall_paces = 3, stall_min_s = 10 },
    follow = { assist = true, check_s = 1.0, near_m = 12, progress_m = 2.0, stuck_s = 5, path_check_s = 2, catchup_m = 25,
               path_stuck_s = 20, cooldown_s = 10, after_scene_s = 5, wait_hold_s = 5, wait_redetach_max = 3, log_every_s = 20 },
    log = true,
}
