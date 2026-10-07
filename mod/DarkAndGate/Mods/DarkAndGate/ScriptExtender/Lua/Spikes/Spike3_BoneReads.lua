-- SPDX-License-Identifier: GPL-3.0-or-later
-- Spike 3: can we read live bone transforms every tick?
--
-- Walks the local character's visual tree to the weapon sub-visual, dumps:
--   * every AnimatableObject's OverrideTransformCount + the first few mat3x4
--     entries (looking for non-zero translation columns)
--   * SkeletonSlots[*].Skeleton.BoneGroups keys
--   * SkeletonSlots[*].Skeleton.Sockets[*].Name + .Transform.Translate
--
-- One console command: !dag3_dump. No tick subscription on purpose -- the
-- goal is just to see if the fields are populated, not to measure cost yet.

local Log = Ext.Require("Shared/Log.lua")

local M = {}

local function fmt(x)
    if x == nil then return "nil" end
    local ok, s = pcall(function() return tostring(x) end)
    return ok and s or "unprintable"
end

local function fmtVec(v)
    if v == nil then return "nil" end
    local ok = pcall(function() return v.x end)
    if ok then
        return string.format("(%.2f,%.2f,%.2f)", v.x or 0, v.y or 0, v.z or 0)
    end
    return fmt(v)
end

-- A glm::mat3x4 column-major translation is the last column: m[3][0..2] in
-- C++. SE's Lua binding usually exposes mat3x4 as a nested-indexed userdata.
-- Try several readback shapes.
local function fmtMat3x4Translate(m)
    if m == nil then return "nil" end
    -- Try m[1][4] / m[2][4] / m[3][4] (1-indexed, last column).
    local ok1, x = pcall(function() return m[1][4] end)
    local ok2, y = pcall(function() return m[2][4] end)
    local ok3, z = pcall(function() return m[3][4] end)
    if ok1 and ok2 and ok3 and x and y and z then
        return string.format("(%.2f,%.2f,%.2f)", x, y, z)
    end
    -- Fallback: just tostring the thing so we see its shape.
    return fmt(m)
end

local function findLocalChar()
    local ents = Ext.Entity.GetAllEntitiesWithComponent("ClientControl") or {}
    if #ents == 0 then return nil end
    return ents[1]
end

local function templateName(vis)
    if vis == nil or vis.VisualResource == nil then return nil end
    local ok, t = pcall(function() return vis.VisualResource.Template end)
    if ok and t then return tostring(t) end
    return nil
end

local function dumpVisual(label, vis)
    if vis == nil then
        Log.Write(label .. ": visual=nil")
        return
    end

    local tn = templateName(vis)
    Log.Write(string.format("%s: template=%s", label, tostring(tn)))

    -- ObjectDescs -> renderables (one per LOD/mesh); each AnimatableObject has
    -- OverrideTransforms.
    local okO, descs = pcall(function() return vis.ObjectDescs end)
    if okO and descs then
        for i, od in ipairs(descs) do
            local _, r = pcall(function() return od.Renderable end)
            if r then
                local _, count = pcall(function() return r.OverrideTransformCount end)
                local _, m     = pcall(function() return r.OverrideTransforms_Mat3x4 end)
                Log.Write(string.format("%s   od[%d] OverrideTransformCount=%s first=%s",
                    label, i, fmt(count), fmtMat3x4Translate(m)))
                -- Try a few more indices via m[idx] in case SE binds as array.
                for idx = 1, 4 do
                    local okE, entry = pcall(function() return m[idx] end)
                    if okE and entry ~= nil then
                        Log.Write(string.format("%s     xform[%d] = %s",
                            label, idx, fmtMat3x4Translate(entry)))
                    end
                end
            end
        end
    end

    -- SkeletonSlots -> Skeleton -> BoneGroups + Sockets.
    local okS, slots = pcall(function() return vis.SkeletonSlots end)
    if okS and slots then
        for si, slot in ipairs(slots) do
            local _, sk = pcall(function() return slot.Skeleton end)
            if sk then
                local _, bg = pcall(function() return sk.BoneGroups end)
                if bg then
                    local keys = {}
                    for k, _ in pairs(bg) do table.insert(keys, tostring(k)) end
                    Log.Write(string.format("%s   skel[%d] BoneGroups=%d: %s",
                        label, si, #keys, table.concat(keys, ",")))
                end
                local _, sockets = pcall(function() return sk.Sockets end)
                if sockets then
                    local count = 0
                    for _ in pairs(sockets) do count = count + 1 end
                    Log.Write(string.format("%s   skel[%d] Sockets count=%d", label, si, count))
                    local shown = 0
                    for _, soc in ipairs(sockets) do
                        local _, name = pcall(function() return soc.Name end)
                        local _, tr   = pcall(function() return soc.Transform end)
                        local tval = tr and fmtVec(tr.Translate) or "nil"
                        Log.Write(string.format("%s     socket name=%s translate=%s",
                            label, tostring(name), tval))
                        shown = shown + 1
                        if shown >= 8 then break end
                    end
                end
            end
        end
    end
end

local function dump()
    Log.Write("Spike3: dag3_dump start")
    local eh = findLocalChar()
    if not eh then
        Log.Write("Spike3: no ClientControl entity")
        return
    end
    local ent = Ext.Entity.Get(eh)
    local vc = ent and ent.Visual
    local root = vc and vc.Visual
    if not root then
        Log.Write("Spike3: no root visual")
        return
    end

    -- Root first; then every attachment (we specifically want the weapon one).
    dumpVisual("Spike3: ROOT", root)
    if root.Attachments then
        for i, att in ipairs(root.Attachments) do
            local sub = att.Visual
            local name = templateName(sub)
            dumpVisual(string.format("Spike3: att[%d] %s", i, tostring(name)), sub)
        end
    end
    Log.Write("Spike3: dag3_dump end")
end

function M.Register()
    Ext.RegisterConsoleCommand("dag3_dump", function() dump() end)
    Log.Write("Spike3: registered dag3_dump")
end

return M
