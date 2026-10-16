-- SPDX-License-Identifier: GPL-3.0-or-later
-- Real-time fights: wires the Brawl import (Server/Brawl/, tinybike's Brawl,
-- GPL-3, credited in NOTICE) into Dark and Gate.
--
-- What Brawl does in a fight: BG3's combat starts as usual, then the party's
-- turn is kept permanently active (party initiative just above the enemies,
-- an invisible "combat helper" keeps the combat alive), enemies end their
-- turn at once and act on Brawl's own per-character timers (AI.act every
-- action interval), and a 6 s timer advances the rounds, so statuses,
-- recharges and concentration tick at 1 turn = 6 s. Nobody waits for a turn.
--
-- Brawl's modules talk to each other through globals that its Main.lua
-- assigns in load order. Register() does the same, with the State singleton
-- renamed BrawlState, and without Swarm Mode, Leaderboard, Loadouts,
-- Encounters or Brawl's keybind commands (stripped in the files, every change
-- marked "DAG:"; docs/brawl-import.md). Settings come from data/realtime.lua
-- instead of Brawl's MCM page.
--
--   !dag_rt on | off      real time / BG3's vanilla turn-based (debugging)
--   !dag_rt status        the current fight: brawlers, targets, timers
--   !dag_rt debug on|off  Brawl's own debug lines into our session log

local Log = Ext.Require("Shared/Log.lua")
local cfg = Ext.Require("data/realtime.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")
local SpellRange = Ext.Require("Shared/SpellRange.lua")

local Adapter = { listening = false }

local registry = {}      -- Brawl module name -> table (State = BrawlState), for Memo.lua
local loaded = false
local hooks = {}         -- name -> fn(...) for our own systems (Parts 2-5)

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function name(uuid)
    local ok, n = pcall(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(uuid)) end)
    return (ok and n and n ~= "") and n or tostring(uuid)
end
Adapter.Name = name

