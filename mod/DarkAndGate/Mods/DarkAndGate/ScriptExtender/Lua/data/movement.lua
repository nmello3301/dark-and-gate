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
--   use_cast        play the JumpFlight Cast (take-off) clip first.
--   phases          which clips a jump plays, in order. 2026-10-09 playtest:
--                   the Recover (land) clip looked unneeded -> cast, ascend,
--                   descend only; descend ends at touchdown.
--   mode            "visual" = the DLL lifts the drawn body + camera (the
--                   real position stays on the ground); "real" = the
--                   character's real position follows the curve through
--                   BG3's falling state (RealJump.cpp, 2026-10-10, being
--                   tested): body, camera, hitbox and collision together,
--                   lands on what is under it. !dag_jump_mode real|visual.
--   strafe_sign     +1 / -1: A/D steering direction in the air (real mode).
--   land_speed      real mode: the curve ends steep (~13 m/s at k=3), which
--                   landed hard and stuck; the engine gets at most this fall
--                   speed for the touchdown.
--   max_clip_rate   the clips are fitted to the airtime (rate = clip time /
--                   airtime, 1.73 s of clips into 1.28 s = x1.35); capped here.
--   anims           BG3 animation-mapping ids for the JumpFlight phases (found by
--                   !dag_jump_anim_scan on 2026-10-09). A mapping id is the same for
--                   every weapon stance; the engine picks the stance's clip. dur is
--                   the clip length in seconds at normal speed (the ST clips).
--                   land = the Recover clip picked in the browser on 2026-10-09
--                   (docs/anim-picks-2026-10-09.txt; was b47955ba..., 1.70 s).
--   moving_anims    jump clips on a moving jump: "auto" plays them and, if the
--                   first one stops the walk (WASD held, speed drops under
--                   rooted_speed), skips clips on moving jumps for the rest of
--                   the session (logged); "on" always, "off" never. The lift
--                   and the horizontal movement are what matter while moving.
--   moving_speed    m/s above which a jump counts as "moving".
--   rooted_speed    m/s; under this with WASD held = the clip rooted the walk.
--
-- air_action: attacks / casts / the spell prepare loop take priority over the
-- jump clips (Client/Combat/Actions.lua).
--   swing_s         fallback action length for a swing with no clip length.
--   cast_s          how long a spell cast blocks the jump clips (BG3 plays the
--                   cast clip itself through UseSpell; extended while the
--                   character still reports SpellCastIsCasting).
--   resume_skip_s   on resume, a phase whose next phase is due within this
--                   long is skipped (straight to landing near touchdown).
--   land_after_s    an action still playing at touchdown delays the landing
--                   clip; it plays after the action if that ends within this
--                   long of touchdown, otherwise it is skipped (logged).
--
-- move: WASD ground speed (Client/Movement/Movement.lua, native lever in
-- MoveSpeed.cpp, docs/spikes/move-speed.md). Multipliers of the character's
-- own speeds, so they suit every race. Walk vs run stays BG3WASD's (walk by
-- default, Left Shift toggles).
--   walk_speed      x the natural walk speed (what BG3WASD's walk gives).
--   run_speed       x the template run speed.
--   speed_mult      x both, before the modifiers (Movement.AddModifier).
--   min_mult /      clamps on the effective multipliers.
--   max_mult
--   loco_sync       play the walk / run clips at the gait's multiplier, so
--                   the feet don't slide at other speeds.
--   loco_deadband   multipliers within this of 1.0 leave the clips alone.
--   idle_speed      m/s under which the character counts as standing.
--
-- prepare: spell prepare loop while a hotbar spell is armed
-- (Client/Combat/Prepare.lua). The clip ids come from the spell's own
-- SpellAnimation stats (slot 0 = prepare, slot 1 = loop; logged per spell).
--   enabled         on/off (also !dag_prepare_anims on|off). OFF since
--                   2026-10-10: the clip (Osi.PlayAnimation) blocked all
--                   movement while casting; animation comes in a later pass.
--   loop_fallback   mapping id looped when the spell has no loop clip
--                   (nil = hold after the prepare clip). The DFLT melee loop
--                   from the 2026-10-09 picks is a candidate.
--   refresh_margin_s re-trigger the loop this long before its clip ends.
--   unknown_dur_s   clip length assumed when the AnimationSet lookup fails
--                   (logged as "?"), so the loop still starts.

return {
    jump = {
        enabled       = true,
        height_m      = 0.80,   -- 2026-10-10: a little bigger (was 0.55)
        clip_air_s    = 0.80,
        duration_mult = 1.60,
        min_air_s     = 0.30,
        max_air_s     = 3.00,
        apex_flatness = 3.0,
        cooldown_s    = 0.15,
        land_lead_s   = 0.05,
        mode          = "real",   -- 2026-10-10 playtest: real jump approved
        strafe_sign   = -1,       -- A/D in the air (playtest: +1 was reversed)
        land_speed    = 3.0,      -- m/s, max fall speed handed back at the end of the curve
        -- 2026-10-10: no take-off windup (the Cast clip felt clunky; jumps
        -- that skipped it felt much better) -> ascend, descend only.
        use_cast      = false,
        phases        = { "ascend", "descend" },
        max_clip_rate = 1.6,
        anims = {
            cast    = { key = "f49c1788-7819-481f-9b83-2344d708e682", dur = 0.600 },
            ascend  = { key = "8ee67630-f1c7-441d-aaf6-fa4633c890da", dur = 0.600 },
            hang    = { key = "a2e3711c-1115-4971-9dbf-b657f09e9d47", dur = 0.567 },
            descend = { key = "ac61dc44-d236-4d19-920c-31ab9dd5a993", dur = 0.533 },
            land    = { key = "6495ac74-6183-41a4-8d3c-add157dd97a2", dur = 1.133 },
        },
        moving_anims  = "auto",
        moving_speed  = 0.8,
        rooted_speed  = 0.3,
    },
    move = {
        walk_speed    = 1.0,
        run_speed     = 1.0,
        speed_mult    = 1.0,
        min_mult      = 0.2,
        max_mult      = 3.0,
        loco_sync     = true,
        loco_deadband = 0.03,
        idle_speed    = 0.3,
    },
    air_action = {
        swing_s      = 0.9,
        cast_s       = 1.2,
        land_after_s = 0.6,
        resume_skip_s = 0.25,
    },
    prepare = {
        enabled          = false,
        loop_fallback    = nil,
        refresh_margin_s = 0.05,
        unknown_dur_s    = 1.0,
    },
}
