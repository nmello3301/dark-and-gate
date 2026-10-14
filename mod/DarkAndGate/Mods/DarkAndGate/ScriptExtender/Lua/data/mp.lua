-- SPDX-License-Identifier: GPL-3.0-or-later
-- Multiplayer tuning (docs/design/multiplayer.md "Lag tolerance").
--   rewind_ms        a melee hit counts if the target was in reach at any
--                    of its positions in the last rewind_ms (the attacker
--                    saw an older position). Live: !dag_mp_rewind <ms>.
--                    Switch: rewind (off = only the current position).
--   history_ms       how long the host keeps positions (>= rewind_ms).
--   sample_ms        how often it samples them.
--   eye_horizontal_m the eye a client sends must be this close to its own
--                    character (horizontal) ...
--   eye_up_m         ... and between eye_down_m below and eye_up_m above its
--   eye_down_m       feet; else the hit claim is rejected (logged).
return {
    rewind_ms = 250,
    history_ms = 600,
    sample_ms = 100,
    eye_horizontal_m = 2.5,
    eye_up_m = 4.0,
    eye_down_m = 1.0,
}
