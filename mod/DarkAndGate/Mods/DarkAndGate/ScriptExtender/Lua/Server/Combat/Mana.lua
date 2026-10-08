-- SPDX-License-Identifier: GPL-3.0-or-later
-- Server-owned mana pool. Per-user state.
--
-- Formula (DESIGN.md):
--   max   = 30 + 10*CL + 5*M
--   regen = 0.5 + 0.1*CL + 0.1*M per second
-- Where CL = caster level, M = spellcasting modifier.
--
-- Spell slots are unused (spike 5: Osi.UseSpell ignores them). Costs come
-- from data/spells.lua. Cast fails if current < cost.

local Log = Ext.Require("Shared/Log.lua")
local Net = Ext.Require("Shared/Net.lua")

local M = {}

-- user id -> state table
local users = {}

local function statsForCaster(uuid)
    -- Spellcasting ability varies by class; probe a couple and take the max.
    -- This is intentionally forgiving for the DEV-SAVE Gale (INT caster).
    local function probe(ab)
        local ok, v = pcall(function() return Osi.GetAbility(uuid, ab) end)
        if ok then return tonumber(v) or 0 end
        return 0
    end
    local int = probe("Intelligence")
    local wis = probe("Wisdom")
    local cha = probe("Charisma")
    local modFrom = function(score) return math.floor(((score or 10) - 10) / 2) end
    local m = math.max(modFrom(int), modFrom(wis), modFrom(cha))
    local okL, lvl = pcall(function() return Osi.GetLevel(uuid) end)
    local cl = tonumber(okL and lvl) or 1
    return cl, m
end

local function recompute(user, uuid)
    local cl, m = statsForCaster(uuid)
    user.max   = 30 + 10 * cl + 5 * m
    user.regen = 0.5 + 0.1 * cl + 0.1 * m
    if user.current == nil then user.current = user.max end
    if user.current > user.max then user.current = user.max end
end

local function broadcast(userId, user)
    Ext.Net.PostMessageToUser(userId, Net.Channels.ManaUpdate, Ext.Json.Stringify({
        max     = user.max,
        current = user.current,
        regen   = user.regen,
    }))
end

local function stateFor(userId, uuid)
    local u = users[userId]
    if not u then
        u = { max = 60, current = 60, regen = 1.0, lastTickMs = 0 }
        users[userId] = u
    end
    if uuid then recompute(u, uuid) end
    return u
end
M.StateFor = stateFor

function M.TrySpend(userId, uuid, cost)
    local u = stateFor(userId, uuid)
    if u.current < cost then return false, u end
    u.current = u.current - cost
    broadcast(userId, u)
    return true, u
end

function M.Refill(userId, uuid)
    local u = stateFor(userId, uuid)
    u.current = u.max
    broadcast(userId, u)
end

function M.Tick(now, osiFns)
    for uid, u in pairs(users) do
        if u.lastTickMs == 0 then u.lastTickMs = now end
        local dtSec = (now - u.lastTickMs) / 1000.0
        if dtSec > 0 then
            local before = u.current
            u.current = math.min(u.max, u.current + u.regen * dtSec)
            u.lastTickMs = now
            if math.floor(u.current) ~= math.floor(before) then
                broadcast(uid, u)
            end
        end
    end
end

function M.Register()
    -- Server tick for regen. Ext.Events.Tick fires each simulation tick.
    Ext.Events.Tick:Subscribe(function()
        pcall(M.Tick, tonumber(Ext.Timer.MonotonicTime()))
    end)
    Ext.RegisterNetListener(Net.Channels.ManaRefill, function(_, _, userId)
        local uuid = (Ext.Require("Server/Net.lua")).UserToCharacter(userId)
        M.Refill(userId, uuid)
        Log.Write("Mana: refill user=" .. tostring(userId))
    end)
    Log.Write("Mana: registered")
end

return M
