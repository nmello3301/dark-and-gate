-- SPDX-License-Identifier: GPL-3.0-or-later
-- Server entry point. Lives in Mods/DarkAndGate/ScriptExtender/Lua/.
-- Server owns truth: damage, mana, hit validation, AI, hotbars, saves.
-- M0: just prove the mod loads and can write to the log file.

local Log = Ext.Require("Shared/Log.lua")
Log.Init("Server")

Log.Write("Dark and Gate loaded. SE v" .. tostring(Ext.Utils.Version()))

Ext.Events.SessionLoaded:Subscribe(function()
    -- Osiris calls are not allowed from this event's handler (restricted
    -- context: "Attempted to call Osiris function in restricted context").
    -- When we need the host character, hook a later event or use
    -- Ext.Osiris.RegisterListener. For M0 the load confirmation is enough.
    Log.Write("SessionLoaded (server).")
end)

local ServerNet = Ext.Require("Server/Net.lua")
ServerNet.Register()

local OsiDump = Ext.Require("Server/OsiDump.lua")
OsiDump.Register()
