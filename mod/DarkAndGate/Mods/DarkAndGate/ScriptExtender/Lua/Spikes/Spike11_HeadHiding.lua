-- SPDX-License-Identifier: GPL-3.0-or-later
-- Spike 11: head / hair / helmet hiding on the local client only. v5.
--
-- Prior attempts:
--   v2 cleared VisualFlags.ShowMesh. Write took but no visual change.
--   v3/v4 wrote Attachment.Offset. SE accepted the write but the readback
--     returned the old value -- Attachment is a value-type proxy, our writes
--     never reached the live array entry.
-- v5: every RenderableObject under the sub-visual has a RenderPropertyList
--   with a RenderPasses bitmask -- the actual per-frame "which passes am I in"
--   switch. Zero it and the renderer skips the mesh entirely. If this doesn't
--   work either, the mesh is likely not Lua-reachable and we fall back to the
--   arms-only view model.
--
-- Three SE console commands (invoke as !dag11_... from the C >> client prompt):
--   !dag11_dump  log attachments + their ObjectDescs + RenderPasses
--   !dag11_hide  zero RenderPasses on head/hair/beard renderables
--   !dag11_show  restore saved RenderPasses

local Log = Ext.Require("Shared/Log.lua")

local M = {}

local HIDE_PATTERNS = {
    "/HAIR_", "/Beard_", "_NKD_Head_", "_HED_", "_ARM_Helmet", "_CLT_.*_Hood",
}

local function matchesHidePattern(name)
    if name == nil then return false end
    local s = tostring(name)
    for _, pat in ipairs(HIDE_PATTERNS) do
        if string.find(s, pat) then return true end
    end
    return false
end

-- Keyed by sub-visual template name + object desc index. Each entry is the
-- original RenderPasses value as a string we can round-trip back.
local savedPasses = {}

local function findLocalChar()
    local ents = Ext.Entity.GetAllEntitiesWithComponent("ClientControl") or {}
    if #ents == 0 then
        Log.Write("Spike11: no ClientControl entities.")
        return nil
    end
    return ents[1]
end

local function templateName(vis)
    if vis == nil or vis.VisualResource == nil then return nil end
    local okTpl, tpl = pcall(function() return vis.VisualResource.Template end)
    if okTpl and tpl then return tostring(tpl) end
    return nil
end

local function fmt(x)
    if x == nil then return "nil" end
    local ok, s = pcall(function() return tostring(x) end)
    return ok and s or "unprintable"
end

local function dumpVisual(prefix, vis)
    if vis == nil then
        Log.Write(prefix .. "visual=nil")
        return
    end
    local _, flags = pcall(function() return vis.VisualFlags end)
    local _, cull  = pcall(function() return vis.CullFlags end)
    Log.Write(string.format("%svisual flags=%s cull=%s template=%s",
        prefix, fmt(flags), fmt(cull), tostring(templateName(vis))))

    -- Dump ObjectDescs: that's where the renderables live.
    local okO, descs = pcall(function() return vis.ObjectDescs end)
    if okO and descs then
        for i, od in ipairs(descs) do
            local okR, r = pcall(function() return od.Renderable end)
            local _, od_flags = pcall(function() return od.Flags end)
            local passes = "nil"
            if okR and r then
                local okP, p = pcall(function() return r.PropertyList.RenderPasses end)
                if okP then passes = fmt(p) end
            end
            Log.Write(string.format("%s  od[%d] flags=%s passes=%s",
                prefix, i, fmt(od_flags), passes))
        end
    end

    local okA, atts = pcall(function() return vis.Attachments end)
    if okA and atts then
        for i, att in ipairs(atts) do
            Log.Write(string.format("%s  att[%d] sub=%s",
                prefix, i, tostring(templateName(att.Visual))))
        end
    end
end

local function dump()
    Log.Write("Spike11: dag11_dump v5 start")
    local eh = findLocalChar(); if not eh then return end
    local ent = Ext.Entity.Get(eh); if ent == nil then return end
    local vc = ent.Visual
    if vc then dumpVisual("Spike11: ROOT ", vc.Visual) end

    -- Walk each attachment's sub-visual to see its renderables + passes.
    if vc and vc.Visual and vc.Visual.Attachments then
        for i, att in ipairs(vc.Visual.Attachments) do
            local name = templateName(att.Visual)
            if matchesHidePattern(name) then
                dumpVisual(string.format("Spike11: HIDE-TARGET att[%d] ", i), att.Visual)
            end
        end
    end
    Log.Write("Spike11: dag11_dump v5 end")
end

local function applyToVisual(vis, label, hide)
    if vis == nil then return end
    local okO, descs = pcall(function() return vis.ObjectDescs end)
    if not okO or descs == nil then
        Log.Write(string.format("Spike11: %s no ObjectDescs", label))
        return
    end
    for i, od in ipairs(descs) do
        local okR, r = pcall(function() return od.Renderable end)
        if okR and r then
            local okP, pl = pcall(function() return r.PropertyList end)
            if okP and pl then
                local _, before = pcall(function() return pl.RenderPasses end)
                local key = label .. "#" .. tostring(i)
                if hide then
                    if savedPasses[key] == nil then
                        savedPasses[key] = fmt(before)
                    end
                    -- 0 = participate in no passes = invisible.
                    local okW, err = pcall(function() pl.RenderPasses = 0 end)
                    local _, after = pcall(function() return pl.RenderPasses end)
                    Log.Write(string.format("Spike11: %s od[%d] passes %s -> %s %s",
                        label, i, fmt(before), fmt(after),
                        okW and "" or ("ERR=" .. tostring(err))))
                else
                    local orig = savedPasses[key]
                    local okW, err = pcall(function() pl.RenderPasses = orig end)
                    local _, after = pcall(function() return pl.RenderPasses end)
                    Log.Write(string.format("Spike11: %s od[%d] passes %s -> %s (restore=%s) %s",
                        label, i, fmt(before), fmt(after), tostring(orig),
                        okW and "" or ("ERR=" .. tostring(err))))
                end
            end
        end
    end
end

local function apply(hide)
    local tag = hide and "dag11_hide" or "dag11_show"
    Log.Write("Spike11: " .. tag .. " v5 start")
    local eh = findLocalChar(); if not eh then return end
    local ent = Ext.Entity.Get(eh); if ent == nil then return end

    local vc = ent.Visual
    local root = vc and vc.Visual or nil
    if root and root.Attachments then
        for i, att in ipairs(root.Attachments) do
            local name = templateName(att.Visual)
            if matchesHidePattern(name) then
                applyToVisual(att.Visual,
                    string.format("root.att[%d] %s", i, tostring(name)), hide)
            end
        end
    end

    local eq = ent.ClientEquipmentVisuals
    if eq and eq.Equipment then
        for slot, data in pairs(eq.Equipment) do
            if tostring(slot) == "Helmet" then
                for i, subEh in ipairs(data.SubVisuals or {}) do
                    local subEnt = Ext.Entity.Get(subEh)
                    local sv = subEnt and subEnt.Visual or nil
                    if sv then
                        applyToVisual(sv.Visual, string.format("helmet.sub[%d]", i), hide)
                    end
                end
            end
        end
    end

    Log.Write("Spike11: " .. tag .. " v5 end")
end

function M.Register()
    Ext.RegisterConsoleCommand("dag11_dump", function() dump() end)
    Ext.RegisterConsoleCommand("dag11_hide", function() apply(true) end)
    Ext.RegisterConsoleCommand("dag11_show", function() apply(false) end)
    Log.Write("Spike11: registered dag11_dump / dag11_hide / dag11_show (v5 RenderPasses)")
end

return M
