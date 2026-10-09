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

-- 2026-10-09: Osi.PlayAnimation is a queued Osiris task. A new one queued
-- behind a clip that is still playing (LMB spam, jump phases) stalls the
-- character's task queue and WASD stops working until a reload. So:
--   * before every PlayAnimation, purge + flush the character's Osiris
--     queue (the new clip interrupts the old one instead of queueing);
--   * a watchdog flushes the queue once more after the last clip should
--     have ended (payload.dur seconds, default 1.5 s).
local ANIM_DEFAULT_S = 1.5
local ANIM_WATCHDOG_MS = 300
local animState = {}   -- uuid -> { endsAt = ms }
local queueFnsLogged = false

local function clearOsirisQueue(uuid, why)
    local results = {}
    for _, fn in ipairs({ "PurgeOsirisQueue", "FlushOsirisQueue" }) do
        local ok, err = pcall(function() return Osi[fn](uuid) end)
        results[#results + 1] = fn .. "=" .. (ok and "ok" or tostring(err))
    end
    if not queueFnsLogged or why == "watchdog" then
        queueFnsLogged = true
        Log.Write(string.format("Net: Osiris queue cleared (%s) %s", why, table.concat(results, " ")))
    end
end

local function animNow() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function animWatchdog()
    local t = animNow()
    for uuid, st in pairs(animState) do
        if t >= st.endsAt + ANIM_WATCHDOG_MS then
            animState[uuid] = nil
            enqueueOsi(function() clearOsirisQueue(uuid, "watchdog") end)
        end
    end
end

handlers[Net.Channels.PlayAnimRequest] = function(payload, userId)
    enqueueOsi(function()
        local uuid = userToCharacter(userId)
        if not uuid then Log.Write("Net: PlayAnim no character for user " .. userId); return end
        -- fix5: "__unstick__" clears a stuck action queue (!dag_unstick).
        if payload.animId == "__unstick__" then
            for _, fn in ipairs({ "PurgeOsirisQueue", "FlushOsirisQueue", "StopAnimation" }) do
                local ok, err = pcall(function() return Osi[fn](uuid) end)
                Log.Write(string.format("Net: unstick Osi.%s ok=%s %s", fn, tostring(ok), ok and "" or tostring(err)))
            end
            return
        end
        -- fix5: in BG3 turn-based combat a scripted PlayAnimation on the
        -- player queues an action that never finishes outside your turn,
        -- which left Gale unable to walk. Skip swing anims while in combat.
        local okC, inC = pcall(function() return Osi.IsInCombat(uuid) end)
        if okC and tonumber(inC) == 1 then
            Log.Write("Net: PlayAnim skipped (in turn-based combat) anim=" .. tostring(payload.animId))
            return
        end
        local dur = tonumber(payload.dur) or ANIM_DEFAULT_S
        if dur <= 0 then dur = ANIM_DEFAULT_S end
        -- 2026-10-09 playtest: the first clip after a pause only played on
        -- the second click (the second click's purge released it), so the
        -- queue is cleared before EVERY clip, not only on interrupts.
        clearOsirisQueue(uuid, animState[uuid] and "interrupt" or "before-play")
        animState[uuid] = { endsAt = animNow() + dur * 1000 }
        Log.Write(string.format("Net: PlayAnim uuid=%s anim=%s dur=%.2fs", uuid, tostring(payload.animId), dur))
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
    -- M1b casts (withMana) belong to Server/Combat/SpellCast.lua. Without
    -- this guard both handlers fired: a free duplicate cast, and point
    -- spells (Fireball) landing on the caster because targetUuid is nil.
    if payload.withMana then return end
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

-- First-person jump: lift the jumper's hitbox for the jump's duration and
-- tell the other clients (their aim needs the lifted cylinder too).
local Hitbox = Ext.Require("Shared/Hitbox.lua")
handlers[Net.Channels.JumpStart] = function(payload, userId)
    local t0 = animNow()
    enqueueOsi(function()
        local uuid = userToCharacter(userId)
        if not uuid then return end
        Hitbox.SetJump(uuid, payload.durMs, payload.h, payload.k, t0)
        Log.Write(string.format("Net: Jump uuid=%s dur=%dms h=%.2f (hitbox lifted)",
            uuid, tonumber(payload.durMs) or 0, tonumber(payload.h) or 0))
        local msg = Ext.Json.Stringify({ uuid = uuid, durMs = payload.durMs, h = payload.h, k = payload.k })
        local okB = pcall(function() Ext.Net.BroadcastMessage(Net.Channels.JumpNotify, msg, uuid) end)
        if not okB then pcall(function() Ext.ServerNet.BroadcastMessage(Net.Channels.JumpNotify, msg, uuid) end) end
    end)
end

function M.Register()
    Ext.Events.Tick:Subscribe(function() pcall(animWatchdog) end)
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
