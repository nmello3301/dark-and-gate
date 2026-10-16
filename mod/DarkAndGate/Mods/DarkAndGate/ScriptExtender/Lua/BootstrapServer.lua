-- SPDX-License-Identifier: GPL-3.0-or-later
-- Server entry point. Lives in Mods/DarkAndGate/ScriptExtender/Lua/.
-- Server owns truth: damage, mana, hit validation, AI, hotbars, saves.
-- M0: just prove the mod loads and can write to the log file.

-- Multiplayer: every net message of ours through one hub (counts, the
-- last 10 s for issue markers, !dag_mp_lag). First, before any listener.
Ext.Require("Shared/NetHub.lua").Install()

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

-- Meta-Points: the user variable is registered when this loads (before any
-- save is read, SE docs).
Ext.Require("Shared/MetaPoints.lua")

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
-- Multiplayer MP-2: positions of everyone near a player, for lag-tolerant
-- melee checks (Server/PosHistory.lua, HitValidator; switch rewind).
local PosHistory = Ext.Require("Server/PosHistory.lua")
PosHistory.SetNear(Ext.Require("Server/Combat/Projectiles.lua").Near)
PosHistory.Register()
Ext.Require("Server/Combat/HudStats.lua").Register()

-- Real-time fights: the Brawl import (Server/Brawl/, tinybike, GPL-3) wired
-- through Server/BrawlAdapter.lua; !dag_rt on|off|status|debug.
Ext.Require("Server/Party.lua").Register()
Ext.Require("Shared/ConsoleForward.lua").RegisterServer()
Ext.Require("Server/BrawlAdapter.lua").Register()
-- The AI pace per side: enemies by BG3's difficulty, your side 4 s.
Ext.Require("Server/Combat/Pace.lua").Register()
-- Real-time rules: no reactions / Sneak Attack in real-time fights.
Ext.Require("Server/Combat/NoReactions.lua").Register()
-- Enemy / companion AI on our rules (swings, projectiles, cast time) and
-- passive shields. !dag_watchdog: per-tick handler timings.
Ext.Require("Shared/TickBudget.lua").Register()
Ext.Require("Server/Combat/Shields.lua").Register()
Ext.Require("Server/Combat/NpcCombat.lua").Register()
-- F interaction: what an entity under a player's crosshair is.
Ext.Require("Server/Combat/Interact.lua").Register()
-- Downed / bleed-out / revive (companions revive first: NpcCombat asks Downed).
local Downed = Ext.Require("Server/Combat/Downed.lua")
Downed.Register()
Ext.Require("Server/Combat/NpcCombat.lua").SetReviveHandler(Downed)
-- Crouch = sneaking, and our stealth checks.
Ext.Require("Server/Combat/Stealth.lua").Register()
-- V companion modes (Downed asks them: no revives from camp), travel / POV.
local Companions = Ext.Require("Server/Companions.lua")
Companions.Register()
Downed.SetModeSource(Companions.Mode)
Ext.Require("Server/Travel.lua").Register()
-- Bows and crossbows (the player's draws and shots; NpcCombat uses it for
-- NPC archers), and the test kit: !dag_chest, !dag_goblins, !dag_god.
Ext.Require("Server/Combat/Bows.lua").Register()
-- WASD in real-time fights when BG3's own WASD can't move you: the server
-- walks you toward the WASD direction (Server/Combat/CombatMove.lua).
Ext.Require("Server/Combat/CombatMove.lua").Register()
-- A real-time fight ends when no enemy in it is within 30 m of the party
-- (Server/Combat/FightEnd.lua).
Ext.Require("Server/Combat/FightEnd.lua").Register()
-- Ground surfaces don't touch a first-person jumper in the air.
Ext.Require("Server/Combat/AirSurfaces.lua").Register()
Ext.Require("Server/Combat/TestKit.lua").Register()
-- !dag_hp 50 [party]: max HP bonus (BG3's IncreaseMaxHP(N%) on a hidden status).
Ext.Require("Server/Combat/HpBonus.lua").Register()
-- No fall damage for the party (BG3's IgnoreFallDamage() on a hidden status).
Ext.Require("Server/Combat/NoFallDamage.lua").Register()
-- !dag_play from a client: the server's parts on, level / character creation info.
Ext.Require("Server/PlayMode.lua").Register()
-- Dialogues / cutscenes: clients hide our HUD and release input (Server/Scene.lua).
Ext.Require("Server/Scene.lua").Register()
-- Multiplayer MP-0: version handshake, !dag_mp_status (Server/MP.lua).
Ext.Require("Server/MP.lua").Register()
-- !dag_move_metrics: the server's own position of a client's character, for
-- the client/server drift (Client/Movement/MoveMetrics.lua).
Ext.Require("Server/MoveProbe.lua").Register()

-- Meta-Points: the per-character point pool (Server/MetaPoints.lua) and its
-- damage side (Server/Combat/MetaDamage.lua: spell damage, enemy knobs, fall guard).
Ext.Require("Server/Combat/MetaDamage.lua").Register()
local MetaPointsServer = Ext.Require("Server/MetaPoints.lua")
MetaPointsServer.Register()
MetaPointsServer.AddDescriber(function(uuid)
    local SpellCastM = Ext.Require("Server/Combat/SpellCast.lua")
    local BowsM = Ext.Require("Server/Combat/Bows.lua")
    local MC = Ext.Require("Shared/MeleeCooldown.lua")
    local cd = MC.Seconds("longsword", uuid)
    return {
        string.format("cast time %.3f s (Fire Bolt, server), bow draw %.3f s, melee cooldown %.3f s (swing x%.2f), shield block %.0f %%",
            SpellCastM.CastTimeFor(uuid, "Projectile_FireBolt"), BowsM.DrawTime(uuid), cd, MC.SwingRate(cd, 420),
            Ext.Require("Server/Combat/Shields.lua").ReductionFor(uuid) * 100),
        Ext.Require("Server/Combat/Mana.lua").Describe(uuid),
        Ext.Require("Server/Combat/MetaDamage.lua").Describe(),
    }
end)

-- RPG Mode: cleared fights leave a flag; ON + away = the camp comes back.
local RpgMode = Ext.Require("Server/Combat/RpgMode.lua")
RpgMode.Register()
Ext.Require("Server/Combat/Interact.lua").SetFlagHandler(RpgMode)

-- Animation browser + gallery (server side: preview copies).
local AnimLib = Ext.Require("Server/AnimLib.lua")
AnimLib.Register()
