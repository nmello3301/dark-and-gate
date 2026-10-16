-- SPDX-License-Identifier: GPL-3.0-or-later
-- Per-race eye heights (metres). The native plugin reads a single
-- `eye_height` number from native-config.toml; this table drives what
-- Lua writes there each time the controlled character changes.
--
-- Tune these in-game: the ones here are first-pass guesses.

return {
    -- Default fallback if the race tag doesn't match a key below.
    Default = 1.65,

    -- Larian race tags from Public/Shared/Races. If a race ships with
    -- a sub-tag (Drow under Elf, etc.), add it here as needed.
    Human        = 1.68,
    HalfElf      = 1.65,
    Tiefling     = 1.68,
    Elf          = 1.75,
    Drow         = 1.75,
    HalfOrc      = 1.80,
    Dragonborn   = 1.90,
    Githyanki    = 1.78,
    Dwarf        = 1.12,
    Halfling     = 0.90,
    Gnome        = 0.88,

    -- Not a race tag (Shared/NativeBridge.lua only looks races up by tag).
    -- Foreign camera (FullPov.lua -> tools/native Pov.cpp): in fights BG3
    -- sometimes renders through a camera that follows nobody or looks at
    -- someone else (brains fight at the crashed nautiloid, 2026-10-14: up to
    -- ~4 s). First person stays on your head; this is what the view
    -- direction does meanwhile. !dag_pov_foreign changes it for a session.
    -- Mouse-look sensitivity (developer 2026-10-16): how fast the first-person
    -- camera turns with the mouse, x BG3's own rotation speed. The player sets
    -- it with the slider on Dark and Gate's page in Mod Configuration Menu
    -- (MCM_blueprint.json "look_sensitivity", same range); this is the value
    -- without MCM. !dag_look_sens <x> overrides it for a session.
    look_sensitivity = { default = 1.0, min = 0.1, max = 3.0 },
    foreign_camera = {
        follow   = true,   -- true: keep following your mouse; false: hold the last direction (the old freeze)
        mouse_ms = 300,    -- BG3's camera turning counts as your mouse only this long after it moved (0 = always)
        ease_ms  = 150,    -- back on you: ease this long onto BG3's camera instead of snapping (0 = snap)
    },
}
