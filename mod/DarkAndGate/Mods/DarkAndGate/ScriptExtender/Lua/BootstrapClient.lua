-- SPDX-License-Identifier: GPL-3.0-or-later
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

local Spike2 = Ext.Require("Spikes/Spike2_AimRay.lua")
Spike2.Register()

local ClientNet = Ext.Require("Client/Net.lua")
ClientNet.Register()

local NativeBridge = Ext.Require("Shared/NativeBridge.lua")
NativeBridge.Register("Client")

-- Full first-person POV (!dag_full_pov). Lua tells the DLL where the
-- head bone lives; the DLL drives the camera every frame.
-- We load CombatState first (further down) in a module require, then
-- back-fill FullPov's reference so setOn() can flip State.povOn without
-- any Ext.Require dance at console-command time (round 2 regression).
local FullPov = Ext.Require("FullPov.lua")
local CombatStateEarly = Ext.Require("Client/Combat/State.lua")
FullPov.LinkState(CombatStateEarly)
FullPov.Register()

-- Combined 4+5+6+7 probe. Each spike is a module behind an MCM toggle and
-- its own console commands; see docs/spikes/04-07-combined-test.md.
local Spike4 = Ext.Require("Spikes/Spike4_Anims.lua");     Spike4.Register()
local Spike5 = Ext.Require("Spikes/Spike5_SpellCast.lua"); Spike5.Register()
local Spike6 = Ext.Require("Spikes/Spike6_Ragdoll.lua");   Spike6.Register()
local Spike7 = Ext.Require("Spikes/Spike7_HitStop.lua");   Spike7.Register()

-- One console command to prove the client->server round-trip works before
-- running the actual spikes.
Ext.RegisterConsoleCommand("dag_ping", function()
    ClientNet.Ping()
end)

-- M1b combat slice: input + swing + spells + hotbar + HUD + debug.
local CombatState  = Ext.Require("Client/Combat/State.lua")
local CombatInput  = Ext.Require("Client/Combat/Input.lua")
local CombatSwing  = Ext.Require("Client/Combat/Swing.lua")
local CombatHotbar = Ext.Require("Client/Combat/Hotbar.lua")
local CombatHUD    = Ext.Require("Client/Combat/HUD.lua")
local CombatDebug  = Ext.Require("Client/Combat/Debug.lua")

-- Actions (swing / cast / spell prepare loop) own the play rate and take
-- priority over the jump clips.
Ext.Require("Client/Combat/Actions.lua").Register()
CombatInput.Register()
CombatSwing.Register()
Ext.Require("Shared/SpellRange.lua").Register("Client")
CombatHotbar.Register()
CombatHUD.Register()
CombatDebug.Register()

-- First-person movement: floaty Space jump (visual lift in the DLL,
-- BG3's jump clips played in phases). See Client/Movement/Jump.lua.
local JumpAnims = Ext.Require("Client/Movement/JumpAnims.lua")
local Jump      = Ext.Require("Client/Movement/Jump.lua")
JumpAnims.Register()
Jump.Register()
-- WASD speed knob + locomotion rate sync (native lever, MoveSpeed.cpp).
Ext.Require("Client/Movement/Movement.lua").Register()

-- Animation browser + gallery (!dag_animlib). Tags picked there feed
-- Swing.lua and the jump (Client/AnimLib/Tags.lua).
local AnimBrowser = Ext.Require("Client/AnimLib/Browser.lua")
AnimBrowser.Register()
