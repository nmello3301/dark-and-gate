-- SPDX-License-Identifier: GPL-3.0-or-later
-- Client net sender. Thin wrappers around Ext.Net.PostMessageToServer so
-- the rest of the client Lua state doesn't deal with JSON serialization or
-- channel strings directly.

local Log = Ext.Require("Shared/Log.lua")
local Net = Ext.Require("Shared/Net.lua")

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

function M.PlayAnim(animId, speed)
    send(Net.Channels.PlayAnimRequest, { animId = animId, speed = speed })
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
    Log.Write("Client Net: PingReply listener registered")
end

return M
