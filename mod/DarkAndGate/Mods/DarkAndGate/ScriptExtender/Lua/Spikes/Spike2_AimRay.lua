-- Spike 2: can we raycast from the camera through the screen centre?
--
-- Two parts:
--   1. The RaycastClosest API itself works (dag2_ray — arbitrary ray).
--   2. We can get the camera's world position + forward (dag2_dump reads
--      InvViewMatrix; dag2_aim fires a ray along forward).

local Log = Ext.Require("Shared/Log.lua")

local M = {}

local function fmtVec(v)
    if v == nil then return "nil" end
    local ok = pcall(function() return v.x end)
    if ok then
        return string.format("(%.3f,%.3f,%.3f)", v.x or 0, v.y or 0, v.z or 0)
    end
    local okT, s = pcall(function() return tostring(v) end)
    return okT and s or "unprintable"
end

-- SE binds glm::mat4 as a flat 16-float Lua table (column-major). Printed as
-- four 4-vec columns for readability.
local function fmtMat4(m)
    if m == nil then return "nil" end
    local vals = {}
    for i = 1, 16 do
        local okV, v = pcall(function() return m[i] end)
        if not okV or v == nil then return "unprintable" end
        table.insert(vals, string.format("%.3f", v))
    end
    return string.format("c0=[%s,%s,%s,%s] c1=[%s,%s,%s,%s] c2=[%s,%s,%s,%s] c3=[%s,%s,%s,%s]",
        vals[1], vals[2], vals[3], vals[4],
        vals[5], vals[6], vals[7], vals[8],
        vals[9], vals[10], vals[11], vals[12],
        vals[13], vals[14], vals[15], vals[16])
end

local function activeCameraController()
    local cams = Ext.Entity.GetAllEntitiesWithComponent("Camera") or {}
    local fallback
    for _, eh in ipairs(cams) do
        local ent = Ext.Entity.Get(eh)
        local _, cam = pcall(function() return ent.Camera end)
        if cam then
            local _, ctl = pcall(function() return cam.Controller end)
            if ctl then
                if not fallback then fallback = ctl end
                local _, active = pcall(function() return cam.Active end)
                if active then return ctl end
            end
        end
    end
    return fallback
end

