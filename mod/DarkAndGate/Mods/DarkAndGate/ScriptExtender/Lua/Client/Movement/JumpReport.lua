-- SPDX-License-Identifier: GPL-3.0-or-later
-- The real jump (FullPov jump mode "real") moves the body on THIS client
-- only; the server still sees the jumper on the ground. While airborne,
-- report the height above the take-off ground (~15 Hz) so the server's
-- hitbox (Shared/Hitbox.lua lift samples) and projectile hits follow it.

local Log       = Ext.Require("Shared/Log.lua")
local Net       = Ext.Require("Shared/Net.lua")
local ClientNet = Ext.Require("Client/Net.lua")
local State     = Ext.Require("Client/Combat/State.lua")
local FullPov   = Ext.Require("FullPov.lua")

local M = {}

local PERIOD_MS = 66
local base = nil
local lastSent = -1e9
local peak = 0

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function feetY()
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    local me = ok and ents and ents[1] or nil
    if not me then return nil end
    local okT, y = pcall(function() return me.Transform.Transform.Translate[2] end)
    return okT and tonumber(y) or nil
end

local function tick()
    local airborne = State.jumping and FullPov.JumpMode() == "real"
    if not airborne then
        if base then
            base = nil
            ClientNet.Send(Net.Channels.JumpLift, { lift = 0 })
            Log.Write(string.format("JumpReport: landed, peak lift sent to the server %.2f m", peak))
        end
        return
    end
    local y = feetY()
    if not y then return end
    if not base then base, peak = y, 0 end
    local t = now()
    if t - lastSent < PERIOD_MS then return end
    lastSent = t
    local lift = math.max(0, y - base)
    if lift > peak then peak = lift end
    ClientNet.Send(Net.Channels.JumpLift, { lift = lift })
end

function M.Register()
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
end

return M
