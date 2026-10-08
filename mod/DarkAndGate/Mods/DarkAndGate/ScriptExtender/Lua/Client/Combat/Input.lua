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

-- MouseButtonInput: event.Button is an SDL button index. Spike 1 verified
-- that tonumber(e.Button) returns 1=left, 2=middle, 3=right.
local function isLMB(button) return tonumber(button) == 1 end
local function isRMB(button) return tonumber(button) == 3 end

local function onMouse(event)
    local button  = event.Button
    local pressed = event.Pressed and true or false
    recordEvent("Mouse", button, pressed)

    -- Log every mouse DOWN event. Low volume, high value: if LMB clicks
    -- never show up here, SE isn't delivering MouseButtonInput for us
    -- (dialogue / UI capture) and we need to look at a different hook.
    if pressed then
        Log.Write(string.format("Combat Input: mouse down button=%s gateActive=%s",
            tostring(button), tostring(State:IsCombatActive())))
    end

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
        if event.CanPreventAction then
            pcall(function() event:PreventAction() end)
        end
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
        if event.CanPreventAction then
            pcall(function() event:PreventAction() end)
        end
    end
end

-- KeyInput: tostring(event.Key) is an SDL scancode name. The digit row
-- comes through as NUM_1..NUM_0 (verified by Spike 1 — NOT the "Key1"
-- the IDE helpers suggest). event.Event is "KeyDown"/"KeyUp".
local KEY_TO_SLOT = {
    NUM_1 = 1, NUM_2 = 2, NUM_3 = 3, NUM_4 = 4, NUM_5 = 5,
    NUM_6 = 6, NUM_7 = 7, NUM_8 = 8, NUM_9 = 9, NUM_0 = 10,
}
local HOTBAR_TOGGLE_KEY = "H"

local function onKey(event)
    local key   = tostring(event.Key or "")
    local evt   = tostring(event.Event or "")
    recordEvent("Key[" .. evt .. "]", key, evt == "KeyDown")

    -- H toggles the hotbar window regardless of gate.
    if key == HOTBAR_TOGGLE_KEY and evt == "KeyDown" then
        requireLazy()
        Hotbar.ToggleWindow()
        return
    end

    if not State:IsCombatActive() then return end

    local slot = KEY_TO_SLOT[key]
    if slot and evt == "KeyDown" then
        Log.Write(string.format("Combat Input: hotbar key %s -> slot %d", key, slot))
        requireLazy()
        Hotbar.PressSlot(slot)
        if event.CanPreventAction then
            pcall(function() event:PreventAction() end)
        end
    end
end

function M.Register()
    Ext.Events.MouseButtonInput:Subscribe(function(e) pcall(onMouse, e) end)
    Ext.Events.KeyInput:Subscribe(function(e) pcall(onKey, e) end)
    Log.Write("Combat Input: registered (LMB/RMB/1-0 + H hotbar)")
end

return M
