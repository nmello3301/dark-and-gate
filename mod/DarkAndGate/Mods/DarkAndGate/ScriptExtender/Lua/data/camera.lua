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
}
