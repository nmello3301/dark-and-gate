-- SPDX-License-Identifier: GPL-3.0-or-later
-- BG3's turn notices ("Your turn", an enemy's or ally's turn, initiative,
-- turn-based mode) mean nothing in real-time fights (developer 2026-10-15:
-- "suppress warnings like 'Your turn'").
--
-- BG3's Notification widget (Mods/MainUI/GUI/Pages/Notification.xaml)
-- shows one notification at a time from CurrentPlayer.UIData.Notification,
-- and its Type names the kind (CombatTurn, StartTurnFTB...). While real
-- time is on (State.realTime, !dag_rt), a notification whose type is in
-- data/hud.lua hide_notification_types is skipped through the widget's own
-- SkipNotificationCommand (the widget does the same with a turn notice
-- outside turn-based mode), and the widget stays invisible (Opacity 0)
-- until the type changes, in case the skip doesn't take. Other
-- notifications (level up, journal, new items...) are untouched.

local Log   = Ext.Require("Shared/Log.lua")
local State = Ext.Require("Client/Combat/State.lua")
local cfg   = Ext.Require("data/hud.lua")

local M = {}

local NAMES = { Notification = true, NotificationWidget = true }
local widget, widgetAt = nil, -1e9
local checkAt = 0
local hiddenOp = nil      -- the widget's Opacity before we hid it (nil = not hidden)
local lastType = nil
local skipLogged = {}

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function findWidget()
    local t = now()
    if widget and t - widgetAt < 5000 then return widget end
    widgetAt = t
    widget = nil
    pcall(function()
        for _, c in ipairs(Ext.UI.GetRoot():Find("ContentRoot").Children) do
            local okN, n = pcall(function() return tostring(c.Name) end)
            if okN and NAMES[n] then widget = c; return end
        end
    end)
    return widget
end

local function hiddenType(t)
    for _, h in ipairs(cfg.hide_notification_types or {}) do
        if h == t then return true end
    end
    return false
end

local function restore(w)
    if hiddenOp == nil then return end
    pcall(function() w.Opacity = hiddenOp end)
    hiddenOp = nil
end

local function tick()
    local t = now()
    if t - checkAt < 100 then return end
    checkAt = t
    local w = findWidget()
    if not w then return end
    local typ = nil
    pcall(function() typ = tostring(w.DataContext.CurrentPlayer.UIData.Notification.Type) end)
    local hide = typ ~= nil and State.realTime ~= false and hiddenType(typ)
    if hide then
        if typ ~= lastType then
            local ok, err = pcall(function() w.DataContext.SkipNotificationCommand:Execute() end)
            if not skipLogged[typ] then
                skipLogged[typ] = true
                Log.Write(string.format("TurnNotices: BG3's %s notice skipped (real-time fights)%s", typ,
                    ok and "" or (": skip command FAILED (" .. tostring(err) .. "), the notice is only made invisible")))
            end
        end
        if hiddenOp == nil then
            local okO, op = pcall(function() return w.Opacity end)
            hiddenOp = (okO and tonumber(op)) or 1
            pcall(function() w.Opacity = 0 end)
        end
    else
        restore(w)
    end
    lastType = typ
end

function M.Register()
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
end

return M
