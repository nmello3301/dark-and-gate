-- SPDX-License-Identifier: GPL-3.0-or-later
-- Debug console commands for M1b:
--   !dag_mana [refill]        print state; refill drains server to full
--   !dag_hotbar <slot> <id>   assign a spell to a slot
--   !dag_hotbar_reset         reset to DEV-SAVE defaults
--   !dag_swing_debug on/off   log the per-sample ray fan
--   !dag_rt on/off            toggle real-time combat (default on)
--   !dag_spawn_dummy          server spawns a goblin dummy 3m +X of player
--   !dag_pov_on               thin wrapper that also sets State.povOn so
--                             the HUD + input know POV is active.

local Log       = Ext.Require("Shared/Log.lua")
local Net       = Ext.Require("Shared/Net.lua")
local State     = Ext.Require("Client/Combat/State.lua")
local ClientNet = Ext.Require("Client/Net.lua")

local M = {}

function M.Register()
    Ext.RegisterConsoleCommand("dag_mana", function(_, arg)
        if arg == "refill" or arg == "full" then
            ClientNet.Send(Net.Channels.ManaRefill, {})
            Log.Write("Mana: refill requested")
        else
            Log.Write(string.format("Mana: %d / %d  +%.1f/s",
                math.floor(State.mana.current),
                math.floor(State.mana.max),
                State.mana.regen))
        end
    end)

    Ext.RegisterConsoleCommand("dag_swing_debug", function(_, arg)
        State.swingDebug = (arg == "on" or arg == "1")
        Log.Write("Swing debug: " .. (State.swingDebug and "ON" or "OFF"))
    end)

    Ext.RegisterConsoleCommand("dag_rt", function(_, arg)
        State.realTime = not (arg == "off" or arg == "0")
        Log.Write("Real-time combat: " .. (State.realTime and "ON" or "OFF"))
    end)

    Ext.RegisterConsoleCommand("dag_spawn_dummy", function()
        ClientNet.Send(Net.Channels.SpawnDummy, {})
        Log.Write("SpawnDummy: requested")
    end)

    -- Follow !dag_full_pov to keep State.povOn consistent — Input/HUD
    -- gate on it. We can't peek inside FullPov, so poll the file.
    local STATUS_PATH = "DarkAndGate/native-pov-status.txt"
    Ext.Events.Tick:Subscribe(function()
        local ok, s = pcall(Ext.IO.LoadFile, STATUS_PATH)
        if not ok or not s then return end
        local on = s:match("on=(%d)")
        State.povOn = on == "1"
    end)

    Log.Write("Combat Debug: registered")
end

return M
