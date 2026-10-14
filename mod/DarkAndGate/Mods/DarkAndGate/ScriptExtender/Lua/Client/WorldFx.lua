-- SPDX-License-Identifier: GPL-3.0-or-later
-- Local ground decals and markers from BG3's own UI effects (the ones its
-- targeting draws, docs/spikes/lookat.md, research spell-indicators):
-- started through the client effect handler
-- (Ext.System.ClientEffectHandler:InitMultiEffect, the path SpellFx.lua
-- already uses), so only this player sees them.
--
-- Our MultiEffectInfos (Public/DarkAndGate/MultiEffectInfos/*.lsf, sources
-- in tools/mei/) wrap vanilla effect resources by GUID; no asset is copied:
--   ring     VFX_UI_Circle_Range_01        the area ring (Fireball, Grease...)
--   target   VFX_UI_Circle_AttackTarget_01 a picked spell target
--   hover    VFX_UI_Circle_Highlight_01    what F / LMB would act on
-- If our ring didn't load, the vanilla 4 m ring (AI_HELPER_AVOIDAREA_RADIUS4)
-- stands in, scaled by radius / 4.
--
--   WorldFx.Ring(key, pos, radius)        ring at pos; re-made when it moves > move_m
--   WorldFx.OnEntity(key, kind, entity)   "target" / "hover" under a character or item
--   WorldFx.Clear(key)   WorldFx.ClearPrefix(prefix)   WorldFx.Count()

local Log = Ext.Require("Shared/Log.lua")
local Me = Ext.Require("Client/Me.lua")   -- the local player's character (multiplayer)

local M = {}

local MEI = {
    ring   = "6894e8ab-538b-4947-aaf9-ab6274127b6f",
    target = "41bafc48-533c-4e0f-bd16-5e819f26c659",
    hover  = "b922bca1-2c99-4bb1-9ee1-70ee05b9e8f4",
}
local VANILLA_RING_4M = "69dba763-775a-4d55-a074-7bd097d3d6f4"
local HAS_ENTITY, HAS_POSITION = 1, 2
local MOVE_M = 0.3

local live = {}       -- key -> { h, pos, r, kind, ent }
local loaded = {}     -- kind -> bool (checked once)

local function player()
    local ok, ents = pcall(Me.All)
    return ok and ents and ents[1] or nil
end

local function have(kind)
    if loaded[kind] == nil then
        local ok, r = pcall(function() return Ext.StaticData.Get(MEI[kind], "MultiEffectInfo") end)
        loaded[kind] = ok and r ~= nil
        Log.Write(string.format("WorldFx: our %s effect (%s) %s", kind, MEI[kind],
            loaded[kind] and "is loaded" or ("is NOT loaded (" .. tostring(ok and "not found" or r) .. ")"
            .. (kind == "ring" and ", using the vanilla 4 m ring" or ", markers off"))))
    end
    return loaded[kind]
end

local function destroy(e)
    if e and e.h then pcall(function() Ext.System.ClientEffectHandler:DestroyMultiEffect(e.h) end) end
end

local function spawn(def, source, target, scale)
    local me = player()
    if not me then return nil end
    local ok, h = pcall(function()
        return Ext.System.ClientEffectHandler:InitMultiEffect({
            EventProviderEntity = me,
            Player = me,
            SourceEffect = source,
            TargetEffect = target,
            MultiEffectDefinition = def,
            FXScale = scale or 1.0,
        })
    end)
    if ok and h then return h end
    if not M.spawnErr then M.spawnErr = true; Log.Write("WorldFx: InitMultiEffect failed: " .. tostring(h)) end
    return nil
end

function M.Ring(key, pos, radius)
    if not pos then return M.Clear(key) end
    radius = math.max(0.2, tonumber(radius) or 1)
    local e = live[key]
    if e and e.pos then
        local dx, dy, dz = pos[1] - e.pos[1], pos[2] - e.pos[2], pos[3] - e.pos[3]
        if dx * dx + dy * dy + dz * dz < MOVE_M * MOVE_M and math.abs((e.r or 0) - radius) < 0.05 then return true end
    end
    destroy(e)
    local def, scale = MEI.ring, 2 * radius
    if not have("ring") then def, scale = VANILLA_RING_4M, radius / 4 end
    local p = { pos[1], pos[2] + 0.05, pos[3] }
    local h = spawn(def, { Position = p, Flags = HAS_POSITION }, { Position = p, Flags = HAS_POSITION }, scale)
    live[key] = h and { h = h, pos = pos, r = radius, kind = "ring" } or nil
    return h ~= nil
end

function M.OnEntity(key, kind, ent)
    if not ent then return M.Clear(key) end
    -- A fresh entity userdata each call need not compare equal: compare handles.
    local id = tostring(ent)
    local e = live[key]
    if e and e.entId == id and e.kind == kind then return true end
    destroy(e)
    live[key] = nil
    if not have(kind) then return false end
    local h = spawn(MEI[kind], { Entity = ent, Flags = HAS_ENTITY }, { Entity = ent, Flags = HAS_ENTITY }, 1.0)
    if h then live[key] = { h = h, entId = id, kind = kind } end
    return h ~= nil
end

function M.Clear(key)
    local e = live[key]
    if e then destroy(e); live[key] = nil end
end

function M.ClearPrefix(prefix)
    for k, e in pairs(live) do
        if k:sub(1, #prefix) == prefix then destroy(e); live[k] = nil end
    end
end

function M.Count()
    local n = 0
    for _ in pairs(live) do n = n + 1 end
    return n
end

return M
