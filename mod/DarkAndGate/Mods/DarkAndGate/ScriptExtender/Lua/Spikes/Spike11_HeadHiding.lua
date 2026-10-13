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

-- Per character (2026-10-13: when the player went down, BG3 handed control to
-- Lae'zel, and the restore, which looked at whoever had control, left the
-- player's head hidden in the downed camera). savedPasses: uuid ->
-- { ["<sub-visual template>#<object desc index>"] = the original RenderPasses
-- value as a string we can round-trip back, _any = the first one saved }.
-- hiddenOn: the characters whose head is hidden now.
local savedPasses = {}
local hiddenOn = {}

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

local function isZero(v)
    local s = fmt(v)
    return s == fmt(0) or s == "RenderPass()" or s == "nil"
end

local function uuidOf(ent)
    local ok, u = pcall(function() return ent.Uuid.EntityUuid end)
    return (ok and u) and tostring(u) or tostring(ent)
end

-- A character's head / hair / beard / headwear sub-visuals:
-- fn(visual, label for the log, key for savedPasses).
local function eachHeadVisual(ent, fn)
    local root = nil
    pcall(function() root = ent.Visual.Visual end)
    if root and root.Attachments then
        for i, att in ipairs(root.Attachments) do
            local name = templateName(att.Visual)
            if matchesHidePattern(name) then
                fn(att.Visual, string.format("root.att[%d] %s", i, tostring(name)), tostring(name))
            end
        end
    end
    -- An equipped helmet brings its own sub-visuals.
    pcall(function()
        for slot, data in pairs(ent.ClientEquipmentVisuals.Equipment) do
            if tostring(slot) == "Helmet" then
                for i, subEh in ipairs(data.SubVisuals or {}) do
                    local subEnt = Ext.Entity.Get(subEh)
                    local sv = subEnt and subEnt.Visual or nil
                    if sv and sv.Visual then
                        fn(sv.Visual, string.format("helmet.sub[%d]", i), "helmet:" .. tostring(templateName(sv.Visual) or i))
                    end
                end
            end
        end
    end)
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

local function applyToVisual(vis, label, key, hide, saved)
    if vis == nil then return end
    local okO, descs = pcall(function() return vis.ObjectDescs end)
    if not okO or descs == nil then
        Log.Write(string.format("Spike11: %s no ObjectDescs", label))
        return
    end
    for i, od in ipairs(descs) do
        local okP, pl = pcall(function() return od.Renderable.PropertyList end)
        if okP and pl then
            local _, before = pcall(function() return pl.RenderPasses end)
            local k = key .. "#" .. tostring(i)
            if hide then
                -- Only a visible value is worth keeping (an already hidden mesh reads 0).
                if saved[k] == nil and not isZero(before) then
                    saved[k] = fmt(before)
                    saved._any = saved._any or saved[k]
                end
                -- 0 = participate in no passes = invisible.
                local okW, err = pcall(function() pl.RenderPasses = 0 end)
                local _, after = pcall(function() return pl.RenderPasses end)
                Log.Write(string.format("Spike11: %s od[%d] passes %s -> %s %s",
                    label, i, fmt(before), fmt(after),
                    okW and "" or ("ERR=" .. tostring(err))))
            elseif isZero(before) then
                -- A mesh hidden before its own value was saved (a re-hide after a
                -- visual swap) gets another head mesh's value rather than none.
                local orig = saved[k] or saved._any
                if orig ~= nil then
                    local okW, err = pcall(function() pl.RenderPasses = orig end)
                    local _, after = pcall(function() return pl.RenderPasses end)
                    Log.Write(string.format("Spike11: %s od[%d] passes %s -> %s (restore=%s%s) %s",
                        label, i, fmt(before), fmt(after), tostring(orig), saved[k] and "" or ", another mesh's value",
                        okW and "" or ("ERR=" .. tostring(err))))
                else
                    Log.Write(string.format("Spike11: %s od[%d] passes %s: nothing saved to restore", label, i, fmt(before)))
                end
            end
        end
    end
end

-- Head back on one character (it need not be the one you control now).
local function showOn(u, why)
    hiddenOn[u] = nil
    local ok, ent = pcall(Ext.Entity.Get, u)
    if not ok or ent == nil then
        Log.Write(string.format("Spike11: head of %s not shown: no entity (%s)", tostring(u), why))
        return
    end
    local saved = savedPasses[u] or {}
    eachHeadVisual(ent, function(vis, label, key) applyToVisual(vis, label, key, false, saved) end)
    Log.Write(string.format("Spike11: head shown on %s (%s)", tostring(u), why))
end

local function apply(hide)
    local tag = hide and "dag11_hide" or "dag11_show"
    Log.Write("Spike11: " .. tag .. " v6 start")
    if hide then
        local eh = findLocalChar(); if not eh then return end
        local ent = Ext.Entity.Get(eh); if ent == nil then return end
        local u = uuidOf(ent)
        for other in pairs(hiddenOn) do
            if other ~= u then showOn(other, "you control another character") end
        end
        savedPasses[u] = savedPasses[u] or {}
        local saved = savedPasses[u]
        eachHeadVisual(ent, function(vis, label, key) applyToVisual(vis, label, key, true, saved) end)
        hiddenOn[u] = true
    else
        -- Every character hidden before, whoever has control now.
        local any = false
        for u in pairs(hiddenOn) do
            any = true
            showOn(u, "the camera is out of your eyes")
        end
        if not any then Log.Write("Spike11: dag11_show: no hidden head") end
    end
    Log.Write("Spike11: " .. tag .. " v6 end")
end

-- Exposed so NativeBridge.tickHeadHide can drive it from the hide_head
-- config flag. apply() is otherwise private.
M.Apply = apply
function M.Hidden() return hiddenOn end

-- 2026-10-09: the hide is a one-shot write, but the engine writes
-- RenderPasses back now and then (the face showed for a moment while
-- playing; most likely BG3's near-camera fade). Enforce() re-zeroes any
-- hidden renderable that came back, without logging each one; NativeBridge
-- calls it every 100 ms while the head is hidden. Re-hides are counted and
-- logged (first 5, then every 50th) so we can see how often it happens.
local reHides = 0
local function enforceVisual(vis, label, key, saved)
    local okO, descs = pcall(function() return vis.ObjectDescs end)
    if not okO or descs == nil then return end
    for i, od in ipairs(descs) do
        local okP, pl = pcall(function() return od.Renderable.PropertyList end)
        if okP and pl then
            local okR, cur = pcall(function() return pl.RenderPasses end)
            if okR and cur ~= nil and not isZero(cur) then
                local k = key .. "#" .. tostring(i)
                if saved[k] == nil then saved[k] = fmt(cur); saved._any = saved._any or saved[k] end
                pcall(function() pl.RenderPasses = 0 end)
                reHides = reHides + 1
                if reHides <= 5 or reHides % 50 == 0 then
                    Log.Write(string.format("Spike11: re-hid %s od[%d] (was %s) total=%d",
                        label, i, fmt(cur), reHides))
                end
            end
        end
    end
end

-- why: nil for the periodic check, or the event that asked for it.
function M.Enforce(why)
    -- Quiet lookup: findLocalChar() logs, and this runs every second.
    local okE, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    local eh = okE and ents and ents[1] or nil
    if not eh then return end
    local ent = Ext.Entity.Get(eh); if ent == nil then return end
    local u = uuidOf(ent)
    -- Control moved to another character (a portrait, BG3 itself when one goes
    -- down): the old one gets its head back, the new one's is hidden.
    for other in pairs(hiddenOn) do
        if other ~= u then showOn(other, "control moved to " .. u) end
    end
    hiddenOn[u] = true
    savedPasses[u] = savedPasses[u] or {}
    local saved = savedPasses[u]
    local before = reHides
    -- A newly equipped helmet brings its own sub-visuals (eachHeadVisual).
    eachHeadVisual(ent, function(vis, label, key) enforceVisual(vis, label, key, saved) end)
    if why then
        Log.Write(string.format("Spike11: re-hide on %s event -> %d renderable(s) re-hidden", why, reHides - before))
    end
end

-- Equipment / visual changes on the player ask for an immediate Enforce
-- (picked up by NativeBridge's tick). 2026-10-09: subscribing with
-- Ext.Entity.OnChange / OnCreateDeferred at load crashed the game before
-- the main menu (native, not catchable), so instead a cheap signature of
-- the player's visual (root attachments + helmet sub-visuals) is compared
-- every 200 ms while the head is hidden; a change = gear / visual swap.
local eventRequest = nil
local lastSig, lastSigAt = nil, 0
local function visualSignature()
    local okE, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    local eh = okE and ents and ents[1] or nil
    if not eh then return nil end
    local ent = Ext.Entity.Get(eh)
    if ent == nil then return nil end
    local parts = { tostring(eh) }
    pcall(function()
        local root = ent.Visual.Visual
        parts[#parts + 1] = tostring(root)
        for _, att in ipairs(root.Attachments) do parts[#parts + 1] = tostring(att.Visual) end
    end)
    pcall(function()
        for slot, data in pairs(ent.ClientEquipmentVisuals.Equipment) do
            if tostring(slot) == "Helmet" then
                for _, sub in ipairs(data.SubVisuals or {}) do parts[#parts + 1] = tostring(sub) end
            end
        end
    end)
    return table.concat(parts, "|")
end
function M.PollVisualChange()
    local now = Ext.Utils.MonotonicTime()
    if now - lastSigAt < 200 then return end
    lastSigAt = now
    local sig = visualSignature()
    if sig and lastSig and sig ~= lastSig then eventRequest = "visual/equipment change" end
    lastSig = sig
end
function M.TakeEventRequest()
    local r = eventRequest
    eventRequest = nil
    return r
end

function M.Register()
    Ext.RegisterConsoleCommand("dag11_dump", function() dump() end)
    Ext.RegisterConsoleCommand("dag11_hide", function() apply(true) end)
    Ext.RegisterConsoleCommand("dag11_show", function() apply(false) end)
    Log.Write("Spike11: registered dag11_dump / dag11_hide / dag11_show (v5 RenderPasses)")
end

return M
