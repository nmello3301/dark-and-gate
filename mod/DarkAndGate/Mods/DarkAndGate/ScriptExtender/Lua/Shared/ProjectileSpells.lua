-- SPDX-License-Identifier: GPL-3.0-or-later
-- The two clones each projectile spell needs (data/projectiles.lua):
--   DAG_V_<spell>  "visual": the same cast, animation, trail and look, no
--                  effect at all -- BG3 flies it, we remove it at our hit;
--   DAG_I_<spell>  "impact": instant, no costs -- applied at our hit with
--                  Osi.CreateExplosion / CreateExplosionAtPosition.
-- Made with Ext.Stats.Create(name, "SpellData", parent) on StatsLoaded on
-- both sides (no sync needed while loading), and once at registration for a
-- Lua `reset` mid-session (the server then Syncs). The spell's own entry is
-- never changed (DESIGN: spells stay BG3 data).

local Log  = Ext.Require("Shared/Log.lua")
local data = Ext.Require("data/projectiles.lua")

local M = {}

function M.VisualId(spell) return "DAG_V_" .. spell end
function M.ImpactId(spell) return "DAG_I_" .. spell end

local function setField(st, k, v)
    local ok, err = pcall(function() st[k] = v end)
    if not ok and tonumber(v) then ok, err = pcall(function() st[k] = tonumber(v) end) end
    return ok, err
end

local function addFlags(st, flags)
    if not flags or #flags == 0 then return true end
    local list, have = {}, {}
    pcall(function() for _, f in ipairs(st.SpellFlags) do list[#list + 1] = tostring(f); have[tostring(f)] = true end end)
    for _, f in ipairs(flags) do if not have[f] then list[#list + 1] = f end end
    local ok, err = pcall(function() st.SpellFlags = list end)
    return ok, err
end

local function make(name, parent, overrides, sync)
    local st = nil
    pcall(function() st = Ext.Stats.Get(name) end)
    local how = "updated"
    if not st then
        local ok, r = pcall(Ext.Stats.Create, name, "SpellData", parent)
        if not ok or not r then return "CREATE FAILED " .. tostring(r) end
        st, how = r, "created"
    end
    local bad = {}
    for k, v in pairs(overrides or {}) do
        if k == "add_flags" then
            local ok, err = addFlags(st, v)
            if not ok then bad[#bad + 1] = "SpellFlags: " .. tostring(err) end
        else
            local ok, err = setField(st, k, v)
            if not ok then bad[#bad + 1] = k .. ": " .. tostring(err) end
        end
    end
    if sync then pcall(function() st:Sync() end) end
    return how .. (#bad > 0 and (" (errors: " .. table.concat(bad, "; ") .. ")") or "")
end

local function exists(name)
    local have = false
    pcall(function() have = Ext.Stats.Get(name) ~= nil end)
    return have
end

local function apply(why, sync)
    if data.enabled == false then return end
    for spell, def in pairs(data.spells) do
        if exists(spell) then
            local v = make(M.VisualId(spell), spell, def.visual, sync)
            local i = make(M.ImpactId(spell), spell, def.impact, sync)
            Log.Write(string.format("ProjectileSpells: %s -> visual %s %s, impact %s %s (%s)", spell, M.VisualId(spell), v,
                M.ImpactId(spell), i, why))
        end
    end
end

function M.Register(context)
    Ext.Events.StatsLoaded:Subscribe(function() apply("StatsLoaded", false) end)
    -- After a Lua `reset` the stats are already loaded.
    if exists("Projectile_FireBolt") then apply("register", context == "Server") end
end

return M
