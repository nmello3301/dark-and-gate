-- SPDX-License-Identifier: GPL-3.0-or-later
-- Client input capture for combat.
--
-- Gate: POV on + no modal UI (see State:IsCombatActive). realTime and
-- inFight are deliberately NOT gated here — the user wants LMB / RMB /
-- 1-0 to work in exploration first-person for training-dummy tests.
--
-- Arm-then-cast HARD mode (user requirement):
--   number key -> armedSpell = <id>
--   LMB:
--     if armedSpell -> Spells.Cast(armedSpell) at crosshair; disarm.
--                      (Never swings while armed.)
--     else          -> Swing.OnLMB() (vanilla melee).
--   RMB tap:
--     if armedSpell -> disarm (no block that press).
--     else          -> block flag ON (stub, no DR applied).
--   Pressing the same number again -> disarm.
--   Pressing a different number -> re-arm.
--   Esc is NOT used (BG3 opens its own menu).

local Log   = Ext.Require("Shared/Log.lua")
local State = Ext.Require("Client/Combat/State.lua")

local M = {}

local Swing, Hotbar, Spells  -- Resolved lazily to break require cycles.

local function requireLazy()
    if not Swing  then Swing  = Ext.Require("Client/Combat/Swing.lua") end
    if not Hotbar then Hotbar = Ext.Require("Client/Combat/Hotbar.lua") end
    if not Spells then Spells = Ext.Require("Client/Combat/Spells.lua") end
end

local function recordEvent(kind, button, pressed)
    State.lastInputEvent = string.format(
        "%s %s %s@%dms gateActive=%s",
        kind, tostring(button), pressed and "down" or "up",
        tonumber(Ext.Timer.MonotonicTime()),
        tostring(State:IsCombatActive()))
end

-- MouseButtonInput: event.Button is an int (SDL button index). SE binds
-- some names like "Left1" / "Right1" / "Middle" as the string form of
-- the enum. We match both the string form AND the raw int code so we
-- don't rely on an exact SE build.
local function isLMB(button)
    local s = tostring(button or "")
    return s == "Left1" or s == "LeftButton" or s == "1" or button == 1
end
local function isRMB(button)
    local s = tostring(button or "")
    return s == "Right1" or s == "RightButton" or s == "3" or button == 3
end

local function onMouse(event)
    local button  = event.Button
    local pressed = event.Pressed and true or false
    recordEvent("Mouse", button, pressed)

    if not State:IsCombatActive() then return end

    if isLMB(button) then
        if pressed then
            requireLazy()
            if State.armedSpell then
                local armed = State.armedSpell
                State.armedSpell = nil
                Spells.Cast(armed)
            else
                Swing.OnLMB()
            end
        end
        pcall(function() event:PreventAction() end)
    elseif isRMB(button) then
        if pressed then
            if State.armedSpell then
                Log.Write("Combat: canceled armed spell (RMB) was=" .. tostring(State.armedSpell))
                State.armedSpell = nil
            else
                State.blocking = true
                Log.Write("Combat: block ON (stub, no DR applied)")
            end
        else
            if State.blocking then
                State.blocking = false
                Log.Write("Combat: block OFF")
            end
        end
        pcall(function() event:PreventAction() end)
    end
end

-- KeyInput: event.Key = "1".."0", "H", etc. event.Event = "KeyDown"/"KeyUp".
local KEY_TO_SLOT = {
    ["1"] = 1, ["2"] = 2, ["3"] = 3, ["4"] = 4, ["5"] = 5,
    ["6"] = 6, ["7"] = 7, ["8"] = 8, ["9"] = 9, ["0"] = 10,
}

local function onKey(event)
    local key   = tostring(event.Key or "")
    local evt   = tostring(event.Event or "")
    recordEvent("Key[" .. evt .. "]", key, evt == "KeyDown")

    -- H toggles the hotbar window regardless of gate.
    if key == "H" and evt == "KeyDown" then
        requireLazy()
        Hotbar.ToggleWindow()
        return
    end

    if not State:IsCombatActive() then return end

    local slot = KEY_TO_SLOT[key]
    if slot and evt == "KeyDown" then
        requireLazy()
        Hotbar.PressSlot(slot)
        pcall(function() event:PreventAction() end)
    end
end

function M.Register()
    Ext.Events.MouseButtonInput:Subscribe(function(e) pcall(onMouse, e) end)
    Ext.Events.KeyInput:Subscribe(function(e) pcall(onKey, e) end)
    Log.Write("Combat Input: registered (LMB/RMB/1-0 + H hotbar)")
end

return M
