-- SPDX-License-Identifier: GPL-3.0-or-later
-- First-person movement tuning.
--
-- jump: a floaty, straight-up jump on Space. The lift is VISUAL ONLY
-- (body + camera on the local client, done by the DLL); the character's
-- real position never leaves the ground, so a jump does not clear
-- obstacles. See docs/DECISIONS.md 2026-10-09.
--
--   height_m        apex height of the lift, metres.
--   clip_air_s      base airtime before duration_mult. The JumpFlight clips
--                   are fitted to it (0.80 x 1.60 = 1.28 s felt right in the
--                   2026-10-09 playtest).
--   duration_mult   floatiness: total airtime = clip airtime * duration_mult.
--                   1.0 = BG3's own timing, 1.6 = noticeably floaty.
--   min_air_s /     clamps on the resulting airtime.
--   max_air_s
--   apex_flatness   shape of the lift curve: y = h * (1 - |2u - 1|^k), u = t / T.
--                   k = 2 is a plain parabola; 3-4 hangs longer near the apex.
--   cooldown_s      after landing, before the next jump is accepted.
--   land_lead_s     the landing (Recover) clip starts this long before touchdown.
--   use_cast        play the JumpFlight Cast (crouch/takeoff) clip first.
--                   Off: the lift starts on the key press, so a crouch
--                   would play while already rising.
--   anims           BG3 animation-mapping ids for the JumpFlight phases (found by
--                   !dag_jump_anim_scan on 2026-10-09). A mapping id is the same for
--                   every weapon stance; the engine picks the stance's clip. dur is
--                   the clip length in seconds at normal speed (the ST clips).

return {
    jump = {
        enabled       = true,
        height_m      = 0.55,
        clip_air_s    = 0.80,
        duration_mult = 1.60,
        min_air_s     = 0.30,
        max_air_s     = 3.00,
        apex_flatness = 3.0,
        cooldown_s    = 0.15,
        land_lead_s   = 0.05,
        use_cast      = false,
        anims = {
            cast    = { key = "f49c1788-7819-481f-9b83-2344d708e682", dur = 0.600 },
            ascend  = { key = "8ee67630-f1c7-441d-aaf6-fa4633c890da", dur = 0.600 },
            hang    = { key = "a2e3711c-1115-4971-9dbf-b657f09e9d47", dur = 0.567 },
            descend = { key = "ac61dc44-d236-4d19-920c-31ab9dd5a993", dur = 0.533 },
            land    = { key = "b47955ba-760c-4e20-a1f0-db25ab1c54c3", dur = 1.700 },
        },
    },
}
