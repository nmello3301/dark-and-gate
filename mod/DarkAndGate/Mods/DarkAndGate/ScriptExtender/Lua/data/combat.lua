-- SPDX-License-Identifier: GPL-3.0-or-later
-- Real-time combat rules (DECISIONS 2026-10-12): shields, downed / bleed-out
-- / revive. Live knobs: !dag_shield_pct, !dag_bleedout, !dag_revive_time.
return {
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
