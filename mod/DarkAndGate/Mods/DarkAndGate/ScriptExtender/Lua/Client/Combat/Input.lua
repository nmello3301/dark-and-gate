-- SPDX-License-Identifier: GPL-3.0-or-later
-- Client input capture for combat.
--
-- Gate: POV on + no modal UI (see State.IsCombatActive). realTime and
-- inFight are deliberately NOT gated here -- the user wants LMB / RMB /
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
--
-- UI mode: when mouse-look is OFF (MMB toggled it off, cursor visible),
-- LMB / RMB pass straight through to the vanilla game so the normal UI,
-- looting, dialogue and context menus work. Number keys still arm.
--
-- fix1 (2026-10-08):
--   * Swing / Hotbar / Spells are required at load time. The old lazy
--     Ext.Require from inside the input handler threw (SE only allows
--     Require while the bootstrap is loading) and the pcall swallowed it,
--     so LMB and 1-0 were logged but did nothing.
--   * Handler errors are now logged ("Combat Input: ERROR ...") instead of
--     being swallowed silently.
--   * !dag_input_log on|off logs every raw mouse/key event (RMB diagnosis).

local Log    = Ext.Require("Shared/Log.lua")
local State  = Ext.Require("Client/Combat/State.lua")
local Swing  = Ext.Require("Client/Combat/Swing.lua")
local Hotbar = Ext.Require("Client/Combat/Hotbar.lua")
local Spells = Ext.Require("Client/Combat/Spells.lua")
local Jump   = Ext.Require("Client/Movement/Jump.lua")

local M = {}

local rawLog = false

local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function recordEvent(kind, button, pressed)
    State.lastInputEvent = string.format(
        "%s %s %s@%dms gateActive=%s",
        kind, tostring(button), pressed and "down" or "up",
        nowMs(), tostring(State.IsCombatActive()))
end

-- MouseButtonInput: event.Button is an SDL button index. Spike 1 verified
-- that tonumber(e.Button) returns 1=left, 2=middle, 3=right.
local function isLMB(button) return tonumber(button) == 1 end
local function isRMB(button) return tonumber(button) == 3 end

local function prevent(event)
    if event.CanPreventAction then
        pcall(function() event:PreventAction() end)
    end
end

local function onMouse(event)
    local button  = event.Button
    local pressed = event.Pressed and true or false
    recordEvent("Mouse", button, pressed)

    if rawLog then
        Log.Write(string.format("Combat Input RAW: mouse button=%s (num=%s) pressed=%s canPrevent=%s",
            tostring(button), tostring(tonumber(button)), tostring(pressed),
            tostring(event.CanPreventAction)))
    end

    if not State.IsCombatActive() then return end

    local lmb, rmb = isLMB(button), isRMB(button)
    if not lmb and not rmb then return end

    -- UI mode: cursor visible -> leave mouse buttons to the vanilla game.
    if not State.MouseLookOn() then
        if pressed then
            Log.Write(string.format("Combat Input: button=%s passed to vanilla UI (mouse-look off)",
                tostring(button)))
        end
        return
    end

    if pressed then
        Log.Write(string.format("Combat Input: %s down", lmb and "LMB" or "RMB"))
    end

    if lmb then
        if pressed then
            if State.armedSpell then
                local armed = State.armedSpell
                State.armedSpell = nil
                Log.Write("Combat: LMB casts armed spell " .. tostring(armed))
                Spells.Cast(armed)
            else
                Swing.OnLMB()
            end
        end
        prevent(event)
    else
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
        prevent(event)
    end
end

-- KeyInput: tostring(event.Key) is an SDL scancode name. The digit row
-- comes through as NUM_1..NUM_0 (verified by Spike 1 -- NOT the "Key1"
-- the IDE helpers suggest). event.Event is "KeyDown"/"KeyUp".
local KEY_TO_SLOT = {
    NUM_1 = 1, NUM_2 = 2, NUM_3 = 3, NUM_4 = 4, NUM_5 = 5,
    NUM_6 = 6, NUM_7 = 7, NUM_8 = 8, NUM_9 = 9, NUM_0 = 10,
}
local HOTBAR_TOGGLE_KEY = "H"

-- Space = jump (Client/Movement/Jump.lua). The scancode name is expected
-- to be "SPACE"; the first key whose name contains "space" is logged raw
-- so the real name is on record, and that name is used from then on.
local JUMP_KEY = "SPACE"
local jumpKeyLogged = false
local function isJumpKey(key)
    if key == JUMP_KEY then return true end
    if not jumpKeyLogged and key:lower():find("space", 1, true) then
        jumpKeyLogged = true
        Log.Write("Combat Input: jump key raw name = " .. key)
        JUMP_KEY = key
        return true
    end
    return false
end

local function onKey(event)
    local key   = tostring(event.Key or "")
    local evt   = tostring(event.Event or "")
    recordEvent("Key[" .. evt .. "]", key, evt == "KeyDown")

    if rawLog and evt == "KeyDown" then
        Log.Write(string.format("Combat Input RAW: key=%s event=%s repeat=%s",
            key, evt, tostring(event.Repeat)))
    end

    -- H toggles the hotbar window regardless of gate.
    if key == HOTBAR_TOGGLE_KEY and evt == "KeyDown" then
        Hotbar.ToggleWindow()
        return
    end

    if not State.IsCombatActive() then return end

    if isJumpKey(key) then
        if evt == "KeyDown" and not event.Repeat then Jump.OnSpace() end
        -- Block vanilla Space on both down and up.
        prevent(event)
        return
    end

    local slot = KEY_TO_SLOT[key]
    if slot then
        if evt == "KeyDown" and not event.Repeat then
            Log.Write(string.format("Combat Input: hotbar key %s -> slot %d", key, slot))
            Hotbar.PressSlot(slot)
        end
        -- Block the vanilla hotbar on both down and up.
        prevent(event)
    end
end

-- Log handler errors, at most one line per 2 s per handler, so a broken
-- path is visible in client.log instead of failing silently.
local lastErrAt = {}
local function guarded(name, fn)
    return function(e)
        local ok, err = pcall(fn, e)
        if not ok then
            local now = nowMs()
            if not lastErrAt[name] or now - lastErrAt[name] > 2000 then
                lastErrAt[name] = now
                Log.Write("Combat Input: ERROR in " .. name .. ": " .. tostring(err))
            end
        end
    end
end

function M.Register()
    Ext.Events.MouseButtonInput:Subscribe(guarded("mouse", onMouse))
    Ext.Events.KeyInput:Subscribe(guarded("key", onKey))
    Ext.RegisterConsoleCommand("dag_input_log", function(_, arg)
        rawLog = (arg == "on" or arg == "1")
        Log.Write("Combat Input: raw input log " .. (rawLog and "ON" or "OFF"))
    end)
    Log.Write("Combat Input: registered fix1 (LMB/RMB/1-0 + H hotbar + Space jump; MMB off = UI mode)")
end

return M
