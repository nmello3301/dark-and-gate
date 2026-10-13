-- SPDX-License-Identifier: GPL-3.0-or-later
-- A real-time fight ends when no enemy in it is near the party (DECISIONS
-- 2026-10-12; developer: "make sure the fight ends once there are no enemies
-- aggroed around 30m" -- goblins stuck in a wall kept a fight, and its music,
-- going forever). Brawl only ends a fight when its last enemy dies.
--
-- Every check_s while a real-time fight runs: the live enemies in it (Brawl's
-- roster minus the party and its combat helper, hostile to someone in the
-- party). When none of them has been within near_m of a party member in the
-- fight for grace_s, they leave the fight and Brawl ends it (EndCombat and its
-- own clean-up). They stay hostile: walk up to them and a new fight starts.
-- Nothing is counted while the party is paused (force turn-based).
--
--   !dag_fight_end [<m> | off | on]   the distance, or the check off / on

local Log            = Ext.Require("Shared/Log.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")
local Party          = Ext.Require("Server/Party.lua")
local Adapter        = Ext.Require("Server/BrawlAdapter.lua")
local D              = Ext.Require("data/realtime.lua").fight_end or {}

local M = {}

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local enabled = D.enabled ~= false
local farSince = nil       -- ms: no enemy near since then (nil = one is near)
local lastCheck = 0
local quietUntil = 0      -- ms: after ending a fight, give BG3 time to close it

local function brawl(name)
    local ok, mod = pcall(function() return DAG_BrawlModule and DAG_BrawlModule(name) end)
    return ok and mod or nil
end

local function num(fn, ...)
    local ok, v = pcall(fn, ...)
    return ok and tonumber(v) or nil
end

local function name(u)
    local ok, n = pcall(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(u)) end)
    return (ok and n and n ~= "") and n or tostring(u)
end

-- Party members in the fight, and the live enemies in it with their distance
-- to the nearest of them.
local function survey()
    local members = {}
    for _, u in ipairs(Party.Members()) do
        if num(Osi.IsInCombat, u) == 1 and num(Osi.IsDead, u) ~= 1 then members[#members + 1] = u end
    end
    local enemies = {}
    local Roster, Utils = brawl("Roster"), brawl("Utils")
    if not Roster or #members == 0 then return members, enemies end
    local okB, brawlers = pcall(Roster.getBrawlers)
    for u in pairs(okB and brawlers or {}) do
        local okH, isH = false, false
        if Utils then okH, isH = pcall(Utils.isCombatHelper, u) end
        local helper = okH and isH == true
        if not helper and num(Osi.IsPartyMember, u, 1) ~= 1 and num(Osi.IsDead, u) ~= 1 and num(Osi.IsInCombat, u) == 1 then
            local best, hostile = nil, false
            for _, m in ipairs(members) do
                if num(Osi.IsEnemy, u, m) == 1 then hostile = true end
                local d = num(Osi.GetDistanceTo, u, m)
                if d and (not best or d < best) then best = d end
            end
            if hostile then enemies[#enemies + 1] = { uuid = u, d = best or 1e9 } end
        end
    end
    return members, enemies
end

local function endFight(members, enemies, why)
    local names = {}
    for _, e in ipairs(enemies) do
        pcall(function() Osi.LeaveCombat(e.uuid) end)
        names[#names + 1] = string.format("%s %.0f m", name(e.uuid), e.d)
    end
    local Roster, Utils = brawl("Roster"), brawl("Utils")
    local okR, region = pcall(function() return Utils.getCurrentRegion() end)
    if Roster and okR and region then pcall(Roster.endBrawl, region) end
    local ended = {}
    for _, m in ipairs(members) do
        local okG, g = pcall(Osi.CombatGetGuidFor, m)
        if okG and g and not ended[g] then
            ended[g] = true
            pcall(function() Osi.EndCombat(g) end)
        end
    end
    Log.Write(string.format("FightEnd: %s -> the fight ends%s", why,
        #names > 0 and (" (left it: " .. table.concat(names, ", ") .. ")") or ""))
end

local function tick()
    if not enabled or not Adapter.Enabled() or not Adapter.InFight() then farSince = nil; return end
    local t = now()
    if t - lastCheck < (D.check_s or 1.0) * 1000 or t < quietUntil then return end
    lastCheck = t
    local Pause = brawl("Pause")
    if Pause and select(2, pcall(Pause.isPartyInFTB)) == true then farSince = nil; return end
    local members, enemies = survey()
    if #members == 0 then farSince = nil; return end
    local nearM = D.near_m or 30
    for _, e in ipairs(enemies) do
        if e.d <= nearM then farSince = nil; return end
    end
    if not farSince then
        farSince = t
        Log.Write(string.format("FightEnd: no enemy within %.0f m of the party (%d further away) -- the fight ends in %.0f s unless one comes closer",
            nearM, #enemies, D.grace_s or 4))
        return
    end
    if t - farSince >= (D.grace_s or 4) * 1000 then
        farSince = nil
        quietUntil = t + 10000
        endFight(members, enemies, string.format("no enemy within %.0f m for %.0f s", nearM, D.grace_s or 4))
    end
end

function M.Register()
    Ext.Events.Tick:Subscribe(function()
        local ok, err = pcall(tick)
        if not ok then Log.Write("FightEnd: tick error " .. tostring(err)) end
    end)
    ConsoleForward.Server("dag_fight_end", function(_, a)
        if a == "off" then enabled = false
        elseif a == "on" then enabled = true
        elseif tonumber(a) then D.near_m = math.max(5, tonumber(a)) end
        Log.Write(string.format("FightEnd: %s (a fight ends when no enemy is within %.0f m for %.0f s)",
            enabled and "ON" or "OFF", D.near_m or 30, D.grace_s or 4))
    end)
    Log.Write(string.format("FightEnd: registered (fights end with no enemy within %.0f m for %.0f s; !dag_fight_end)",
        D.near_m or 30, D.grace_s or 4))
end

return M
