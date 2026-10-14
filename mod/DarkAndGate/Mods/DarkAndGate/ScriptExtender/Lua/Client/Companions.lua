-- SPDX-License-Identifier: GPL-3.0-or-later
-- V cycles the companion mode (Follow -> Wait -> Go to camp; the server does
-- it: Server/Companions.lua). V replaces BG3's Shove in first person. Also
-- shows the server's toasts (Toast channel) through Client/HUD/Overlay.lua.

local Log       = Ext.Require("Shared/Log.lua")
local Net       = Ext.Require("Shared/Net.lua")
local ClientNet = Ext.Require("Client/Net.lua")
local Input     = Ext.Require("Client/Combat/Input.lua")
local Overlay   = Ext.Require("Client/HUD/Overlay.lua")

local MPFeatures = Ext.Require("Shared/MPFeatures.lua")   -- multiplayer kill switches

local M = {}

function M.Register()
    Input.AddKey("V", function()
        if not MPFeatures.On("companion_v") then
            Log.Write("Companions: V is off (host switch companion_v)")
            pcall(Overlay.Toast, "V is off (host switch)", 2)
            return
        end
        ClientNet.Send(Net.Channels.CompanionMode, {})
        Log.Write("Companions: V -> next mode")
    end)
    Ext.RegisterNetListener(Net.Channels.Toast, function(_, payload)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if ok and type(p) == "table" and p.text then Overlay.Toast(p.text, p.secs) end
    end)
    Log.Write("Companions: registered (V cycles Follow / Wait / Go to camp)")
end

return M
