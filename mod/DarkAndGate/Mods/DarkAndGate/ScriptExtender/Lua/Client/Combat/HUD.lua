-- SPDX-License-Identifier: GPL-3.0-or-later
-- Minimal HUD: mana bar + crosshair. ImGui — M4 replaces with native.
--
-- Visible when POV + gameplay active. Hidden otherwise so dialogue /
-- cutscenes stay clean.

local Log   = Ext.Require("Shared/Log.lua")
local State = Ext.Require("Client/Combat/State.lua")

local M = {}

local manaUpdateHooked = false

local function render()
    if not State.povOn then return end
    if not Ext.IMGUI then return end
    local okWin, _ = pcall(function()
        local w = Ext.IMGUI.NewWindow("DAG HUD",
            Ext.Enums and Ext.Enums.GuiWindowFlags
                and (Ext.Enums.GuiWindowFlags.NoDecoration + Ext.Enums.GuiWindowFlags.NoInputs)
                or nil)
        if not w then return end
        local pct = (State.mana.max > 0) and (State.mana.current / State.mana.max) or 0
        pct = math.max(0, math.min(1, pct))
        w:AddText(string.format("Mana: %d / %d  +%.1f/s",
            math.floor(State.mana.current), math.floor(State.mana.max), State.mana.regen))
        -- A rendered bar with ProgressBar if available.
        pcall(function() w:AddProgressBar(pct, 180, 10) end)
        if State.currentSwing then
            w:AddText(string.format("Swing %d/%d (%s)",
                State.currentSwing.swingIndex, 3, State.currentSwing.def.name))
        end
    end)
    if not okWin then
        -- Fallback: nothing visible, but keep going.
    end
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
            Log.Write(string.format("HUD: hit %s zone=%s dmg=%d", tostring(parsed.target), tostring(parsed.zone), tonumber(parsed.damage) or 0))
        end)
    end
    Ext.Events.Tick:Subscribe(function() pcall(render) end)
    Log.Write("HUD: registered (mana bar + swing marker)")
end

return M
