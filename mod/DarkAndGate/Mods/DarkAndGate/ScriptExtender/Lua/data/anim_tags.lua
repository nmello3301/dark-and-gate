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

return {
    tags = {},
}
