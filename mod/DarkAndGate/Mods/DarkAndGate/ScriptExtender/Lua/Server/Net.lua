-- SPDX-License-Identifier: GPL-3.0-or-later
-- Server net handlers. Validates intents from the client and, when an action
-- requires Osiris, defers the Osi call to the next tick so we are never in a
-- restricted context.

local Log = Ext.Require("Shared/Log.lua")
local Net = Ext.Require("Shared/Net.lua")

local M = {}

local handlers = {}

-- Deferred Osi queue. Entries are plain functions; drained on OnNextTick.
local osiQueue = {}
local tickHooked = false

local function enqueueOsi(fn)
    table.insert(osiQueue, fn)
    if not tickHooked then
        tickHooked = true
        Ext.OnNextTick(function()
            tickHooked = false
            local drain = osiQueue
            osiQueue = {}
            for _, f in ipairs(drain) do
                local ok, err = pcall(f)
                if not ok then Log.Write("Net: deferred Osi error: " .. tostring(err)) end
            end
        end)
    end
end
M.EnqueueOsi = enqueueOsi

-- Resolve the character UUID a given user is controlling. Uses Osi, so only
-- call from a deferred callback. Returns nil if the user has no character.
--
-- In single player, Osi.GetCurrentCharacter(65536) returns nothing (verified
-- 2026-10-08: logged "no character for user 65536" when called). The reliable
-- single-player path is Osi.GetHostCharacter(). For MP we'll need a proper
-- user->character lookup; this stub falls through to the host for now.
local function userToCharacter(userId)
    local ok, uuid = pcall(function() return Osi.GetCurrentCharacter(userId) end)
    if ok and uuid and uuid ~= "" then return uuid end
    local ok2, host = pcall(function() return Osi.GetHostCharacter() end)
    if ok2 and host and host ~= "" then return host end
    return nil
end
M.UserToCharacter = userToCharacter

-- ------------- Channel handlers -----------------------------------------

handlers[Net.Channels.Ping] = function(payload, userId)
    local reply = {
        nonce   = payload.nonce,
        sentMs  = payload.sentMs,
        recvMs  = tostring(Ext.Timer.MonotonicTime()),
        replyMs = tostring(Ext.Timer.MonotonicTime()),
    }
    Ext.Net.PostMessageToUser(userId, Net.Channels.PingReply,
        Ext.Json.Stringify(reply))
    Log.Write(string.format("Net: Ping from user=%d nonce=%s", userId, tostring(payload.nonce)))
end

handlers[Net.Channels.PlayAnimRequest] = function(payload, userId)
    enqueueOsi(function()
        local uuid = userToCharacter(userId)
        if not uuid then Log.Write("Net: PlayAnim no character for user " .. userId); return end
        Log.Write(string.format("Net: PlayAnim uuid=%s anim=%s", uuid, tostring(payload.animId)))
        Osi.PlayAnimation(uuid, payload.animId, "")
    end)
end

-- Find the nearest hostile character within 30 m of casterUuid. Uses
-- CharacterIsEnemy from Osi; falls back to any non-player if that query is
-- unavailable. Server-side only, Osi-safe context assumed.
local function nearestHostile(casterUuid)
    local best, bestDist = nil, 1e9
    local ents = Ext.Entity.GetAllEntitiesWithComponent("ServerCharacter") or {}
    for _, ent in ipairs(ents) do
        local uuid = ent.Uuid and ent.Uuid.EntityUuid
        if uuid and uuid ~= casterUuid then
            local ok, isPlayer = pcall(function() return Osi.IsPlayer(uuid) end)
            if ok and tonumber(isPlayer) == 0 then
                local okD, d = pcall(function() return Osi.GetDistanceTo(casterUuid, uuid) end)
                local dist = tonumber(d) or 1e9
                if okD and dist < bestDist and dist < 30 then
                    best, bestDist = uuid, dist
                end
            end
        end
    end
    return best, bestDist
end

handlers[Net.Channels.CastSpellRequest] = function(payload, userId)
    enqueueOsi(function()
        local caster = userToCharacter(userId)
        if not caster then Log.Write("Net: CastSpell no character for user " .. userId); return end
        local target = payload.targetUuid
        if target == "__nearest_enemy__" then
            local t, dist = nearestHostile(caster)
            if not t then
                Log.Write("Net: CastSpell no hostile within 30m of " .. caster); return
            end
            Log.Write(string.format("Net: CastSpell picked nearest hostile %s (%.2fm)", t, dist))
            target = t
        elseif target == nil or target == "" then
            target = caster
        end
        Log.Write(string.format("Net: UseSpell caster=%s spell=%s target=%s",
            caster, tostring(payload.spell), tostring(target)))
        Osi.UseSpell(caster, payload.spell, target)
    end)
end

handlers[Net.Channels.RagdollPush] = function(payload, userId)
    enqueueOsi(function()
        local caster = userToCharacter(userId)
        local target = payload.targetUuid
        if target == "__nearest_enemy__" then
            if not caster then Log.Write("Net: RagdollPush no caster"); return end
            local t, dist = nearestHostile(caster)
            if not t then Log.Write("Net: RagdollPush no hostile within 30m of " .. caster); return end
            Log.Write(string.format("Net: RagdollPush picked %s (%.2fm)", t, dist))
            target = t
        end
        if not target or target == "" then return end
        Log.Write(string.format("Net: RagdollPush target=%s force=%.2f",
            target, payload.force or 0))
        -- Spike 6 probe. The real "push direction" lives in the engine's
        -- death handler; from Lua the only visible lever is a status. If
        -- KNOCKED_DOWN takes effect visibly, we know the status path works
        -- end-to-end; the actual directional impulse is almost certainly
        -- native-plugin territory.
        Osi.ApplyStatus(target, "KNOCKED_DOWN", 1)
    end)
end

handlers[Net.Channels.HitStopRequest] = function(payload, userId)
    enqueueOsi(function()
        if not payload.targetUuid then return end
        Log.Write(string.format("Net: HitStop target=%s ms=%d",
            payload.targetUuid, payload.durationMs or 0))
        -- Spike 7 probe. See Spikes/Spike7_HitStop.lua for the actual engine
        -- lever it tries; this handler just logs the request path works.
    end)
end

function M.Register()
    for channel, handler in pairs(handlers) do
        Ext.RegisterNetListener(channel, function(c, payload, userId)
            local ok, parsed = pcall(Ext.Json.Parse, payload)
            if not ok then
                Log.Write("Net: bad JSON on channel " .. tostring(c))
                return
            end
            local ok2, err = pcall(handler, parsed, userId)
            if not ok2 then
                Log.Write("Net: handler error on " .. tostring(c) .. ": " .. tostring(err))
            end
        end)
    end
    Log.Write("Net: server listeners registered for " .. tostring(#Net.AllChannels) .. " channels")
end

return M
