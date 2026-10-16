-- SPDX-License-Identifier: GPL-3.0-or-later
-- Meta-Points (DECISIONS 2026-10-15, docs/DESIGN.md "Meta-Points"): a point
-- pool per party member, parallel to BG3's ability scores (which it never
-- reads or changes), that scales Dark and Gate's real-time combat knobs.
--
-- These are the defaults. The server writes them to
-- %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\DarkAndGate\metapoints.json
-- on first run; edit that file and type !dag_meta_reload (no repack). In
-- co-op the host's file decides; each player's own file only sets their
-- hotkey. Delete the file to get these defaults back.
--
--   points_per_level     points per character level (8 x 12 = 96 at level 12)
--   max_per_stat         most points one stat can take
--   respec_mode          "camp" (Reset all points only in camp) | "anywhere" | "off"
--   min_action_interval  engine safety, not balance: the shortest effective
--                        cast, bow draw and melee cooldown, in seconds, so a
--                        held button can't fire every frame (0 is allowed)
--   enemy_hp_mult        enemies' max HP x this when they join a fight
--   enemy_damage_mult    damage enemies deal x this
--   hotkey               opens the Meta-Points menu (SDL key name)
--   notify_level_up      toast when a level-up brings points to spend
--   spell_damage_hook    how INT's spell damage is applied: "before" = BG3's
--                        own damage scaled before it lands (SE BeforeDealDamage,
--                        resistances apply once), "after" = extra damage right
--                        after the hit, "off". "before" checks itself on the
--                        first hits and switches to "after" if BG3 ignores it.
--   effects              one entry per effect. points = { {points, value}, ... }
--                        breakpoints, linear between them, flat after the last.
--                        kind: "mult" (x value), "time" (value x the base
--                        time named by `base`), "fraction" (an absolute share).
--                        controlled_only: only while a player controls the
--                        character (companions on AI don't use it).
--                        A new effect (WIS parry, sneak) is a new entry here
--                        plus the code that reads it (MetaPoints.Value).
return {
    version             = 1,
    points_per_level    = 8,
    max_per_stat        = 96,
    stats               = { "STR", "DEX", "INT", "WIS", "CON", "CHA" },
    stat_names          = { STR = "Strength", DEX = "Dexterity", INT = "Intelligence",
                            WIS = "Wisdom", CON = "Constitution", CHA = "Charisma" },
    respec_mode         = "camp",
    min_action_interval = 0.05,
    enemy_hp_mult       = 1.0,
    enemy_damage_mult   = 1.0,
    hotkey              = "P",
    notify_level_up     = true,
    spell_damage_hook   = "before",
    effects = {
        { id = "melee_damage",    stat = "STR", label = "Melee damage",    kind = "mult",
          points = { { 0, 1.0 }, { 48, 3.0 }, { 96, 4.0 } } },
        { id = "bow_draw",        stat = "STR", label = "Bow draw time",   kind = "time", base = "bow_draw",
          points = { { 0, 1.0 }, { 67, 0.10 }, { 96, 0.0 } } },
        { id = "ranged_damage",   stat = "DEX", label = "Ranged damage",   kind = "mult",
          points = { { 0, 1.0 }, { 48, 3.0 }, { 96, 4.0 } } },
        { id = "attack_cooldown", stat = "DEX", label = "Attack cooldown", kind = "time", base = "melee_cooldown",
          controlled_only = true,
          points = { { 0, 1.0 }, { 86, 0.10 }, { 96, 0.10 } } },
        { id = "spell_damage",    stat = "INT", label = "Spell damage",    kind = "mult",
          points = { { 0, 1.0 }, { 48, 3.0 }, { 96, 4.0 } } },
        { id = "max_mana",        stat = "INT", label = "Max mana",        kind = "mult",
          points = { { 0, 1.0 }, { 96, 5.0 } } },
        { id = "cast_time",       stat = "WIS", label = "Cast time",       kind = "time", base = "cast_time",
          points = { { 0, 1.0 }, { 58, 0.075 }, { 96, 0.0 } } },
        { id = "block",           stat = "CON", label = "Shield block",    kind = "fraction",
          points = { { 0, 0.40 }, { 96, 0.85 } } },
        { id = "jump_height",     stat = "CON", label = "Jump height",     kind = "mult", controlled_only = true,
          points = { { 0, 1.0 }, { 96, 10.0 } } },
        { id = "move_speed",      stat = "CHA", label = "Move speed",      kind = "mult", controlled_only = true,
          points = { { 0, 1.0 }, { 96, 4.0 } } },
    },
}
