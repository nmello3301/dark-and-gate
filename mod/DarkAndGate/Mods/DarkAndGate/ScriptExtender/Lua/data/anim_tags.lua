-- SPDX-License-Identifier: GPL-3.0-or-later
-- Animation tags picked in the animation browser (!dag_animlib).
--
-- Paste the output of !dag_animlib_export here to make picks permanent.
-- Runtime picks (DarkAndGate/anim-tags.txt) override these.
--
-- A tag is a BG3 animation MAPPING id, not a clip file: the engine resolves
-- the mapping id through each character's own AnimationSet, so one tag can
-- serve every rig. `overrides` holds per-rig picks when a rig needs a
-- different mapping id. If a rig has no clip for a tag at all, the runtime
-- falls back to that rig's DFLT clip of the same category and phase.
--
-- Tags used by the mod: swing1, swing2, swing3, jump_start, jump_loop,
-- jump_land, block, parry, hit_react (plus any custom text).
--
--   tags = {
--       swing1 = { key = "<mapping id>", res = "<resource id>", file = "<clip>",
--                  rig = "HUM_M", dur = 1.2,
--                  overrides = { HUM_F = { key = "...", res = "...", file = "...", dur = 1.1 } } },
--   }

-- 2026-10-09: the swing chain uses the developer's picks
-- (docs/anim-picks-2026-10-09.txt). The automatic swing-1 pick was BG3's
-- RANGED right-hand attack (20054426..., CMBT_Range_RHand_01_Attack), which
-- has no clip in a melee / unarmed stance -- the first click played nothing.
-- Mapping ids resolve through the character's weapon stance.
return {
    tags = {
        swing1 = { key = "f4ac302b-1569-404f-bd52-1fe443e265df", res = "05fd937b-00ab-cd26-d1a6-595ab43af2b5",
                   file = "HUM_M_Rig_1HPSH_CMBT_Melee_RHand_01_Attack", rig = "HUM_M", dur = 0.50 },
        swing2 = { key = "722df2d7-7898-4b0b-b930-5a850b55ccf0", res = "82da4469-8ea7-d2ad-ebd0-e1fcff5943ea",
                   file = "HUM_M_Rig_1HSSH_CMBT_Melee_LHand_01_Attack", rig = "HUM_M", dur = 0.47 },
        swing3 = { key = "f4ac302b-1569-404f-bd52-1fe443e265df", res = "05fd937b-00ab-cd26-d1a6-595ab43af2b5",
                   file = "HUM_M_Rig_1HPSH_CMBT_Melee_RHand_01_Attack", rig = "HUM_M", dur = 0.50 },
    },
}
