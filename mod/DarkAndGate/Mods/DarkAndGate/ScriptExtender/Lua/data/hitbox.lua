-- SPDX-License-Identifier: GPL-3.0-or-later
-- Character hitboxes: one vertical cylinder per character.
--
--   radius_m / height_m   cylinder size (default body; no per-race sizes yet).
--   base_m                cylinder bottom above the feet (0 = from the ground).
--   zones                 hit zone by height fraction of the cylinder, top
--                         down: a hit at or above `head` is a head hit, at or
--                         above `torso` a torso hit, below that limbs.
--   zone_mult             damage multiplier per zone (server applies it).
--   reach_slack_m         server-side tolerance on melee reach (lag, aim assist).
-- A jumping character's cylinder rises with its visual lift (Shared/Hitbox.lua).

return {
    radius_m = 0.35,
    height_m = 1.80,
    base_m   = 0.00,
    zones = {
        head  = 0.85,
        torso = 0.45,
    },
    zone_mult = {
        head  = 2.0,
        torso = 1.0,
        limbs = 0.6,
    },
    reach_slack_m = 1.0,
}
