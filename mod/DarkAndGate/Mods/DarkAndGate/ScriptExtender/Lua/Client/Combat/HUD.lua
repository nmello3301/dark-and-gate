-- SPDX-License-Identifier: GPL-3.0-or-later
-- Minimal HUD: mana bar + ARMED spell indicator + Fireball ground preview.
-- ImGui-based (M4 replaces with native UI).
--
-- Visible while POV on. Hidden otherwise so dialogue / cutscenes stay clean.
--
-- Arm-then-cast indicator (fix 4): while State.armedSpell is set, the mana
-- bar background and the "Mana:" line are tinted and we print a bold
-- "ARMED: <spell>" line above the bar. For "point"/"teleport" spells
-- (Fireball, Misty Step) we also print the live crosshair-ground hit so
-- the user can tell where the cast will land before pressing LMB.

local Log    = Ext.Require("Shared/Log.lua")
local State  = Ext.Require("Client/Combat/State.lua")
local Aim    = Ext.Require("Client/Combat/Aim.lua")
local spells = Ext.Require("data/spells.lua")

local M = {}

local manaUpdateHooked = false

local function armedDef()
    local id = State.armedSpell
    if not id then return nil end
    return id, spells.spells[id]
end

local function render()
    if not State.povOn then return end
    if not Ext.IMGUI then return end
    local okWin, _ = pcall(function()
        local w = Ext.IMGUI.NewWindow("DAG HUD",
            Ext.Enums and Ext.Enums.GuiWindowFlags
                and (Ext.Enums.GuiWindowFlags.NoDecoration + Ext.Enums.GuiWindowFlags.NoInputs)
                or nil)
        if not w then return end

        local armedId, armedSpell = armedDef()
        if armedId then
            w:AddText(string.format("ARMED: %s (LMB cast / RMB cancel / press key again to cancel)",
                armedSpell and armedSpell.label or armedId))
        end

        local pct = (State.mana.max > 0) and (State.mana.current / State.mana.max) or 0
        pct = math.max(0, math.min(1, pct))
        local tint = armedId and "  [spell armed]" or ""
        w:AddText(string.format("Mana: %d / %d  +%.1f/s%s",
            math.floor(State.mana.current), math.floor(State.mana.max),
            State.mana.regen, tint))
        pcall(function() w:AddProgressBar(pct, 180, 10) end)

        if armedId and armedSpell and (armedSpell.kind == "point" or armedSpell.kind == "teleport") then
            -- Fireball / Misty Step aim readout — ground marker light-mode.
            -- Full decal is M4; for M1b we surface the crosshair ground hit.
            local aim = Aim.CrosshairRay(60.0, false)
            if aim and aim.hit then
                w:AddText(string.format("AIM: %s at (%.2f, %.2f, %.2f)  [distance %.1f m]",
                    armedSpell.label or "",
                    aim.hit.pos[1], aim.hit.pos[2], aim.hit.pos[3],
                    aim.hit.distance or 0))
            else
                w:AddText("AIM: " .. (armedSpell.label or "") .. " (no ground hit — look at terrain)")
            end
        elseif armedId and armedSpell and armedSpell.kind == "target" then
            local aim = Aim.CrosshairRay(60.0, true)
            if aim and aim.hit and aim.hit.target then
                w:AddText(string.format("AIM: target %s  [%.1f m]",
                    aim.hit.target, aim.hit.distance or 0))
            else
                w:AddText("AIM: NO TARGET (LMB will abort)")
            end
        end

        if State.currentSwing then
            w:AddText(string.format("Swing %d/%d (%s)",
                State.currentSwing.swingIndex, 3, State.currentSwing.def.name))
        end
    end)
end

function M.Register()
    local Net = Ext.Require("Shared/Net.lua")
    if not manaUpdateHooked then
        manaUpdateHooked = true
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
    end
    Ext.Events.Tick:Subscribe(function() pcall(render) end)
    Log.Write("HUD: registered (mana bar + ARMED indicator + aim readout)")
end

return M
