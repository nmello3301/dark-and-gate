-- SPDX-License-Identifier: GPL-3.0-or-later
-- Crouch = sneaking, detection (Server/Combat/Stealth.lua, DECISIONS 2026-10-12).
--   check_s             one stealth check per NPC per this long while you stay in its cone
--   update_hz           cone tests per second
--   max_range_m         NPCs farther than this are not tested
--   default_sight_m /   when an NPC's Sight component can't be read
--   default_fov_deg     (BG3's _Base: Sight 1600 = 16 m, FOV 90)
--   stealth_skill_index Stats.Skills index of Stealth (SkillId 6, Lua arrays from 1)
--   silence_vanilla     switch off vanilla's own sneaker spotting (SetCanSpotSneakers)
--                       for the NPCs we check, restored afterwards
return {
    enabled = true,
    check_s = 6,
    update_hz = 4,
    max_range_m = 30,
    default_sight_m = 16,
    default_fov_deg = 90,
    stealth_skill_index = 7,
    silence_vanilla = true,
}