local function dumpOne()
    Log.Write("Spike2: dag2_dump start")
    local cams = Ext.Entity.GetAllEntitiesWithComponent("Camera") or {}
    Log.Write(string.format("Spike2: %d camera entities", #cams))

    for i, eh in ipairs(cams) do
        local ent = Ext.Entity.Get(eh)
        local _, cam = pcall(function() return ent.Camera end)
        if cam then
            local _, active = pcall(function() return cam.Active end)
            local _, ctl = pcall(function() return cam.Controller end)
            if ctl then
                local _, fov = pcall(function() return ctl.FOV end)
                local _, ar  = pcall(function() return ctl.AspectRatio end)
                local _, look= pcall(function() return ctl.LookAt end)
                Log.Write(string.format("Spike2:   cam[%d] active=%s fov=%s ar=%s look=%s",
                    i, tostring(active), tostring(fov), tostring(ar), fmtVec(look)))
                local _, inner = pcall(function() return ctl.Camera end)
                if inner then
                    local _, view    = pcall(function() return inner.ViewMatrix end)
                    local _, invView = pcall(function() return inner.InvViewMatrix end)
                    Log.Write(string.format("Spike2:   cam[%d] ViewMatrix:    %s", i, fmtMat4(view)))
                    Log.Write(string.format("Spike2:   cam[%d] InvViewMatrix: %s", i, fmtMat4(invView)))
                end
            end
        end
    end

    Log.Write("Spike2: dag2_dump end")
end

-- RaycastClosest(from, to, physicsType, collidesWith, ignoredGroups, maxHits)
-- physicsType: "Static" | "Dynamic"
-- Flags from PhysicsGroupFlags; "Terrain"/"Scenery"/"Character"/"Item" cover
-- the obvious targetable things.
local DEFAULT_COLLIDES_WITH = { "Terrain", "Scenery", "Character", "Item" }
local DEFAULT_IGNORED       = {}

local function tryRaycast(label, from, to)
    local ok, hit = pcall(function()
        return Ext.Level.RaycastClosest(
            from, to, "Static", DEFAULT_COLLIDES_WITH, DEFAULT_IGNORED, 1)
    end)
    if not ok then
        Log.Write(string.format("Spike2: %s err=%s", label, tostring(hit)))
        return
    end
    if hit == nil then
        Log.Write(string.format("Spike2: %s nil hit (from=%s to=%s)",
            label, fmtVec(from), fmtVec(to)))
        return
    end
    local _, pos = pcall(function() return hit.Position end)
    local _, nor = pcall(function() return hit.Normal end)
    local _, dist= pcall(function() return hit.Distance end)
    local _, grp = pcall(function() return hit.PhysicsGroup end)
    local _, shape = pcall(function() return hit.Shape end)

    -- Position and Normal read back as (0,0,0) through SE's binding (same bug
    -- as other vec3 fields), but Distance is populated. If it's a fraction of
    -- the ray length, we can rebuild the world hit position from from/to.
    local function el(v, i)
        if type(v) == "table" then return v[i] or 0 end
        local ok, r = pcall(function() return v[i] end)
        return (ok and r) or 0
    end
    local dx, dy, dz = el(to,1) - el(from,1), el(to,2) - el(from,2), el(to,3) - el(from,3)
    local hpx = el(from,1) + dx * (tonumber(dist) or 0)
    local hpy = el(from,2) + dy * (tonumber(dist) or 0)
    local hpz = el(from,3) + dz * (tonumber(dist) or 0)

    Log.Write(string.format("Spike2: %s dist=%s group=%s shape=%s rawPos=%s reconstructedPos=(%.3f,%.3f,%.3f)",
        label, tostring(dist), tostring(grp), tostring(shape),
        fmtVec(pos), hpx, hpy, hpz))
end

local function rayDown()
    -- Arbitrary known-ish location in the Grove area: (0,100,0) → (0,-100,0).
    -- Just a smoke test that the API works with sensible from/to; if we hit
    -- something, raycast is callable.
    tryRaycast("ray-down", { 0, 100, 0 }, { 0, -100, 0 })
end

local function rayFromCameraForward()
    local ctl = activeCameraController()
    if ctl == nil then
        Log.Write("Spike2: no active camera controller")
        return
    end
    local _, inner = pcall(function() return ctl.Camera end)
    if inner == nil then
        Log.Write("Spike2: no inner rf::Camera on controller")
        return
    end
    local _, invView = pcall(function() return inner.InvViewMatrix end)
    if invView == nil then
        Log.Write("Spike2: InvViewMatrix unreadable")
        return
    end

    -- InvViewMatrix is a flat 16-float column-major table. Column c (0..3)
    -- starts at Lua index 4*c + 1 (so col3 = positions at 13..16, col2 = back
    -- axis at 9..12). Camera forward = -col2.
    local function el(i)
        local ok, v = pcall(function() return invView[i] end)
        if not ok then return 0 end
        return tonumber(v) or 0
    end
    local px = el(13); local py = el(14); local pz = el(15)
    local fx = -el(9); local fy = -el(10); local fz = -el(11)

    local len = math.sqrt(fx*fx + fy*fy + fz*fz)
    if len < 0.001 then
        Log.Write(string.format("Spike2: forward vector too short (len=%.4f) — matrix probably not populated", len))
        return
    end
    fx = fx / len; fy = fy / len; fz = fz / len

    -- Nudge the start 0.5 m forward of the camera so we don't hit the near
    -- scenery around the camera position.
    local nudge = 0.5
    local sx = px + fx*nudge; local sy = py + fy*nudge; local sz = pz + fz*nudge
    local reach = 100.0
    local to = { sx + fx*reach, sy + fy*reach, sz + fz*reach }
    Log.Write(string.format("Spike2: aim from=(%.3f,%.3f,%.3f) fwd=(%.3f,%.3f,%.3f)",
        sx, sy, sz, fx, fy, fz))
    tryRaycast("aim", { sx, sy, sz }, to)
end

-- Spike 10 piggyback: raycast throughput benchmark.
local function benchRays(cmd, countArg)
    local n = tonumber(countArg) or 100
    local from = { 0, 100, 0 }
    local to   = { 0, -100, 0 }
    local startMs = tonumber(Ext.Timer.MonotonicTime())
    for _ = 1, n do
        Ext.Level.RaycastClosest(from, to, "Static", DEFAULT_COLLIDES_WITH, DEFAULT_IGNORED, 1)
    end
    local endMs = tonumber(Ext.Timer.MonotonicTime())
    local totalMs = endMs - startMs
    local perRayUs = (totalMs * 1000.0) / n
    Log.Write(string.format("Spike2/10: bench n=%d total=%.3fms per-ray=%.1fus",
        n, totalMs, perRayUs))
end

function M.Register()
    Ext.RegisterConsoleCommand("dag2_dump",  function() dumpOne() end)
    Ext.RegisterConsoleCommand("dag2_ray",   function() rayDown() end)
    Ext.RegisterConsoleCommand("dag2_aim",   function() rayFromCameraForward() end)
    Ext.RegisterConsoleCommand("dag2_bench", benchRays)
    Log.Write("Spike2: registered dag2_dump / dag2_ray / dag2_aim / dag2_bench")
end

return M
