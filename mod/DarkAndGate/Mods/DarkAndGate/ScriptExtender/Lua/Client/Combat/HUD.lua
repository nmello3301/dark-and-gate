-- SPDX-License-Identifier: GPL-3.0-or-later
-- Minimal first-person HUD (ImGui; M4 replaces it with native UI):
--   * a crosshair "+" at screen centre (what LMB and spells aim at)
--   * a status panel: hint line / ARMED spell, mana, what the crosshair is on
--
-- Visible only while POV is on. fix2: SE's ImGui is retained-mode, so the
-- windows and their text elements are created ONCE and only their labels
-- are updated per tick (the old code called NewWindow every tick).
--
-- Commands:
--   !dag_crosshair on|off        show / hide the crosshair
--   !dag_crosshair <x> <y>       nudge the crosshair (pixels from centre)

local Log    = Ext.Require("Shared/Log.lua")
local Net    = Ext.Require("Shared/Net.lua")
local State  = Ext.Require("Client/Combat/State.lua")
local Aim    = Ext.Require("Client/Combat/Aim.lua")
local spells = Ext.Require("data/spells.lua")

local M = {}

local ui = nil
local uiFailed = false
local crossOn = true
local crossNudge = { 0, 0 }
local lastAimAt = -1e9
local aimText = ""
local wasVisible = false

local function trySet(obj, key, value)
    pcall(function() obj[key] = value end)
end

local function viewport()
    local ok, v = pcall(function() return Ext.IMGUI.GetViewportSize() end)
    if ok and type(v) ~= "nil" then
        local w, h = tonumber(v[1] or v.x), tonumber(v[2] or v.y)
        if w and h and w > 0 then return w, h end
    end
    local okR, w, h = pcall(function()
        local r = Ext.UI.GetRoot()
        return r.ActualWidth, r.ActualHeight
    end)
    if okR and tonumber(w) and tonumber(w) > 0 then return tonumber(w), tonumber(h) end
    return 1920, 1080
end

local WINDOW_FLAGS = { "NoTitleBar", "NoResize", "NoMove", "NoInputs", "NoScrollbar",
                       "NoSavedSettings", "AlwaysAutoResize", "NoFocusOnAppearing", "NoNav" }

local function bareWindow(title)
    local w = Ext.IMGUI.NewWindow(title)
    trySet(w, "Closeable", false)
    -- Set flags both ways SE has exposed them; each attempt is isolated.
    pcall(function() w.Flags = WINDOW_FLAGS end)
    for _, f in ipairs(WINDOW_FLAGS) do trySet(w, f, true) end
    return w
end

local function build()
    if ui or uiFailed then return ui end
    if not (Ext.IMGUI and Ext.IMGUI.NewWindow) then
        uiFailed = true
        Log.Write("HUD: Ext.IMGUI not available -- no crosshair/HUD")
        return nil
    end
    local ok, err = pcall(function()
        local t = {}
        t.cross = bareWindow("##DAG_Crosshair")
        pcall(function() t.cross:SetColor("WindowBg", { 0, 0, 0, 0 }) end)
        pcall(function() t.cross:SetColor("Border", { 0, 0, 0, 0 }) end)
        pcall(function() t.cross:SetStyle("WindowBorderSize", 0) end)
        pcall(function() t.cross:SetStyle("WindowPadding", 2, 0) end)
        t.crossText = t.cross:AddText("+")
        pcall(function() t.crossText:SetColor("Text", { 1, 1, 1, 0.95 }) end)

        t.panel = bareWindow("##DAG_HUD")
        pcall(function() t.panel:SetColor("WindowBg", { 0, 0, 0, 0.35 }) end)
        t.armed = t.panel:AddText("")
        t.mana  = t.panel:AddText("")
        t.bar   = t.panel:AddProgressBar()
        pcall(function() t.bar:SetSize({ 180, 10 }) end)
        t.aim   = t.panel:AddText("")
        t.swing = t.panel:AddText("")
        ui = t
    end)
    if not ok then
        uiFailed = true
        Log.Write("HUD: ImGui build failed: " .. tostring(err))
    else
        Log.Write("HUD: ImGui crosshair + panel created")
    end
    return ui
end

local function show(on)
    if not ui then return end
    trySet(ui.panel, "Open", on)
    trySet(ui.panel, "Visible", on)
    trySet(ui.cross, "Open", on and crossOn)
    trySet(ui.cross, "Visible", on and crossOn)
end