-- Brawl's debug lines (Utils.debugDisplay, DAG patch) when !dag_rt debug is on.
local function brawlLog(file, isDump, ...)
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "table" then
            local ok, s = pcall(Ext.Json.Stringify, v)
            v = ok and s or "<table>"
        end
        parts[#parts + 1] = tostring(v)
    end
    Log.Write("Brawl[" .. file .. "]" .. (isDump and " dump: " or ": ") .. table.concat(parts, " "))
end

local function applySettings()
    local S = BrawlState.Settings
    S.ModEnabled = cfg.enabled ~= false
    S.CompanionAIEnabled = cfg.companion_ai ~= false
    S.TruePause = cfg.true_pause ~= false
    S.AutoPauseOnDowned = false          -- downed = our bleed-out, never a pause
    S.AutoPauseOnCombatStart = false
    S.ActionInterval = tonumber(cfg.action_interval_s) or 6.0
    -- How much initiative shifts each fighter's pace (Brawl shipped 0.3).
    Constants.ACTION_INTERVAL_RESCALING = tonumber(cfg.initiative_spread) or Constants.ACTION_INTERVAL_RESCALING
    DAG_MoveGait = cfg.move_gait   -- Brawl Movement.getMovementSpeed (DAG patch)
    S.CombatRoundDuration = tonumber(cfg.round_s) or 6.0
    S.FullAuto = false
    S.HitpointsMultiplier = tonumber(cfg.hitpoints_multiplier) or 1.0
    -- At x1 Brawl's HP scaling only rewrites every fighter's Health with the
    -- same values (+ Replicate), at each level start, fight join and HP change
    -- (a Health subscription per party member). Off at x1 (2026-10-13: it ran on
    -- the character creation dummy when BG3 crashed there; !dag_hp is ours).
    if S.HitpointsMultiplier == 1.0 then
        local noop = function() end
        BrawlState.setupPartyMembersHitpoints = noop
        BrawlState.modifyHitpoints = noop
        BrawlState.revertHitpoints = noop
    end
    S.CompanionTactics = cfg.companion_tactics or "Balanced"
    S.DefensiveTacticsMaxDistance = tonumber(cfg.defensive_tactics_max_distance) or 15
    S.CompanionAIMaxSpellLevel = tonumber(cfg.companion_ai_max_spell_level) or 0
    S.HogwildMode = false
    S.TurnBasedSwarmMode = false
    S.LeaderboardEnabled = false
    S.PlayersGoTogether = true
    S.ExcludeEnemyTiers = cfg.exclude_enemy_tiers
    S.DisableEnemyAI = false
    if cfg.max_party_size == nil then
        BrawlState.setMaxPartySize = function() end   -- leave BG3's party size alone
    else
        S.MaxPartySize = cfg.max_party_size
    end
end

-- Wrap a Brawl module function so fn(...) runs after the original with the
-- same arguments. Brawl calls its modules through the globals at call time,
-- so replacing the field is enough.
function Adapter.After(mod, fname, fn)
    local orig = mod[fname]
    mod[fname] = function(...)
        local r = table.pack(orig(...))
        local ok, err = pcall(fn, ...)
        if not ok then Log.Write(string.format("RT: hook after %s failed: %s", fname, tostring(err))) end
        return table.unpack(r, 1, r.n)
    end
end

-- Our systems subscribe to fight events here (Downed, NoReactions, ...).
function Adapter.Hook(event, fn)
    hooks[event] = hooks[event] or {}
    table.insert(hooks[event], fn)
end
local function fire(event, ...)
    for _, fn in ipairs(hooks[event] or {}) do
        local ok, err = pcall(fn, ...)
        if not ok then Log.Write("RT: " .. event .. " hook failed: " .. tostring(err)) end
    end
end

-- ---------------------------------------------------------------------
-- State-change log (combat start / stop, who joins)
-- ---------------------------------------------------------------------
local fight = { active = false, startedAt = 0, joined = {} }

local function brawlerCount()
    local n = 0
    for _ in pairs(Roster.getBrawlers() or {}) do n = n + 1 end
    return n
end

local function registerStateLog()
    Ext.Osiris.RegisterListener("CombatStarted", 1, "after", function(combatGuid)
        fight.active, fight.startedAt, fight.joined = true, now(), {}
        Log.Write(string.format("RT: combat %s started -> %s", tostring(combatGuid),
            Adapter.Enabled() and ("REAL TIME (Brawl loop, 1 round = " .. tostring(BrawlState.Settings.CombatRoundDuration) .. " s)")
            or "vanilla TURN-BASED (!dag_rt off)"))
        fire("CombatStarted", combatGuid)
    end)
    Ext.Osiris.RegisterListener("CombatEnded", 1, "after", function(combatGuid)
        Log.Write(string.format("RT: combat %s ended after %.1f s", tostring(combatGuid), (now() - fight.startedAt) / 1000))
        fight.active = false
        fire("CombatEnded", combatGuid)
    end)
    Ext.Osiris.RegisterListener("EnteredCombat", 2, "after", function(entity, combatGuid)
        local okU, uuid = pcall(Osi.GetUUID, entity)
        uuid = okU and uuid or tostring(entity)
        if fight.joined[uuid] then return end
        fight.joined[uuid] = true
        -- Brawl's invisible combat helpers rejoin every round: not logged.
        local okH, helper = pcall(function() return Utils.isCombatHelper(uuid) end)
        if okH and helper then fire("EnteredCombat", uuid, combatGuid); return end
        local okG, group = pcall(Osi.GetCombatGroupID, uuid)
        local okP, isPlayer = pcall(Osi.IsPartyMember, uuid, 1)
        Log.Write(string.format("RT: %s joined combat %s (%s, group %s)", name(uuid), tostring(combatGuid),
            (okP and tonumber(isPlayer) == 1) and "party" or "npc", okG and tostring(group) or "?"))
        fire("EnteredCombat", uuid, combatGuid)
    end)
    Ext.Osiris.RegisterListener("CombatRoundStarted", 2, "after", function(combatGuid, round)
        if cfg.log_rounds then
            Log.Write(string.format("RT: round %s of %s (%d brawlers)", tostring(round), tostring(combatGuid), brawlerCount()))
        end
        fire("CombatRoundStarted", combatGuid, round)
    end)
    -- 1 turn = 6 s: the first time each timed status lands during a
    -- real-time fight, log its turns and the seconds it got ("BLESS 10 turns
    -- -> 60 s"). Brawl ticks enemy statuses 6 s per round (Spells.lua).
    local seenStatus = {}
    Ext.Osiris.RegisterListener("StatusApplied", 4, "after", function(obj, status)
        if not fight.active or not Adapter.Enabled() or seenStatus[status] then return end
        seenStatus[status] = true
        local okT, turns = pcall(function() return Osi.GetStatusTurns(obj, status) end)
        local okL, left = pcall(function() return Osi.GetStatusCurrentLifetime(obj, status) end)
        turns, left = okT and tonumber(turns) or nil, okL and tonumber(left) or nil
        if not turns or turns <= 0 or not left or left <= 0 then return end
        Log.Write(string.format("RT: status %s on %s: %d turns -> %.0f s (1 turn = %.0f s)", tostring(status), name(obj), turns, left,
            tonumber(BrawlState.Settings.CombatRoundDuration) or 6))
    end)
end

function Adapter.InFight() return fight.active end

-- ---------------------------------------------------------------------
-- On / off
-- ---------------------------------------------------------------------
function Adapter.Enabled() return loaded and BrawlState.Settings.ModEnabled == true end

local function enable(why)
    if Adapter.Enabled() and Adapter.listening then return end
    BrawlState.Settings.ModEnabled = true
    Listeners.startListeners()
    Adapter.listening = true
    local okH, host = pcall(Osi.GetHostCharacter)
    local okR, level = pcall(Osi.GetRegion, okH and host or nil)
    if okR and level and not DAG_SkipLevel(level) then Listeners.onStarted(level) end
    Log.Write("RT: real-time fights ON (" .. tostring(why) .. ")")
    fire("Enabled")
end

local function disable(why)
    if not Adapter.Enabled() then return end
    fire("Disabling")
    BrawlState.Settings.ModEnabled = false
    if Adapter.listening then Listeners.stopListeners() end
    Adapter.listening = false
    Movement.removeAllDashSpeedBoosts()
    Log.Write("RT: real-time fights OFF -> the next fight is BG3's vanilla turn-based (" .. tostring(why) .. ")")
end

-- Real time on / off (!dag_play and the on / off key, Server/PlayMode.lua).
function Adapter.Enable(why) enable(why) end
function Adapter.Disable(why) disable(why) end

-- True when this character's fight is really turn-based right now: in combat
-- with real time off, or the party paused into force-turn-based. Scripted
-- animations stall in that mode (Server/Net.lua).
function Adapter.IsTurnBased(uuid)
    local okC, inC = pcall(Osi.IsInCombat, uuid)
    if not okC or tonumber(inC) ~= 1 then return false end
    if not Adapter.Enabled() then return true end
    local okF, ftb = pcall(Osi.IsInForceTurnBasedMode, uuid)
    return okF and tonumber(ftb) == 1
end

local function status()
    Log.Write(string.format("RT: %s, listeners %s, fight %s, combat helper %s, round %s s, action interval %s s",
        BrawlState.Settings.ModEnabled and "ON" or "OFF", tostring(Adapter.listening), fight.active and "active" or "none",
        tostring(BrawlState.Session.CombatHelper), tostring(BrawlState.Settings.CombatRoundDuration),
        tostring(BrawlState.Settings.ActionInterval)))
    for uuid, b in pairs(Roster.getBrawlers() or {}) do
        Log.Write(string.format("  %s (%s): archetype %s, target %s, every %.1f s, pulse %s%s", name(uuid), uuid,
            tostring(b.archetype), b.targetUuid and name(b.targetUuid) or "-", (b.actionInterval or 0) / 1000,
            BrawlState.Session.PulseActionTimers[uuid] and "on" or "off", b.isPaused and ", PAUSED" or ""))
    end
end

-- Must run while the bootstrap loads (Ext.Require only works then).
function Adapter.Register()
    if loaded then return end
    -- Brawl's Main.lua, in its order (Leaderboard, Loadouts, Commands and
    -- Swarm are not imported). Each module reads the earlier ones' globals
    -- while it loads.
    Constants  = Ext.Require("Server/Brawl/Constants.lua")
    Utils      = Ext.Require("Server/Brawl/Utils.lua")
    BrawlState = Ext.Require("Server/Brawl/State.lua")
    Spells     = Ext.Require("Server/Brawl/Spells.lua")
    Resources  = Ext.Require("Server/Brawl/Resources.lua")
    Movement   = Ext.Require("Server/Brawl/Movement.lua")
    Roster     = Ext.Require("Server/Brawl/Roster.lua")
    Actions    = Ext.Require("Server/Brawl/Actions.lua")
    Pick       = Ext.Require("Server/Brawl/Pick.lua")
    AI         = Ext.Require("Server/Brawl/AI.lua")
    Pause      = Ext.Require("Server/Brawl/Pause.lua")
    Quests     = Ext.Require("Server/Brawl/Quests.lua")
    Listeners  = Ext.Require("Server/Brawl/Listeners.lua")
    TurnOrder  = Ext.Require("Server/Brawl/TurnOrder.lua")
    RT         = Ext.Require("Server/Brawl/RealTime.lua")
    M          = Ext.Require("Server/Brawl/Memo.lua")
    registry = {
        Constants = Constants, Utils = Utils, State = BrawlState, Spells = Spells, Resources = Resources,
        Movement = Movement, Roster = Roster, Actions = Actions, Pick = Pick, AI = AI, Pause = Pause,
        Quests = Quests, Listeners = Listeners, TurnOrder = TurnOrder, RealTime = RT,
    }
    DAG_BrawlModule = function(n) return registry[n] end   -- Memo.lua (DAG patch)
    -- Brawl stays out of character creation (Listeners.onLevelGameplayStarted, DAG patch).
    DAG_SkipLevel = function(level)
        local ok, v = pcall(Osi.IsCharacterCreationLevel, level)
        local skip = ok and tonumber(v) == 1
        if skip then Log.Write("RT: " .. tostring(level) .. " is character creation: Brawl's level start skipped") end
        return skip
    end
    -- Brawl's AI keeps BG3's own spell ranges (how close NPCs and companions
    -- walk before they cast); ours are for the player's aim (Shared/SpellRange.lua;
    -- DAG patches in Utils.getSpellRange and Spells.getSpellInfo).
    DAG_SpellRangeVanilla = SpellRange.Vanilla
    loaded = true
    applySettings()
    registerStateLog()

    Ext.Events.SessionLoaded:Subscribe(function()
        -- Brawl's own session start (its listeners when enabled).
        local ok, err = pcall(Listeners.onSessionLoaded)
        Adapter.listening = ok and BrawlState.Settings.ModEnabled == true
        Log.Write(ok and ("RT: Brawl loop ready, real-time fights " .. (Adapter.Enabled() and "ON" or "OFF (data/realtime.lua)"))
            or ("RT: Brawl session start FAILED: " .. tostring(err)))
    end)

    -- Also typed in the client console (Shared/ConsoleForward.lua).
    ConsoleForward.Server("dag_rt", function(_, a, b)
        if a == "on" then enable("!dag_rt on")
        elseif a == "off" then disable("!dag_rt off")
        elseif a == "debug" then
            local on = (b ~= "off" and b ~= "0")
            Constants.DEBUG_LOGGING = on
            DAG_BrawlLog = on and brawlLog or nil
            Log.Write("RT: Brawl debug lines " .. (on and "ON (into the session log)" or "OFF"))
        else status() end
    end)
    -- !dag_ai_interval <s>: how often your side's AI acts (companions and NPC
    -- allies, data/realtime.lua action_interval_s; the enemies' pace follows
    -- BG3's difficulty, Server/Combat/Pace.lua). Fighters already in a fight
    -- keep their timers.
    ConsoleForward.Server("dag_ai_interval", function(_, v)
        if tonumber(v) then
            BrawlState.Settings.ActionInterval = math.max(1.0, tonumber(v))
            cfg.action_interval_s = BrawlState.Settings.ActionInterval
        end
        Log.Write(string.format("RT: your side's AI pace %.1f s (initiative +-%.0f %% scale; from the next fight; enemies: !dag_enemy_pace)",
            BrawlState.Settings.ActionInterval, (Constants.ACTION_INTERVAL_RESCALING or 0) * 100))
    end)
    Log.Write(string.format("RT: Brawl import loaded (%d modules; real time %s; round %s s; your side's AI pace %.1f s, enemies' by BG3's difficulty (Server/Combat/Pace.lua), initiative scale %.2f; !dag_rt on|off|status|debug)",
        16, BrawlState.Settings.ModEnabled and "on" or "off", tostring(BrawlState.Settings.CombatRoundDuration),
        BrawlState.Settings.ActionInterval, Constants.ACTION_INTERVAL_RESCALING or 0))
end

return Adapter
