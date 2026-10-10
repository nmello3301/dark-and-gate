-- SPDX-License-Identifier: GPL-3.0-or-later
-- Shooting spells have no practical max range in first person
-- (data/spells.lua: unlimited_range, stat_range_m).
--
-- BG3 refuses or walks the caster into range when a cast point is beyond
-- the spell's TargetRadius (Fire Bolt: 18 m). We raise TargetRadius of the
-- spells marked unlimited_range. This changes how the spell is aimed, not
-- what it does (DESIGN: spells stay BG3 data).
--
-- Applied on StatsLoaded (no sync needed while loading) and once at
-- registration for a Lua `reset` mid-session (the server then Syncs the
-- entry to clients). Before / after values are logged.

local Log    = Ext.Require("Shared/Log.lua")
local spells = Ext.Require("data/spells.lua")

local M = {}

local function apply(why, sync)
    local want = spells.stat_range_m or 100
    for id, def in pairs(spells.spells) do
        if def.unlimited_range then
            local ok, err = pcall(function()
                local st = Ext.Stats.Get(id)
                if not st then error("no stats entry") end
                local before = st.TargetRadius
                local okS = pcall(function() st.TargetRadius = tostring(want) end)
                if not okS or tostring(st.TargetRadius) == tostring(before) then
                    pcall(function() st.TargetRadius = want end)
                end
                if sync then pcall(function() st:Sync() end) end
                Log.Write(string.format("SpellRange: %s TargetRadius %s -> %s (%s%s)", id, tostring(before),
                    tostring(st.TargetRadius), why, sync and ", synced" or ""))
            end)
            if not ok then Log.Write("SpellRange: " .. id .. " ERROR " .. tostring(err)) end
        end
    end
end

function M.Register(context)
    Ext.Events.StatsLoaded:Subscribe(function() apply("StatsLoaded", false) end)
    -- After a Lua reset the stats are already loaded.
    apply("register", context == "Server")
end

return M
