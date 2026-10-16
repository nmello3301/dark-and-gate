-- SPDX-License-Identifier: GPL-3.0-or-later
-- RPG Mode (DECISIONS 2026-10-15, Server/Combat/RpgMode.lua): a cleared
-- fight leaves a flag; switched ON, the fight's enemies come back (fresh
-- copies) once the party is away. Overridable without a repack by
-- %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\DarkAndGate\rpgmode.json
-- (top-level keys; !dag_rpg_reload).
--
--   rpg_mode_enabled        false: no flags spawn, existing flags respawn nothing
--   respawn_radius          m: every party member at least this far from the
--                           encounter's centre (the enemies' start positions)
--   respawn_min_delay       s of play since the flag went ON
--   respawn_unique_enemies  false: story / global / unique characters stay dead
--                           (the rest of the encounter still comes back)
--   flag_template /         item root templates for the flag (OFF / ON). nil =
--   flag_template_on        a BG3 banner found by name at first use (logged;
--                           !dag_rpg_flag_templates lists the candidates)
--   check_s                 how often the server checks (s)
--   end_settle_s            after a fight ends, wait this long (BG3 flickers
--                           combat ids mid-fight) before deciding "cleared"
return {
    rpg_mode_enabled       = true,
    respawn_radius         = 100,
    respawn_min_delay      = 60,
    respawn_unique_enemies = false,
    flag_template          = nil,
    flag_template_on       = nil,
    flag_name_patterns     = { "banner" },
    flag_name_exclude      = { "wall", "hang", "tapestry", "broken", "destroyed", "fx", "scroll", "pole_only", "ruin" },
    check_s                = 2.0,
    end_settle_s           = 2.0,
}
