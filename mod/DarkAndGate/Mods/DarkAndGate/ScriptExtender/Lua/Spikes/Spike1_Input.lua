-- SPDX-License-Identifier: GPL-3.0-or-later
-- Spike 1: capture + suppress LMB / RMB / keys 1-0 on the client.
--
-- Subscribes to Ext.Events.EclLuaKeyInput and EclLuaMouseButton. Two toggles:
--   logging   -- off by default, enable with !dag1_log_on
--   suppress  -- off by default; when on, calls PreventAction() on the 12
--                inputs we care about (LMB, RMB, keys 1..9 and 0).
--
-- The 12 inputs are the baseline for M1's melee + hotbar; proving suppression
-- here means our swing and hotbar handlers won't fire alongside BG3's defaults.
-- SDL scancodes from https://wiki.libsdl.org/SDL2/SDLScancodeLookup:
--   1 = 30, 2 = 31, 3 = 32, 4 = 33, 5 = 34, 6 = 35, 7 = 36, 8 = 37, 9 = 38, 0 = 39.

local Log = Ext.Require("Shared/Log.lua")

local M = {}

local logging  = false
local suppress = false

-- e.Key is a SDLScanCode enum userdata; SE prints it as NUM_1..NUM_0 for the
-- digit row (not Key1 as the IDE helpers suggest).
local DIGIT_KEY_NAMES = {
    NUM_1 = true, NUM_2 = true, NUM_3 = true, NUM_4 = true, NUM_5 = true,
    NUM_6 = true, NUM_7 = true, NUM_8 = true, NUM_9 = true, NUM_0 = true,
}

-- Mouse Button values follow SDL: 1 = left, 2 = middle, 3 = right.
local MOUSE_LEFT  = 1
local MOUSE_RIGHT = 3

local function onKey(e)
    local keyName = tostring(e.Key)
    if logging then
        Log.Write(string.format("Spike1: key %s pressed=%s repeat=%s mods=%s",
            keyName, tostring(e.Pressed), tostring(e.Repeat), tostring(e.Modifiers)))
    end
    if suppress and DIGIT_KEY_NAMES[keyName] then
        if e.CanPreventAction then
            e:PreventAction()
            if logging then Log.Write("Spike1:   -> PreventAction") end
        else
            if logging then Log.Write("Spike1:   -> CanPreventAction=false, cannot block") end
        end
    end
end

local function onMouse(e)
    local btn = tonumber(e.Button)
    local name = (btn == MOUSE_LEFT and "LMB")
              or (btn == MOUSE_RIGHT and "RMB")
              or ("mbtn=" .. tostring(btn))
    if logging then
        Log.Write(string.format("Spike1: mouse %s pressed=%s clicks=%s at (%d,%d)",
            name, tostring(e.Pressed), tostring(e.Clicks),
            tonumber(e.X) or -1, tonumber(e.Y) or -1))
    end
    if suppress and (btn == MOUSE_LEFT or btn == MOUSE_RIGHT) then
        if e.CanPreventAction then
            e:PreventAction()
            if logging then Log.Write("Spike1:   -> PreventAction") end
        else
            if logging then Log.Write("Spike1:   -> CanPreventAction=false, cannot block") end
        end
    end
end

function M.Register()
    -- IDE helpers call these EclLuaKeyInput / EclLuaMouseButton, but the real
    -- runtime names in LuaClient.cpp are KeyInput / MouseButtonInput.
    Ext.Events.KeyInput:Subscribe(function(e)
        local ok, err = pcall(onKey, e)
        if not ok then Log.Write("Spike1: key handler err=" .. tostring(err)) end
    end)
    Ext.Events.MouseButtonInput:Subscribe(function(e)
        local ok, err = pcall(onMouse, e)
        if not ok then Log.Write("Spike1: mouse handler err=" .. tostring(err)) end
    end)

    Ext.RegisterConsoleCommand("dag1_log_on",       function() logging  = true;  Log.Write("Spike1: logging ON")  end)
    Ext.RegisterConsoleCommand("dag1_log_off",      function() logging  = false; Log.Write("Spike1: logging OFF") end)
    Ext.RegisterConsoleCommand("dag1_suppress_on",  function() suppress = true;  Log.Write("Spike1: suppress ON (LMB/RMB/1-0)") end)
    Ext.RegisterConsoleCommand("dag1_suppress_off", function() suppress = false; Log.Write("Spike1: suppress OFF") end)
    Log.Write("Spike1: registered dag1_log_on/off and dag1_suppress_on/off")
end

return M
