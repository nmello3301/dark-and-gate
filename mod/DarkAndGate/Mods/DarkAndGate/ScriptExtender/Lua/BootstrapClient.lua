-- SPDX-License-Identifier: GPL-3.0-or-later
-- Client entry point. One client state per player (including the single-player
-- "fake client" that always exists).
-- Client owns feel: input, camera, aim, swing animation, HUD, effects.
-- M0: just prove the client state loads too.

-- Multiplayer: every net message of ours through one hub (counts, the
-- last 10 s for issue markers, !dag_mp_lag). First, before any listener.
Ext.Require("Shared/NetHub.lua").Install()

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
-- !dag_spell_anims: each spell's prepare / loop / cast / recover for this character.
Ext.Require("Client/Combat/SpellAnims.lua").Register()
CombatHotbar.Register()
CombatHUD.Register()
CombatDebug.Register()
-- First-person HUD with the developer's art (replaces BG3's HUD in POV).
Ext.Require("Client/HUD/Hud.lua").Register()
-- Prepare Hotbar menu (bind spells to 1..0): beside BG3's I / Tab panels, H pins it.
Ext.Require("Client/HUD/HotbarMenu.lua").Register()
-- Projectile system v1: the clones' stats + the client-side visual probe.
Ext.Require("Shared/ProjectileSpells.lua").Register("Client")
Ext.Require("Client/Combat/ProjectileView.lua").Register()
-- Bows and crossbows: LMB draws / releases with the ranged set out, Q
-- switches melee / ranged, other characters' draws (Client/Combat/Bow.lua).
Ext.Require("Client/Combat/Bow.lua").Register()
-- Real-time fights, client side: keep control on our character at Brawl's
-- round turnovers, BG3's dynamic combat camera off.
Ext.Require("Client/BrawlClient.lua").Register()
-- BG3's Projectile / Spell combat camera requests dropped in first person.
Ext.Require("Client/CamGuard.lua").Register()
-- Real-time combat pass (2026-10-12): what the crosshair is on (F, targeted
-- spells, area indicators), on-screen prompts, the per-tick watchdog, and
-- the server's knobs typed in this console (Shared/ConsoleForward.lua).
Ext.Require("Shared/TickBudget.lua").Register()
Ext.Require("Client/LookAt.lua").Register()
Ext.Require("Client/HUD/Overlay.lua").Register()
-- F: tap = interact with what the crosshair is on, hold = revive.
Ext.Require("Client/Interact.lua").Register()
-- Downed: orbit camera, spectate, banner, revive bar.
Ext.Require("Client/Downed.lua").Register()
-- C = crouch (BG3 sneaking): speed, eye, cones.
Ext.Require("Client/Crouch.lua").Register()
-- V companion modes + server toasts; first person after teleports.
Ext.Require("Client/Companions.lua").Register()
Ext.Require("Client/Travel.lua").Register()
-- !dag_play: the whole mod on, remembered; first person by itself after
-- loads and character creation (Client/PlayMode.lua, Server/PlayMode.lua).
Ext.Require("Client/PlayMode.lua").Register()
-- Multiplayer MP-0: version handshake, log tags, !dag_mp_status (Client/MP.lua).
Ext.Require("Client/MP.lua").Register()
-- Other players' jump arcs on this screen (Client/RemoteJump.lua; switch jump_sync).
Ext.Require("Client/RemoteJump.lua").Register()
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")
ConsoleForward.Forward({
    "dag_ai", "dag_ai_aim", "dag_ai_react", "dag_ai_debug", "dag_shield_pct", "dag_shield_debug",
    "dag_bleedout", "dag_revive_time", "dag_downme", "dag_stealth", "dag_stealth_debug",
    -- Test kit (Server/Combat/TestKit.lua) and the bow's draw time.
    "dag_chest", "dag_goblins", "dag_god", "dag_bow_draw", "dag_learn",
    -- Max HP bonus (Server/Combat/HpBonus.lua); a stuck dialogue state (Server/Scene.lua);
    -- a use BG3 keeps repeating (Server/Combat/Interact.lua).
    "dag_hp", "dag_scene", "dag_unstick",
    -- The enemies' pace (Server/Combat/Pace.lua).
    "dag_enemy_pace",
    -- The melee cooldown: the client sets its own too (Client/Combat/Swing.lua).
    "dag_melee_cooldown",
    -- Multiplayer kill switches (Server/MP.lua; host only).
    "dag_mp_feature",
})
-- Forwarded commands carry the camera's forward ("ahead of you" spawns).
local AimForCtx = Ext.Require("Client/Combat/Aim.lua")
ConsoleForward.SetContext(function()
    local _, f = AimForCtx.ReadInvView()
    if f then return { fwd = { f[1], f[2], f[3] } } end
    return nil
end)

-- First-person movement: floaty Space jump (visual lift in the DLL,
-- BG3's jump clips played in phases). See Client/Movement/Jump.lua.
local JumpAnims = Ext.Require("Client/Movement/JumpAnims.lua")
local Jump      = Ext.Require("Client/Movement/Jump.lua")
JumpAnims.Register()
Jump.Register()
-- WASD speed knob + locomotion rate sync (native lever, MoveSpeed.cpp), and
-- the direct WASD controller's settings (MoveFeel.cpp, !dag_move_mode).
Ext.Require("Client/Movement/Movement.lua").Register()
-- Direct controller: the locomotion Start / End / turn clips fast-forwarded.
Ext.Require("Client/Movement/LocoSkip.lua").Register()
-- !dag_move_metrics on|off: start / stop / reverse / strafe timings (DLL) and
-- the client/server drift (Server/MoveProbe.lua).
Ext.Require("Client/Movement/MoveMetrics.lua").Register()
-- WASD in real-time fights: BG3's own through the DLL, the server as the
-- fallback (Client/Movement/CombatMove.lua).
Ext.Require("Client/Movement/CombatMove.lua").Register()
-- The real jump's height, reported to the server (hitbox + projectile hits).
Ext.Require("Client/Movement/JumpReport.lua").Register()

-- Animation browser + gallery (!dag_animlib). Tags picked there feed
-- Swing.lua and the jump (Client/AnimLib/Tags.lua).
local AnimBrowser = Ext.Require("Client/AnimLib/Browser.lua")
AnimBrowser.Register()
-- !dag_anim_record on|off: which clips BG3 itself plays on the player.
Ext.Require("Client/AnimLib/Recorder.lua").Register()
Ext.Require("Client/AnimLib/AnimState.lua").Register()
Ext.Require("Client/AnimLib/SpellVariants.lua").Register()
