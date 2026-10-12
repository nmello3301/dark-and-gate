-- SPDX-License-Identifier: GPL-3.0-or-later
-- Teleports / fast travel (Server/Travel.lua): our character moved -> first
-- person settles again (FullPov.Settle). Level loads are FullPov's own
-- GameStateChanged handling.

local Log     = Ext.Require("Shared/Log.lua")
local Net     = Ext.Require("Shared/Net.lua")
local Aim     = Ext.Require("Client/Combat/Aim.lua")
local FullPov = Ext.Require("FullPov.lua")

local M = {}

function M.Register()
    Ext.RegisterNetListener(Net.Channels.PovSettle, function(_, payload)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if ok and type(p) == "table" and p.uuid and p.uuid == Aim.SelfUuid() then
            FullPov.Settle(tostring(p.why or "teleport"), 600)
        end
    end)
    Log.Write("Travel: client registered (M = BG3's map, first person settles after travel)")
end

return M
