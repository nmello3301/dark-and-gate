-- SPDX-License-Identifier: GPL-3.0-or-later
-- Real-time combat rules (DECISIONS 2026-10-12): shields, downed / bleed-out
-- / revive, the melee cooldown. Live knobs: !dag_shield_pct, !dag_bleedout,
-- !dag_revive_time, !dag_melee_cooldown.
return {
    -- Melee cooldown (developer 2026-10-13): one swing per cooldown_s,
    -- counted from swing start to swing start, so LMB spam can't out-swing
    -- a fight. A starting value; the weapon's cooldown_mult scales it
    -- (data/weapons/*.lua), and later stats / perks will (docs/DESIGN.md
    -- "Melee cooldown"). Shared/MeleeCooldown.lua reads it on both sides.
    melee = {
        cooldown_s     = 1.5,
        buffer_s       = 0.3,   -- a click this close to the end of the cooldown waits and swings on time; earlier clicks are ignored
        server_slack_s = 0.4,   -- server: a new swing's first hit may arrive this much sooner than the cooldown (swings hit at different points of their windup / active window; lag)
        server_slack_frac = 0.5, -- ...but at most this share of the cooldown (fast high-DEX swings, Meta-Points)
        max_swing_rate = 4.0,   -- a cooldown shorter than the swing plays the swing (and its clip) faster, at most this much (Meta-Points DEX, 2026-10-15)
    },
    -- No fall damage (developer 2026-10-15): party members carry BG3's
    -- IgnoreFallDamage() boost (Server/Combat/NoFallDamage.lua). true = BG3's
    -- fall damage back.
    fall_damage = false,
    -- Passive shields: an equipped shield takes this share of the damage of any
    -- melee hit, arrow or projectile spell that lands on it.
    shield = {
        reduction = 0.40,
        -- A disc on the shield arm, facing forward (character frame, metres):
        radius_m  = 0.35,
        height_m  = 1.15,   -- disc centre above the feet
        fwd_m     = 0.35,   -- in front of the body axis
        side_m    = 0.18,   -- towards the shield arm (side_sign flips it if the
        side_sign = 1,      -- disc shows on the wrong side in !dag_shield_debug)
        fwd_sign  = 1,      -- the Transform's local +Z is the facing; corrected
                            -- by itself if walking characters face -Z (logged)
    },
    -- No reactions in real time (Server/Combat/NoReactions.lua): every
    -- interrupt is switched off in BG3's own reaction settings, so nothing
    -- asks (Tides of Chaos, Shield, Divine Smite...). !dag_rt off puts the
    -- player's own switches back.
    reactions = {
        party_always = true,   -- party members' switches stay off whenever real time is on, in and out of fights (a fight's opener can ask too); false = only during real-time fights
        guard_s      = 1.0,    -- how often the party's switches are checked again (an interrupt added mid-fight, a new party member)
    },
    -- Downed players and companions.
    downed = {
        bleedout_s       = 180,   -- dead after this long downed (paused while revived)
        revive_s         = 3.0,   -- hold F this long
        revive_range_m   = 1.5,   -- reviver within this distance of the body
        revive_hp        = 1,     -- HP after a revive
        companion_range_m = 25,   -- companions come to revive from this far
        control_back_tries = 3,   -- BG3 moves your control off your downed body: handed back this many times per down
        give_up_confirm_s = 5,    -- nobody standing: Give up (button / G) a second time within this ends the game
        orbit_distance_m = 3.5,   -- downed camera: distance from the body
        orbit_up_m       = 0.6,   -- the point it circles, above the body's root
        orbit_pitch_min  = -10,   -- degrees (+ = above, looking down)
        orbit_pitch_max  = 70,
        orbit_spin_deg_s = 120,   -- A / D or LMB / RMB held
        orbit_tilt_deg_s = 60,    -- W / S held
    },
}
