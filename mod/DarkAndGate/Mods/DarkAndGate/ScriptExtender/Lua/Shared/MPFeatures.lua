-- SPDX-License-Identifier: GPL-3.0-or-later
-- Multiplayer kill switches (MP-4). The host sets them (!dag_mp_feature
-- <name> on|off, host only) and pushes them to every client (Server/MP.lua
-- MpFeatures); a joining player gets them in the welcome. All ON by default;
-- single player never changes them unless the host types the command.
--
--   jump_sync        other players' jumps drawn on your screen (Client/RemoteJump.lua)
--   swing_sync       the host plays remote players' swing clips (others see the swing)
--   cast_sync        cast stages (prepare / loop) relayed to the other players
--   proj_sync        projectile spells relayed to the other players' screens
--   rewind           hit checks against the target's recent positions (lag)
--   remote_playrate  other players' bow draws / clips at our play rate here
--   stealth          our stealth checks (off = BG3's own detection)
--   revive           companions run to revive downed players
--   spectate         downed: Space cycles allies' views
--   companion_v      V cycles your companions' mode
--   direct_move      the direct WASD controller (off = vanilla movement for everyone)
--
-- docs/playtest/mp-tonight.md says which switch to flip for which symptom.

local M = {}

M.NAMES = { "jump_sync", "swing_sync", "cast_sync", "proj_sync", "rewind", "remote_playrate",
            "stealth", "revive", "spectate", "companion_v", "direct_move" }

local on = {}
for _, n in ipairs(M.NAMES) do on[n] = true end
local listeners = {}

function M.Known(name) return on[name] ~= nil end
function M.On(name) return on[name] ~= false end

function M.All()
    local t = {}
    for _, n in ipairs(M.NAMES) do t[n] = on[n] end
    return t
end

function M.OnChange(fn) listeners[#listeners + 1] = fn end

-- Apply a { name = bool } table (from the host); returns the names that changed.
function M.Apply(tbl)
    local changed = {}
    for k, v in pairs(tbl or {}) do
        if on[k] ~= nil and on[k] ~= (v == true) then
            on[k] = (v == true)
            changed[#changed + 1] = k
        end
    end
    if #changed > 0 then
        for _, fn in ipairs(listeners) do pcall(fn, changed) end
    end
    return changed
end

function M.Line()
    local parts = {}
    for _, n in ipairs(M.NAMES) do parts[#parts + 1] = n .. "=" .. (on[n] and "on" or "OFF") end
    return table.concat(parts, " ")
end

return M
