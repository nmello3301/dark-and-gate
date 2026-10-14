-- SPDX-License-Identifier: GPL-3.0-or-later
-- Client net sender. Thin wrappers around Ext.Net.PostMessageToServer so
-- the rest of the client Lua state doesn't deal with JSON serialization or
-- channel strings directly.

local Log = Ext.Require("Shared/Log.lua")
local Net = Ext.Require("Shared/Net.lua")
local Hitbox = Ext.Require("Shared/Hitbox.lua")
local RemoteJump = Ext.Require("Client/RemoteJump.lua")

local M = {}

local function send(channel, payload)
    Ext.Net.PostMessageToServer(channel, Ext.Json.Stringify(payload or {}))
end
M.Send = send

function M.Ping(nonce)
    send(Net.Channels.Ping, {
        nonce  = nonce or tostring(math.random(1, 1e9)),
        sentMs = tostring(Ext.Timer.MonotonicTime()),
    })
end

-- dur: the clip's length in seconds (server watchdog flushes the Osiris
-- queue once it should be over); nil = server default.
function M.PlayAnim(animId, dur)
    send(Net.Channels.PlayAnimRequest, { animId = animId, dur = dur })
end

-- Animation browser: play on any allowed character (party, gallery copy,
-- within 10 m). force skips the turn-based guard; quiet = gallery loop.
function M.PlayAnimOn(target, animId, dur, force, quiet)
    send(Net.Channels.PlayAnimRequest, { animId = animId, dur = dur, target = target, force = force, quiet = quiet })
end

-- h: the hitbox lift (0 for a real jump: the real position rises); arcH:
-- the arc's height, for other players' screens (Client/RemoteJump.lua).
function M.JumpStart(durMs, h, k, arcH)
    send(Net.Channels.JumpStart, { durMs = durMs, h = h, k = k, arcH = arcH })
end

function M.CastSpell(spell, aim, targetUuid)
    send(Net.Channels.CastSpellRequest, {
        spell      = spell,
        aim        = aim,
        targetUuid = targetUuid,
    })
end

function M.RagdollPush(targetUuid, direction, force)
    send(Net.Channels.RagdollPush, {
        targetUuid = targetUuid,
        direction  = direction,
        force      = force,
    })
end

function M.HitStop(targetUuid, durationMs)
    send(Net.Channels.HitStopRequest, {
        targetUuid = targetUuid,
        durationMs = durationMs,
    })
end

function M.Register()
    Ext.RegisterNetListener(Net.Channels.PingReply, function(_, payload)
        local ok, msg = pcall(Ext.Json.Parse, payload)
        if not ok then Log.Write("Client Net: bad PingReply JSON"); return end
        local sent  = tonumber(msg.sentMs)  or 0
        local reply = tonumber(msg.replyMs) or 0
        local now   = tonumber(Ext.Timer.MonotonicTime())
        Log.Write(string.format("Client Net: PingReply nonce=%s roundtrip=%dms server_dt=%dms",
            tostring(msg.nonce), now - sent, reply - sent))
    end)
    -- Another player's jump: lift their hitbox locally for aim and melee.
    Ext.RegisterNetListener(Net.Channels.JumpNotify, function(_, payload)
        local ok, msg = pcall(Ext.Json.Parse, payload)
        if ok and msg and msg.uuid then
            Hitbox.SetJump(msg.uuid, msg.durMs, msg.h, msg.k)
            RemoteJump.Start(msg)   -- draw the arc on this screen (multiplayer)
        end
    end)
    Log.Write("Client Net: PingReply + JumpNotify listeners registered")
end

return M
