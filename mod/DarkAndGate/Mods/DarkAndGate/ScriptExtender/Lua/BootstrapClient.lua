-- Client entry point. One client state per player (including the single-player
-- "fake client" that always exists).
-- Client owns feel: input, camera, aim, swing animation, HUD, effects.
-- M0: just prove the client state loads too.

local Log = Ext.Require("Shared/Log.lua")
Log.Init("Client")

Log.Write("Dark and Gate loaded. SE v" .. tostring(Ext.Utils.Version()))

Ext.Events.SessionLoaded:Subscribe(function()
    Log.Write("SessionLoaded (client).")
end)

local Spike11 = Ext.Require("Spikes/Spike11_HeadHiding.lua")
Spike11.Register()

local Spike11b = Ext.Require("Spikes/Spike11b_Camera.lua")
Spike11b.Register()

local Spike1 = Ext.Require("Spikes/Spike1_Input.lua")
Spike1.Register()

local Spike3 = Ext.Require("Spikes/Spike3_BoneReads.lua")
Spike3.Register()
