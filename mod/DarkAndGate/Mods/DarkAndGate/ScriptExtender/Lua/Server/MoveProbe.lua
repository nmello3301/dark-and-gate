-- SPDX-License-Identifier: GPL-3.0-or-later
-- Movement-feel metrics, server side (!dag_move_metrics on a client,
-- Client/Movement/MoveMetrics.lua; docs/spikes/move-feel.md). While a client
-- asks, the position of its character as the SERVER has it goes back to that
-- client every 50 ms, so the client can measure how far the two disagree
-- while walking and after stopping.

local Log   = Ext.Require("Shared/Log.lua")
local Net   = Ext.Require("Shared/Net.lua")
local Party = Ext.Require("Server/Party.lua")

local M = {}

local PERIOD_MS = 50
local watchers = {}   -- user -> { at = ms of the last probe }

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function tick()
    if next(watchers) == nil then return end
    local t = now()
    for user, w in pairs(watchers) do
        if t - w.at >= PERIOD_MS then
            w.at = t
            local u = Party.Controlled(user)
            local ok, p = pcall(function() return Ext.Entity.Get(u).Transform.Transform.Translate end)
            if ok and p then
                pcall(Ext.Net.PostMessageToUser, user, Net.Channels.MoveProbe,
                    Ext.Json.Stringify({ x = p[1], y = p[2], z = p[3] }))
            end
        end
    end
end

function M.Register()
    Ext.RegisterNetListener(Net.Channels.MoveProbeReq, function(_, payload, peer)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" then return end
        local user = Party.UserFromPeer(peer)
        if p.on then
            watchers[user] = { at = 0 }
            Log.Write(string.format("MoveProbe: ON for user %s (%s): its position as the server has it, every %d ms",
                tostring(user), tostring(Party.Controlled(user)), PERIOD_MS))
        elseif watchers[user] then
            watchers[user] = nil
            Log.Write("MoveProbe: OFF for user " .. tostring(user))
        end
    end)
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
end

return M
