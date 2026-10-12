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
    log = true,
}
