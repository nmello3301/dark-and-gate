-- SPDX-License-Identifier: GPL-3.0-or-later
-- Minimal first-person HUD (ImGui; M4 replaces it with native UI):
--   * a crosshair "+" at screen centre (what LMB and spells aim at)
--   * ONE small status line under it: mana, armed spell, what you aim at
--
-- fix3: everything is throttled (labels 10 Hz, aim readout 5 Hz) and the
-- heavy work (character scan) lives in Aim.lua's incremental tick, so no
-- handler gets near SE's "Dispatching event Tick ... took N ms" warning.
--
-- Commands:
--   !dag_hud on|off              show / hide the status line
--   !dag_crosshair on|off        show / hide the crosshair
--   !dag_crosshair <x> <y>       nudge the crosshair (pixels from centre)

local Log    = Ext.Require("Shared/Log.lua")
local Net    = Ext.Require("Shared/Net.lua")
local State  = Ext.Require("Client/Combat/State.lua")
local Aim    = Ext.Require("Client/Combat/Aim.lua")
local spells = Ext.Require("data/spells.lua")

local M = {}

local ui, uiFailed = nil, false
local crossOn, hudOn = true, true
local crossNudge = { 0, 0 }
local shown = { cross = nil, panel = nil }
local lastLabelAt, lastAimAt = -1e9, -1e9
local lastVW, lastVH = -1, -1
local aimText = ""
local lastLabel = nil

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local function trySet(obj, key, value) pcall(function() obj[key] = value end) end

local function viewport()
    local ok, v = pcall(Ext.IMGUI.GetViewportSize)
    if ok and v then
        local w, h = tonumber(v[1] or v.x), tonumber(v[2] or v.y)
        if w and h and w > 0 then return w, h end
    end
    return 1920, 1080
end

local FLAGS = { "NoTitleBar", "NoResize", "NoMove", "NoInputs", "NoScrollbar",
                "NoSavedSettings", "AlwaysAutoResize", "NoFocusOnAppearing", "NoNav" }

local function bareWindow(title, bg)
    local w = Ext.IMGUI.NewWindow(title)
    trySet(w, "Closeable", false)
    pcall(function() w.Flags = FLAGS end)
    for _, f in ipairs(FLAGS) do trySet(w, f, true) end
    pcall(function() w:SetColor("WindowBg", bg) end)
    pcall(function() w:SetColor("Border", { 0, 0, 0, 0 }) end)
    pcall(function() w:SetStyle("WindowBorderSize", 0) end)
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
        t.cross = bareWindow("##DAG_Crosshair", { 0, 0, 0, 0 })
        pcall(function() t.cross:SetStyle("WindowPadding", 2, 0) end)
        t.crossText = t.cross:AddText("+")
        pcall(function() t.crossText:SetColor("Text", { 1, 1, 1, 0.9 }) end)
        t.panel = bareWindow("##DAG_HUD", { 0, 0, 0, 0.25 })
        pcall(function() t.panel:SetStyle("WindowPadding", 6, 2) end)
        t.line = t.panel:AddText("")
        pcall(function() t.line:SetColor("Text", { 1, 1, 1, 0.85 }) end)
        ui = t
    end)
    if not ok then
        uiFailed = true
        Log.Write("HUD: ImGui build failed: " .. tostring(err))
    end
    return ui
end

local function setShown(which, on)
    if shown[which] == on then return end
    shown[which] = on
    trySet(ui[which], "Open", on)
    trySet(ui[which], "Visible", on)
end

local function updateAim(armedId, def)
    local t = now()
    if t - lastAimAt < 200 then return end
    lastAimAt = t
    if armedId and def and (def.kind == "point" or def.kind == "teleport") then
        local _, d, via = Aim.GroundPoint(def.range_m or 30)
        aimText = d and string.format("ground %.1f m%s", d, via == "ray" and "" or (" (" .. via .. ")")) or "no ground"
    else
        local tg = Aim.TargetAtCrosshair(armedId and (def and def.range_m or 36) or 3.0)
        if tg then
            aimText = string.format("target %.1f m", tg.distance or 0)
        elseif armedId then
            local _, d = Aim.GroundPoint(def and def.range_m or 36)
            aimText = d and string.format("ground %.1f m", d) or ""
        else
            aimText = ""
        end
    end
end

local function render()
    local t = now()
    if t - lastLabelAt < 100 then return end
    lastLabelAt = t

    local want = State.povOn and State.IsCombatActive()
    if not want then
        if ui then setShown("cross", false); setShown("panel", false) end
        return
    end
    local u = build()
    if not u then return end
    setShown("cross", crossOn)
    setShown("panel", hudOn)

    local vw, vh = viewport()
    if vw ~= lastVW or vh ~= lastVH then
        lastVW, lastVH = vw, vh
        pcall(function() u.cross:SetPos({ vw / 2 - 6 + crossNudge[1], vh / 2 - 9 + crossNudge[2] }) end)
        pcall(function() u.panel:SetPos({ vw / 2 - 110, vh / 2 + 40 }) end)
    end
    if not hudOn then return end

    local armedId = State.armedSpell
    local def = armedId and spells.spells[armedId] or nil
    updateAim(armedId, def)
    local parts = { string.format("Mana %d/%d", math.floor(State.mana.current), math.floor(State.mana.max)) }
    if armedId then parts[#parts + 1] = "ARMED " .. ((def and def.label) or armedId) end
    if aimText ~= "" then parts[#parts + 1] = aimText end
    local label = table.concat(parts, "  |  ")
    if label ~= lastLabel then
        lastLabel = label
        trySet(u.line, "Label", label)
    end
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
        elseif tonumber(a) then crossNudge = { tonumber(a) or 0, tonumber(b) or 0 }; lastVW = -1 end
        Log.Write(string.format("HUD: crosshair %s nudge=(%d,%d)", crossOn and "on" or "off",
            crossNudge[1], crossNudge[2]))
    end)
    Ext.RegisterConsoleCommand("dag_hud", function(_, a)
        hudOn = not (a == "off" or a == "0")
        Log.Write("HUD: status line " .. (hudOn and "on" or "off"))
    end)
    local lastErr = -1e9
    Ext.Events.Tick:Subscribe(function()
        local ok, err = pcall(render)
        if not ok and now() - lastErr > 5000 then
            lastErr = now()
            Log.Write("HUD: render error: " .. tostring(err))
        end
    end)
    Log.Write("HUD: registered fix3 (crosshair + one status line, throttled)")
end

return M
