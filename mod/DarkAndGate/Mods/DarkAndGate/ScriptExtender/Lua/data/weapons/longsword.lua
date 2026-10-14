-- SPDX-License-Identifier: GPL-3.0-or-later
-- Longsword: 3-swing chain data.
--
-- Each swing has:
--   anim         Osi animation handle string. Picked from Osi.PlayAnimation
--                probing; Spike 4 verified that triggering works but there
--                is no playback-speed API, so our timings must match the
--                animation's real timings.
--   windup_ms    time between LMB press and the start of the active window.
--   active_ms    duration the hit arc is live (and the ray fan sweeps).
--   recovery_ms  time after active before the next swing can start (the
--                melee cooldown below is longer, so it is what gates).
--   combo_ms     how long after the next swing is allowed (the melee
--                cooldown's end) another LMB chains to the next swing in the
--                chain. Beyond this, LMB resets to swing 1.
--
-- cooldown_mult  x the melee cooldown (data/combat.lua melee.cooldown_s,
--                swing start to swing start; DECISIONS 2026-10-13). The
--                weapon-family scaling hook: a dagger < 1, a greataxe > 1.
--   damage       base damage dealt on a non-crit limb hit. Zone multipliers
--                apply (head 2.0, torso 1.0, limbs 0.6).
--   reach_m      straight-line reach from the eye along forward.
--   arc_deg_h    horizontal arc the swing sweeps (yaw total).
--   arc_deg_v    vertical arc from the camera forward (positive is up).
--   arc_rays     number of rays in the fan. 7 is enough for feel; up to 15
--                for precision tests via !dag_swing_debug.
--
-- Scope note: with no anim-speed API (M1a archive line), we don't try to
-- time-stretch animations here. If a swing's active window ends before the
-- animation would land visually, the user sees a hit "early" — tune the
-- active_ms against the animation.
--
-- 2026-10-08: Osi.PlayAnimation takes a GUID, not a template-name string.
-- Round 2 used "GSB_Melee_1H_Base_Chain1" etc. and Osi silently rejected
-- them — swings logged but no visible animation. Spike 4 verified this
-- combat anim GUID plays end-to-end:
--   01932f4d-a39b-4ea8-96ba-aef3e6b4c2d8  (Brawl's LOOPING_COMBAT_ANIMATION_ID)
-- For now ALL three swings in the chain use that same anim so the user
-- sees Gale swing on LMB. Per-swing R2L / L2R / Overhead anim GUIDs are
-- a separate asset lookup; the hit-detection and chain-timing systems are
-- what matters for M1b feel.
local PROBE_SWING_ANIM = "01932f4d-a39b-4ea8-96ba-aef3e6b4c2d8"

return {
    name = "longsword",
    cooldown_mult = 1.0,
    chain = {
        {
            name       = "swing1_R2L",
            anim       = PROBE_SWING_ANIM,
            windup_ms   = 120,
            active_ms   = 180,
            recovery_ms = 120,
            combo_ms    = 400,
            damage      = 8.0,
            reach_m     = 2.2,
            arc_deg_h   = 100,
            arc_deg_v   = 40,
            arc_rays    = 7,
            swing_dir   = "R2L",
        },
        {
            name       = "swing2_L2R",
            anim       = PROBE_SWING_ANIM,
            windup_ms   = 100,
            active_ms   = 180,
            recovery_ms = 120,
            combo_ms    = 400,
            damage      = 8.0,
            reach_m     = 2.2,
            arc_deg_h   = 100,
            arc_deg_v   = 40,
            arc_rays    = 7,
            swing_dir   = "L2R",
        },
        {
            name       = "swing3_overhead",
            anim       = PROBE_SWING_ANIM,
            windup_ms   = 160,
            active_ms   = 200,
            recovery_ms = 220,
            combo_ms    = 0,  -- chain resets after overhead
            damage      = 12.0,
            reach_m     = 2.4,
            arc_deg_h   = 40,
            arc_deg_v   = 90,  -- overhead comes down
            arc_rays    = 9,
            swing_dir   = "overhead",
        },
    },
    zones = {
        head  = 2.0,
        torso = 1.0,
        limbs = 0.6,
    },
}
