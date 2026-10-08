-- SPDX-License-Identifier: GPL-3.0-or-later
-- Client input capture for combat.
--
-- While POV + real-time combat active:
--   LMB  -> swing (and PreventAction so BG3 doesn't select).
--   RMB  -> block (hold; stub this pass — raises a flag only).
--   1..0 -> hotbar slot. PreventAction so BG3 doesn't pick/select.
--
-- Outside POV / combat the handlers early-exit and the event propagates
-- vanilla.

local Log   = Ext.Require("Shared/Log.lua")
local State = Ext.Require("Client/Combat/State.lua")

local M = {}

local Swing, Hotbar  -- Resolved lazily to avoid Ext.Require cycles.

local function requireLazy()
    if not Swing  then Swing  = Ext.Require("Client/Combat/Swing.lua") end
    if not Hotbar then Hotbar = Ext.Require("Client/Combat/Hotbar.lua") end
end

-- SE's MouseButtonInput event: event.Button ("LeftButton" / "RightButton" /
-- "MiddleButton"), event.Pressed (true on down, false on up).
local function onMouse(event)
    if not State:IsCombatActive() then return end
    local b = tostring(event.Button or "")
    if b == "Left1" or b == "LeftButton" then
        requireLazy()
        if event.Pressed then
            Swing.OnLMB()
        end
        pcall(function() event:PreventAction() end)
    elseif b == "Right1" or b == "RightButton" then
        State.blocking = event.Pressed and true or false
        if event.Pressed then
            Log.Write("Combat: block ON (stub, no DR applied yet)")
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
    if not State:IsCombatActive() then
        -- H toggles the hotbar window even outside combat.
        if tostring(event.Key or "") == "H" and event.Event == "KeyDown" then
            requireLazy()
            Hotbar.ToggleWindow()
        end
        return
    end
    local key = tostring(event.Key or "")
    if key == "H" and event.Event == "KeyDown" then
        requireLazy()
        Hotbar.ToggleWindow()
        return
    end
    local slot = KEY_TO_SLOT[key]
    if slot and event.Event == "KeyDown" then
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
