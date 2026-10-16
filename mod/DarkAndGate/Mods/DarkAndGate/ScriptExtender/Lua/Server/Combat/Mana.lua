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
--
-- Meta-Points (2026-10-15): max x the controlled character's INT curve
-- (max_mana); whenever max changes, current keeps its share of max.
-- Recomputed on every cast, when that character's points or level change
-- (OnCharacterChanged) and when the player takes another character.

local Log = Ext.Require("Shared/Log.lua")
local Net = Ext.Require("Shared/Net.lua")

local MPState = Ext.Require("Shared/MPState.lua")
local ServerNetMod = Ext.Require("Server/Net.lua")
local MetaPoints = Ext.Require("Shared/MetaPoints.lua")
local Party = Ext.Require("Server/Party.lua")

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
    local mult = MetaPoints.Mult(uuid, "max_mana")
    local max = (30 + 10 * cl + 5 * m) * mult
    if user.current == nil then
        user.current = max
    elseif user.max and user.max > 0 and math.abs(max - user.max) > 1e-6 then
        user.current = user.current / user.max * max   -- the same share of the new max
    end
    user.max   = max
    user.regen = 0.5 + 0.1 * cl + 0.1 * m
    user.uuid  = uuid
    user.mult  = mult
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

-- Join snapshot (Server/MP.lua): send this player their mana now.
function M.Push(userId, uuid)
    pcall(function() broadcast(userId, stateFor(userId, uuid)) end)
end

function M.Refill(userId, uuid)
    local u = stateFor(userId, uuid)
    u.current = u.max
    broadcast(userId, u)
end

-- A character's Meta-Points or level changed: every player on it now gets
-- the new max (same share of it) at once.
function M.OnCharacterChanged(uuid)
    for uid, u in pairs(users) do
        if u.uuid == uuid then
            local before = u.max
            recompute(u, uuid)
            broadcast(uid, u)
            if math.abs((before or 0) - u.max) > 1e-6 then
                Log.Write(string.format("Mana: user %s max %.0f -> %.0f (INT x%.2f), current %.0f", tostring(uid), before or 0, u.max, u.mult or 1, u.current))
            end
        end
    end
end

-- For !dag_meta_print.
function M.Describe(uuid)
    for uid, u in pairs(users) do
        if u.uuid == uuid then
            return string.format("mana %.0f / %.0f (INT x%.2f), regen %.2f/s (user %s)", u.current, u.max, u.mult or 1, u.regen, tostring(uid))
        end
    end
    return "mana: no player has cast with this character yet"
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
        -- A test helper: with other players connected, only the host may refill.
        if MPState.Multi() and ((tonumber(userId) or 0) >> 16) ~= 1 then
            Log.Write("Mana: refill from user " .. tostring(userId) .. " REJECTED (only the host, in co-op)")
            return
        end
        local uuid = ServerNetMod.UserToCharacter(userId)
        M.Refill(userId, uuid)
        Log.Write("Mana: refill user=" .. tostring(userId))
    end)
    -- Another character: that one's max (same share), at once.
    Party.OnControl(function(user, uuid)
        for uid, u in pairs(users) do
            if Party.UserFromPeer(uid) == user and uuid then
                Ext.OnNextTick(function()
                    pcall(function() recompute(u, uuid); broadcast(uid, u) end)
                end)
            end
        end
    end)
    Log.Write("Mana: registered")
end

return M
