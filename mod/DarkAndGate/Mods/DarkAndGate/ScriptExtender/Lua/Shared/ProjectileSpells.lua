-- SPDX-License-Identifier: GPL-3.0-or-later
-- The two clones each projectile spell needs (data/projectiles.lua):
--   DAG_V_<spell>  "visual": the same cast, animation, trail and look, no
--                  roll and no effect -- BG3 flies it, we remove it at our hit;
--   DAG_I_<spell>  "impact": instant, no costs -- applied at our hit with
--                  Osi.CreateExplosion / CreateExplosionAtPosition.
-- They live in the mod's stats file
-- (Public/DarkAndGate/Stats/Generated/Data/DAG_Projectiles.txt, "using" the
-- spell, as vanilla builds its own variants): Script Extender v32 can't
-- write functor fields (SpellSuccess / SpellProperties) from Lua -- the
-- first build tried and logged "cannot write properties of this type",
-- so its visual clone still dealt damage (playtest 2026-10-12).
-- This module only checks they loaded and logs what they hold. The spells'
-- own entries are never changed (DESIGN: spells stay BG3 data).

local Log  = Ext.Require("Shared/Log.lua")
local data = Ext.Require("data/projectiles.lua")

local M = {}

function M.VisualId(spell) return "DAG_V_" .. spell end
function M.ImpactId(spell) return "DAG_I_" .. spell end

local function get(name)
    local st = nil
    pcall(function() st = Ext.Stats.Get(name) end)
    return st
end

local function field(st, k)
    local ok, v = pcall(function() return st[k] end)
    if not ok then return "?" end
    if type(v) == "userdata" or type(v) == "table" then
        local okJ, j = pcall(Ext.Json.Stringify, v, { Beautify = false, IterateUserdata = true, StringifyInternalTypes = true })
        v = okJ and j or tostring(v)
    end
    v = tostring(v)
    return #v > 60 and (v:sub(1, 57) .. "...") or v
end

local okCount = 0
function M.Ok() return okCount end

local function check(why)
    if data.enabled == false then return end
    okCount = 0
    for spell in pairs(data.spells) do
        if get(spell) then
            local v, i = get(M.VisualId(spell)), get(M.ImpactId(spell))
            if v and i then okCount = okCount + 1 end
            Log.Write(string.format("ProjectileSpells: %s -> %s %s (SpellRoll=%s SpellSuccess=%s SpellProperties=%s), %s %s (SpellRoll=%s SpellProperties=%s ExplodeRadius=%s) [%s]",
                spell, M.VisualId(spell), v and "loaded" or "MISSING", v and field(v, "SpellRoll") or "-",
                v and field(v, "SpellSuccess") or "-", v and field(v, "SpellProperties") or "-",
                M.ImpactId(spell), i and "loaded" or "MISSING", i and field(i, "SpellRoll") or "-",
                i and field(i, "SpellProperties") or "-", i and field(i, "ExplodeRadius") or "-", why))
        end
    end
end

-- Both clones of `spell` exist (else the server casts the spell the old way).
function M.Ready(spell)
    return get(M.VisualId(spell)) ~= nil and get(M.ImpactId(spell)) ~= nil
end

function M.Register(context)
    Ext.Events.StatsLoaded:Subscribe(function() check("StatsLoaded") end)
    if get("Projectile_FireBolt") then check("register") end
end

return M