local function updateAim(armedId, def)
    local now = tonumber(Ext.Timer.MonotonicTime()) or 0
    if now - lastAimAt < 150 then return end
    lastAimAt = now
    if armedId and def and (def.kind == "point" or def.kind == "teleport") then
        local aim = Aim.CrosshairRay(60.0, false)
        if aim and aim.hit then
            aimText = string.format("AIM: ground %.1f m", aim.hit.distance or 0)
        else
            aimText = "AIM: no ground hit -- look at terrain"
        end
    else
        local t = Aim.TargetAtCrosshair(armedId and 60.0 or 10.0)
        if t then
            aimText = string.format("AIM: target %.1f m (%s)", t.distance or 0, t.via)
        else
            aimText = armedId and "AIM: NO TARGET (LMB will abort)" or "AIM: -"
        end
    end
end

local lastRenderAt = -1e9
local lastCrossVW, lastCrossVH = -1, -1

local function render()
    -- Throttle to ~10 Hz. SE's console prints "Dispatching event Tick …
    -- took N ms" for every handler >3 ms; running the full retained-mode
    -- layout + Characters scan + ConeTarget every frame was spamming
    -- 5-11 ms lines so the SE console was unusable. 100 ms is well under
    -- any visible lag threshold for a HUD readout.
    local now = tonumber(Ext.Timer.MonotonicTime()) or 0
    if now - lastRenderAt < 100 then return end
    lastRenderAt = now

    local want = State.povOn and State.IsCombatActive()
    if not want then
        if wasVisible then show(false); wasVisible = false end
        return
    end
    local t = build()
    if not t then return end
    if not wasVisible then show(true); wasVisible = true end

    local vw, vh = viewport()
    -- SetPos re-triggers an ImGui layout even if the value hasn't changed;
    -- skip the call when the viewport is stable (every tick after the
    -- first in a given resolution).
    if vw ~= lastCrossVW or vh ~= lastCrossVH then
        lastCrossVW, lastCrossVH = vw, vh
        pcall(function() t.cross:SetPos({ vw / 2 - 6 + crossNudge[1], vh / 2 - 9 + crossNudge[2] }) end)
        pcall(function() t.panel:SetPos({ vw / 2 - 130, vh - 230 }) end)
    end

    local armedId = State.armedSpell
    local def = armedId and spells.spells[armedId] or nil
    trySet(t.armed, "Label", armedId
        and string.format("ARMED: %s  (LMB cast / RMB or same key cancel)", def and def.label or armedId)
        or "LMB swing | 1-0 arm spell | MMB cursor")
    local pct = (State.mana.max > 0) and (State.mana.current / State.mana.max) or 0
    pct = math.max(0, math.min(1, pct))
    trySet(t.mana, "Label", string.format("Mana %d / %d  +%.1f/s",
        math.floor(State.mana.current), math.floor(State.mana.max), State.mana.regen))
    trySet(t.bar, "Value", pct)
    updateAim(armedId, def)
    trySet(t.aim, "Label", aimText)
    local s = State.currentSwing
    trySet(t.swing, "Label", s and string.format("Swing %d/3 (%s)", s.swingIndex, s.def.name) or "")
end

function M.Register()
    Ext.RegisterNetListener(Net.Channels.ManaUpdate, function(_, payload)
        local ok, parsed = pcall(Ext.Json.Parse, payload)
        if not ok then return end
        State.mana.max     = tonumber(parsed.max)     or State.mana.max
        State.mana.current = tonumber(parsed.current) or State.mana.current
        State.mana.regen   = tonumber(parsed.regen)   or State.mana.regen
    end)
    Ext.RegisterNetListener(Net.Channels.HitResult, function(_, payload)
        local ok, parsed = pcall(Ext.Json.Parse, payload)
        if not ok then return end
        Log.Write(string.format("HUD: hit %s zone=%s dmg=%d",
            tostring(parsed.target), tostring(parsed.zone), tonumber(parsed.damage) or 0))
    end)
    Ext.RegisterConsoleCommand("dag_crosshair", function(_, a, b)
        if a == "off" or a == "0" then crossOn = false
        elseif a == "on" or a == "1" then crossOn = true
        elseif tonumber(a) then crossNudge = { tonumber(a) or 0, tonumber(b) or 0 } end
        if wasVisible then show(true) end
        Log.Write(string.format("HUD: crosshair %s nudge=(%d,%d)", crossOn and "on" or "off",
            crossNudge[1], crossNudge[2]))
    end)
    local lastErr = -1e9
    Ext.Events.Tick:Subscribe(function()
        local ok, err = pcall(render)
        if not ok then
            local now = tonumber(Ext.Timer.MonotonicTime()) or 0
            if now - lastErr > 5000 then lastErr = now; Log.Write("HUD: render error: " .. tostring(err)) end
        end
    end)
    Log.Write("HUD: registered fix2 (crosshair + mana + ARMED + aim readout)")
end

return M
