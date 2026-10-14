-- SPDX-License-Identifier: GPL-3.0-or-later
-- Animation state snapshot (read-only): what on the player can make the same
-- blueprint node pick a different clip (docs/spikes/spell-anims.md).
--
--   !dag_anim_state <label> [delay_s]
--     after delay_s (default 0) writes DarkAndGate/anim-state-<label>.txt:
--       - every animation blueprint variable: index, name, type, value
--       - DynamicAnimationTags, AnimationWaterfall, AnimationSet,
--         TemplateAnimationSetOverride, Unsheath, WeaponSet
--       - the player's component names
--     and DarkAndGate/anim-state-<label>-components.json (all components).
-- Take one while vanilla targeting runs and one while ours runs, then diff.

local Log = Ext.Require("Shared/Log.lua")
local Me = Ext.Require("Client/Me.lua")   -- the local player's character (multiplayer)

local M = {}

local pending = nil   -- { label, at }

local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function player()
    local ok, ents = pcall(Me.All)
    return ok and ents and ents[1] or nil
end

local JSON_OPTS = { Beautify = false, StringifyInternalTypes = true, IterateUserdata = true, AvoidRecursion = true, MaxDepth = 6 }

local function str(v)
    if type(v) ~= "userdata" and type(v) ~= "table" then return tostring(v) end
    local ok, s = pcall(Ext.Json.Stringify, v, JSON_OPTS)
    return ok and s or tostring(v)
end

local function snapshot(label)
    local me = player()
    if not me then Log.Write("AnimState: no player"); return end
    local lines = { "# anim state '" .. label .. "' at " .. nowMs() }
    -- Blueprint variables, named from the blueprint's templates.
    local nVars = 0
    pcall(function()
        local bp = me.AnimationBlueprint
        local inst = bp.Instance
        local names = {}
        pcall(function()
            for _, t in ipairs(inst.Parent.Variables) do names[tonumber(t.Index)] = t.Name end
        end)
        for i, v in ipairs(inst.Variables) do
            local okT, ty = pcall(function() return tostring(v.Type) end)
            local okV, val = pcall(function() return v.Value end)
            lines[#lines + 1] = string.format("var|%d|%s|%s|%s", i - 1, names[i - 1] or "?", okT and ty or "?",
                okV and str(val) or "?")
            nVars = nVars + 1
        end
    end)
    for _, c in ipairs({ "DynamicAnimationTags", "AnimationWaterfall", "AnimationSet", "TemplateAnimationSetOverride",
                         "Unsheath", "WeaponSet" }) do
        local ok, comp = pcall(function() return me[c] end)
        lines[#lines + 1] = "comp|" .. c .. "|" .. ((ok and comp) and str(comp) or "nil")
    end
    pcall(function()
        local names = me:GetAllComponentNames()
        table.sort(names)
        for _, n in ipairs(names) do lines[#lines + 1] = "has|" .. n end
    end)
    local path = "DarkAndGate/anim-state-" .. label .. ".txt"
    pcall(Ext.IO.SaveFile, path, table.concat(lines, "\n") .. "\n")
    local okD = pcall(function()
        Ext.IO.SaveFile("DarkAndGate/anim-state-" .. label .. "-components.json", Ext.DumpExport(me:GetAllComponents()))
    end)
    Log.Write(string.format("AnimState: '%s' saved (%d blueprint variables, components dump %s) -> %s", label, nVars,
        okD and "ok" or "FAILED", path))
end

function M.Register()
    Ext.RegisterConsoleCommand("dag_anim_state", function(_, label, delay)
        label = label or "snap"
        local d = tonumber(delay) or 0
        pending = { label = label, at = nowMs() + d * 1000 }
        Log.Write(string.format("AnimState: '%s' in %.1fs", label, d))
    end)
    Ext.Events.Tick:Subscribe(function()
        if pending and nowMs() >= pending.at then
            local p = pending
            pending = nil
            local ok, err = pcall(snapshot, p.label)
            if not ok then Log.Write("AnimState: ERROR " .. tostring(err)) end
        end
    end)
end

return M
