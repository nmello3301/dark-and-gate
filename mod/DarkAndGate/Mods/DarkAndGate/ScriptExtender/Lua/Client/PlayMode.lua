-- SPDX-License-Identifier: GPL-3.0-or-later
-- !dag_play: one command for the whole mod (developer 2026-10-12: "one
-- command that can trigger the full mod functionality", for a playthrough
-- from game start). It turns on, and remembers on this PC
-- (Client/PlayFlag.lua):
--   * first person with mouse-look (FullPov); BG3's combat camera kept away
--     and WASD in fights (the DLL); CamGuard; our HUD and crosshair;
--   * on the server (Server/PlayMode.lua): real-time fights, our combat
--     rules for the AI, fights ending once the enemies are gone;
--   * your own spells on the hotbar: a character with no saved layout gets
--     its own cantrips and spells (damage spells first), not the M1b test
--     set (Fire Bolt / Fireball / Misty Step), and the Prepare Hotbar menu
--     lists only spells it has (Client/Combat/Hotbar.lua, HotbarMenu.lua).
-- While it is on, first person comes back by itself after every load and
-- level change, and after character creation in a new game: the server says
-- when the level isn't character creation (PlayReady). !dag_full_pov off
-- still turns first person off until the next level.
-- The max HP bonus is its own command (Server/Combat/HpBonus.lua, !dag_hp 50).
--
--   !dag_play [on|off|status]      (no argument = on)

local Log       = Ext.Require("Shared/Log.lua")
local Net       = Ext.Require("Shared/Net.lua")
local ClientNet = Ext.Require("Client/Net.lua")
local PlayFlag  = Ext.Require("Client/PlayFlag.lua")
local FullPov   = Ext.Require("FullPov.lua")
local CamGuard  = Ext.Require("Client/CamGuard.lua")
local Hud       = Ext.Require("Client/HUD/Hud.lua")
local CombatHUD = Ext.Require("Client/Combat/HUD.lua")
local Overlay   = Ext.Require("Client/HUD/Overlay.lua")
local State     = Ext.Require("Client/Combat/State.lua")

local M = {}

local want = false                    -- turn first person on once the level is ready
local level = { name = nil, cc = nil } -- the server's PlayReady
local gameState = nil                 -- last GameStateChanged ToState
local inGame = false                  -- a game session is loaded (there is a server to tell)
local tickAt, waitSince = -1e9, nil

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

-- The client's share of "everything on" (the defaults, in case a test
-- turned one off).
local function clientOn()
    pcall(CamGuard.SetOn, true)
    pcall(Hud.SetMode, "on")
    pcall(CombatHUD.SetCrosshair, true)
    pcall(FullPov.SetCombatWasd, true)
    pcall(FullPov.SetNoCombatCam, true)
end

local function characterReady()
    local ok, ready = pcall(function()
        local e = Ext.Entity.GetAllEntitiesWithComponent("ClientControl")[1]
        return e ~= nil and e.Transform ~= nil
    end)
    return ok and ready == true
end

-- In the main menu there is no server yet (SE warns "a host that does not
-- understand extender protocol", playtest 2026-10-13): the flag is saved and
-- the next session start tells the server. A controlled character means a
-- game is loaded (also after a Lua reset, which fires no SessionLoaded).
local function ask()
    if not inGame and not characterReady() then
        Log.Write("PlayMode: no game loaded yet; the server is told when one starts")
        return
    end
    local ok, err = pcall(ClientNet.Send, Net.Channels.PlayMode, { on = PlayFlag.On() })
    if not ok then Log.Write("PlayMode: the server can't be told yet (" .. tostring(err) .. "); it is asked at the next session start") end
end

local function tick()
    local t = now()
    if t - tickAt < 250 then return end
    tickAt = t
    if not PlayFlag.On() or not want then return end
    local why = nil
    if level.cc == nil then why = "waiting for the server's level"
    elseif level.cc then why = "character creation"
    elseif gameState and gameState ~= "Running" then why = "loading (" .. tostring(gameState) .. ")"
    elseif not characterReady() then why = "no controlled character yet" end
    if why then
        waitSince = waitSince or t
        if t - waitSince > 15000 then
            waitSince = t
            Log.Write("PlayMode: first person waits: " .. why)
        end
        return
    end
    want, waitSince = false, nil
    if not FullPov.IsOn() then
        clientOn()
        FullPov.SetOn(true)
        Log.Write(string.format("PlayMode: first person ON by itself (level %s)", tostring(level.name)))
    end
end

local function status(toast)
    local text = PlayFlag.On() and "Dark and Gate: play mode ON (first person, real-time fights, your spells on 1-0)"
        or "Dark and Gate: play mode OFF (!dag_play turns everything on)"
    Log.Write(string.format("PlayMode: %s; first person %s; level %s%s", PlayFlag.On() and "ON" or "OFF",
        FullPov.IsOn() and "on" or "off", tostring(level.name), level.cc and " (character creation)" or ""))
    if toast then pcall(Overlay.Toast, text, 3) end
end

function M.Register()
    Ext.RegisterNetListener(Net.Channels.PlayReady, function(_, payload)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" then return end
        level.name, level.cc = p.level, p.cc == true
        PlayFlag.SetLevel(p.level, p.cc == true)
        if PlayFlag.On() then
            want = true
            Log.Write(string.format("PlayMode: level %s%s", tostring(p.level), level.cc and " = character creation, first person waits" or " -> first person on when ready"))
        end
    end)
    -- Dialogues / cutscenes (Server/Scene.lua): our HUD and input stand aside.
    Ext.RegisterNetListener(Net.Channels.Scene, function(_, payload)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" then return end
        local on = p.on == true
        if on ~= State.sceneOn then
            State.sceneOn = on
            Log.Write("PlayMode: " .. (on and "dialogue / cutscene: our HUD and input stand aside" or "dialogue / cutscene over: HUD back"))
        end
    end)
    pcall(function()
        Ext.Events.GameStateChanged:Subscribe(function(e)
            gameState = tostring(e.ToState)
            if gameState == "Menu" or gameState == "LoadMenu" or gameState == "InitMenu" then inGame = false end
        end)
    end)
    Ext.Events.SessionLoaded:Subscribe(function()
        inGame = true
        if PlayFlag.On() then
            want = true
            ask()
            Log.Write("PlayMode: play mode is ON (remembered): asking the server for the level")
        end
    end)
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)

    Ext.RegisterConsoleCommand("dag_play", function(_, a)
        a = a and tostring(a):lower() or ""
        if a == "status" then status(true); return end
        if a == "off" or a == "0" then
            PlayFlag.Set(false)
            want = false
            FullPov.SetOn(false)
            ask()
            status(true)
            return
        end
        PlayFlag.Set(true)
        clientOn()
        want = true
        ask()
        status(true)
        Log.Write("PlayMode: max HP bonus: !dag_hp 50 (your character) or !dag_hp 50 party")
    end)
    Log.Write("PlayMode: registered (!dag_play [on|off|status]; play mode " .. (PlayFlag.On() and "ON" or "off") .. ")")
end

return M
