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

local NativeBridge = Ext.Require("Shared/NativeBridge.lua")
NativeBridge.Register("Server")

-- M1b combat slice (server side): mana + hit validation + spell routing + dummy.
local Mana         = Ext.Require("Server/Combat/Mana.lua")
local HitValidator = Ext.Require("Server/Combat/HitValidator.lua")
local SpellCast    = Ext.Require("Server/Combat/SpellCast.lua")
local Dummy        = Ext.Require("Server/Combat/Dummy.lua")

Mana.Register()
HitValidator.Register()
SpellCast.Register()
Ext.Require("Shared/SpellRange.lua").Register("Server")
Dummy.Register()
-- Projectile system v1 (visual / impact clones + our flight) and the HUD's stats.
Ext.Require("Shared/ProjectileSpells.lua").Register("Server")
Ext.Require("Server/Combat/Projectiles.lua").Register()
Ext.Require("Server/Combat/HudStats.lua").Register()

-- Real-time fights: the Brawl import (Server/Brawl/, tinybike, GPL-3) wired
-- through Server/BrawlAdapter.lua; !dag_rt on|off|status|debug.
Ext.Require("Server/BrawlAdapter.lua").Register()

-- Animation browser + gallery (server side: preview copies).
local AnimLib = Ext.Require("Server/AnimLib.lua")
AnimLib.Register()
