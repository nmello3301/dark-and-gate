-- SPDX-License-Identifier: GPL-3.0-or-later
-- Bows and crossbows (DECISIONS 2026-10-12, docs/design/projectiles.md).
-- The player (Client/Combat/Bow.lua, Server/Combat/Bows.lua) and NPC /
-- companion archers (Server/Combat/NpcCombat.lua) use the same numbers.
--
--   draw_s              base draw time of every bow: hold LMB this long for a
--                       full draw (developer 2026-10-12: 3 s; a stat will scale
--                       it later -- Server/Combat/Bows.lua DrawTime is the hook)
--   min_draw            no shot below this draw fraction: letting go earlier
--                       cancels the draw
--   damage_at_min       damage multiplier at min_draw (x1 at full draw, linear)
--   speed_at_min        arrow speed multiplier at min_draw (x1 at full draw)
--   gravity_mps2        arrow drop (real gravity; 0 = straight flight)
--   drawing_speed_mult  movement speed while drawing (design: ~60 %)
--   release_tolerance_s the server accepts a release this much earlier than
--                       its own clock says (network latency)
--   recover_s           after a shot, the next draw can start this much later
--   guard_rate / release_guard_s  after the release the bow's draw / aim clips
--                       play this much faster for this long, in case the engine
--                       replays them before the release clip
--   families            by the ranged weapon's Proficiency Group: bow or
--                       crossbow, full-draw arrow speed (m/s), crossbow reload
return {
    arrow_spell        = "Projectile_MainHandAttack",
    draw_s             = 3.0,
    min_draw           = 0.3,
    damage_at_min      = 0.4,
    speed_at_min       = 0.45,
    gravity_mps2       = 9.81,
    drawing_speed_mult = 0.6,
    release_tolerance_s = 0.25,
    recover_s          = 0.5,
    guard_rate         = 8.0,
    release_guard_s    = 1.2,
    -- The draw on the body (playtest 2026-10-12, twice: the bow only came up
    -- after the release). BG3's ranged attack is Prepare (bow up) -> aim
    -- Loop -> Antic (the pull to full draw) -> Attack (release); vanilla
    -- plays the pull only at the shot. Ours: Prepare at raise_rate (at most
    -- raise_max_frac of the draw time), then the Antic stretched over the
    -- rest and held at pull_hold_frac of its length (clip rate hold_rate)
    -- until you let go; the shot (visual clone, Antic slot blanked) goes
    -- straight to the release clip.
    raise_rate         = 1.0,
    raise_max_frac     = 0.5,
    pull_hold_frac     = 0.85,
    hold_rate          = 0.002,
    -- Crossbows: R reloads (reload_s of the family); a loaded crossbow shoots
    -- on click. LMB on an empty one reloads too.
    reload_key         = "R",
    families = {
        Shortbows      = { kind = "bow",      speed_mps = 55 },
        Longbows       = { kind = "bow",      speed_mps = 65 },
        HandCrossbows  = { kind = "crossbow", speed_mps = 60, reload_s = 1.0 },
        LightCrossbows = { kind = "crossbow", speed_mps = 75, reload_s = 1.5 },
        HeavyCrossbows = { kind = "crossbow", speed_mps = 85, reload_s = 2.5 },
    },
    -- A ranged weapon in none of the families above counts as this one.
    default_family = "Shortbows",
    -- Q in first person: melee <-> ranged weapon set. The client presses
    -- BG3's own "toggle weapon set" key (toggle_key, F by default: it is
    -- ours in first person, so that one press is let through); if the set
    -- hasn't changed after check_s, the server switches it itself.
    weapon_set = { key = "Q", toggle_key = "F", check_s = 0.8 },
    -- NPC / companion archers: they draw draw_s like the player, keep facing
    -- the target, and aim at the release (lead + drop + data/ai.lua's error).
    npc = { face_every_ms = 400 },
}
