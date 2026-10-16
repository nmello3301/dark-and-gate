-- SPDX-License-Identifier: GPL-3.0-or-later
-- Meta-Points, client side (docs/DESIGN.md "Meta-Points"; the server owns
-- the points: Server/MetaPoints.lua).
--   * asks the server for the config and the party's points once the
--     character is known (MetaQuery), keeps every MetaState
--     (MetaPoints.SetState) for the menu and the client-side effects;
--   * the hotkey (data/metapoints.lua hotkey, P; this PC's metapoints.json
--     may change it) opens the menu (Client/HUD/MetaMenu.lua), in first or
--     third person;
--   * level-up notice (MetaNotify), and once per session if the character
--     you control has points to spend;
--   * CHA move speed: a Movement modifier, only while Dark and Gate's first
--     person is live (State.IsCombatActive: first person on, no dialogue or
--     cutscene; fights or not), so pathing, cutscenes and dialogue movement
--     are untouched. (Cast time, cooldown and jump read MetaPoints where
--     they are computed: Client/Combat/Spells.lua, Swing.lua, Movement/Jump.lua.)
--
-- Console (client): !dag_meta_menu (same as the hotkey); !dag_meta_print and
-- !dag_meta_selftest print this client's view too (then the server's).

local Log            = Ext.Require("Shared/Log.lua")
local Net            = Ext.Require("Shared/Net.lua")
local ClientNet      = Ext.Require("Client/Net.lua")
local MetaPoints     = Ext.Require("Shared/MetaPoints.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")
local State          = Ext.Require("Client/Combat/State.lua")
local Me             = Ext.Require("Client/Me.lua")
local Overlay        = Ext.Require("Client/HUD/Overlay.lua")
local Movement       = Ext.Require("Client/Movement/Movement.lua")
local MetaMenu       = Ext.Require("Client/HUD/MetaMenu.lua")
local MeleeCooldown  = Ext.Require("Shared/MeleeCooldown.lua")

local M = {}

local hotkey = "P"
local asked = false
local startNoticeDone = false

local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function loadHotkey()
    local file = MetaPoints.ReadFile()
    local k = (file and file.hotkey) or MetaPoints.Defaults().hotkey or "P"
    hotkey = tostring(k):upper()
end
function M.Hotkey() return hotkey end

local function notify(text, secs)
    if State.povOn then Overlay.Toast(text, secs) else MetaMenu.Notice(text, secs) end
    Log.Write("MetaPoints: notice \"" .. text .. "\"")
end

local function describe(uuid)
    local lines = {}
    local st = MetaPoints.State(uuid)
    if not st then return { "no Meta-Points state from the server yet for " .. tostring(uuid) } end
    lines[#lines + 1] = string.format("%s level %d: %d points, %d unspent | %s", tostring(st.name), st.level or 0, st.total or 0, st.unspent or 0,
        Ext.Json.Stringify(st.spent or {}))
    for _, e in ipairs(MetaPoints.Config().effects) do
        local v = MetaPoints.Value(uuid, e.id) or 0
        lines[#lines + 1] = string.format("  %-15s %s -> %s", e.id, e.stat, e.kind == "fraction" and string.format("%.1f %%", v * 100) or string.format("x%.3f", v))
    end
    local Spells = Ext.Require("Client/Combat/Spells.lua")
    local cd = MeleeCooldown.Seconds("longsword", uuid)
    local w, r = Movement.Mults()
    lines[#lines + 1] = string.format("client: cast time %.3f s (Fire Bolt), melee cooldown %.3f s (swing x%.2f), move walk x%.2f run x%.2f now (CHA x%.2f, first person %s), min action interval %.3f s",
        Spells.CastTime("Projectile_FireBolt", uuid), cd, MeleeCooldown.SwingRate(cd, 420), w or 1, r or 1,
        MetaPoints.Mult(uuid, "move_speed"), State.IsCombatActive() and "live" or "off", MetaPoints.MinInterval())
    return lines
end

local function tick()
    if not asked and Me.Uuid() then
        asked = true
        ClientNet.Send(Net.Channels.MetaQuery, {})
    end
    MetaMenu.Tick()
end

function M.Register()
    loadHotkey()
    MetaPoints.SelfTest(true)

    Ext.RegisterNetListener(Net.Channels.MetaConfig, function(_, payload)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" then return end
        if MetaPoints.SetConfig(p.config) then
            MetaMenu.ConfigChanged()
            Log.Write(string.format("MetaPoints: the host's config (%d per level, respec %s, min action interval %.3f s)",
                tonumber(MetaPoints.Config().points_per_level) or 0, tostring(MetaPoints.Config().respec_mode), MetaPoints.MinInterval()))
        end
    end)
    Ext.RegisterNetListener(Net.Channels.MetaState, function(_, payload)
        local ok, st = pcall(Ext.Json.Parse, payload)
        if not ok or type(st) ~= "table" or not st.uuid then return end
        MetaPoints.SetState(st.uuid, st)
        if not startNoticeDone and st.uuid == Me.Uuid() then
            startNoticeDone = true
            if (tonumber(st.unspent) or 0) > 0 and MetaPoints.Config().notify_level_up ~= false then
                notify(string.format("%s: %d Meta-Points to spend (%s)", tostring(st.name), st.unspent, hotkey), 6)
            end
        end
    end)
    Ext.RegisterNetListener(Net.Channels.MetaNotify, function(_, payload)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" then return end
        notify(string.format("Level %d! %s has %d Meta-Points to spend (%s)", tonumber(p.level) or 0, tostring(p.name),
            tonumber(p.unspent) or 0, hotkey), 7)
    end)

    Ext.Events.KeyInput:Subscribe(function(e)
        local ok = pcall(function()
            if tostring(e.Key or ""):upper() ~= hotkey then return end
            -- In first person the key is ours (a BG3 panel open: the UI's).
            if State.IsCombatActive() then
                if State.uiPaused then return end
                pcall(function() e:PreventAction() end)
            end
            if tostring(e.Event or "") == "KeyDown" and not e.Repeat then MetaMenu.Toggle() end
        end)
        if not ok then return end
    end)

    -- CHA: move speed, only while first person is live.
    Movement.AddModifier("meta", function(ent)
        if not State.IsCombatActive() then return 1.0 end
        local uuid = nil
        pcall(function() uuid = ent.Uuid.EntityUuid end)
        return MetaPoints.Mult(uuid or Me.Uuid(), "move_speed")
    end)

    Ext.Events.Tick:Subscribe(function() pcall(tick) end)

    Ext.RegisterConsoleCommand("dag_meta_menu", function() MetaMenu.Toggle() end)
    ConsoleForward.Local("dag_meta_print", function()
        Log.Write("MetaPoints: client values:")
        for _, l in ipairs(describe(Me.Uuid())) do Log.Write("MetaPoints:   " .. l) end
    end)
    ConsoleForward.Local("dag_meta_selftest", function() MetaPoints.SelfTest(true) end)
    ConsoleForward.Local("dag_meta_reload", function()
        loadHotkey()
        Log.Write("MetaPoints: hotkey " .. hotkey .. " (this PC's metapoints.json); the rest comes from the host")
    end)
    Log.Write("MetaPoints: registered (client; menu on " .. hotkey .. ")")
end

return M
