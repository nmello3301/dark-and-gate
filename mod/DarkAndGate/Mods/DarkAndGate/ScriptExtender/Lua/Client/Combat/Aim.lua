-- SPDX-License-Identifier: GPL-3.0-or-later
-- Aim ray helpers (spike 2 verified path).
--
-- Reads the active camera's InvViewMatrix to get eye + forward (world
-- space) and returns a crosshair hit result.
--   { eye={x,y,z}, forward={x,y,z}, hit = { pos=..., target=... }? }
--
-- Rays start 0.4 m in front of the camera to clear near scenery. Target
-- resolution: if the ray hits a Character inside maxDist, we return its UUID.

local M = {}

local COLLIDES_WITH_WORLD    = { "Terrain", "Scenery", "Item", "Door" }
local COLLIDES_WITH_ANYTHING = { "Terrain", "Scenery", "Item", "Door", "Character" }
local IGNORED = {}

-- The local player's UUID, so rays that start inside or next to our own
-- body (first-person eye) never report ourselves as the target.
local function selfUuid()
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    if not ok or not ents or not ents[1] then return nil end
    local okU, u = pcall(function() return ents[1].Uuid.EntityUuid end)
    if okU then return u end
    return nil
end
M.SelfUuid = selfUuid

local function hitUuid(hit)
    local okU, u = pcall(function()
        return hit.HitEntity and hit.HitEntity.Uuid and hit.HitEntity.Uuid.EntityUuid
    end)
    if okU then return u end
    return nil
end

-- RaycastClosest from `from` along unit `dir` for `len` metres. If the
-- closest hit is our own character, restart just past it (max 4 times).
-- Returns distance-from-`from`, uuid (or nil), or nil when nothing is hit.
local function rayIgnoringSelf(from, dir, len, flags, me)
    local travelled = 0
    for _ = 1, 4 do
        local f = { from[1] + dir[1] * travelled, from[2] + dir[2] * travelled, from[3] + dir[3] * travelled }
        local t = { from[1] + dir[1] * len, from[2] + dir[2] * len, from[3] + dir[3] * len }
        if travelled >= len then return nil end
        local okR, hit = pcall(function()
            return Ext.Level.RaycastClosest(f, t, "Static", flags, IGNORED, 1)
        end)
        if not okR or not hit then return nil end
        local d = tonumber(hit.Distance) or (len - travelled)
        local u = hitUuid(hit)
        if u and me and u == me then
            travelled = travelled + d + 0.05
        else
            return travelled + d, u
        end
    end
    return nil
end

local function activeCameraController()
    local cams = Ext.Entity.GetAllEntitiesWithComponent("Camera") or {}
    local fallback
    for _, eh in ipairs(cams) do
        local okE, ent = pcall(Ext.Entity.Get, eh)
        if not okE or not ent then ent = eh end
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
M.ActiveCameraController = activeCameraController

local function readInvView()
    local ctl = activeCameraController()
    if not ctl then return nil end
    local _, inner = pcall(function() return ctl.Camera end)
    if not inner then return nil end
    local _, m = pcall(function() return inner.InvViewMatrix end)
    if not m then return nil end
    local function el(i)
        local ok, v = pcall(function() return m[i] end)
        return (ok and tonumber(v)) or 0
    end
    local eye = { el(13), el(14), el(15) }
    local fwd = { -el(9), -el(10), -el(11) }
    local L = math.sqrt(fwd[1] ^ 2 + fwd[2] ^ 2 + fwd[3] ^ 2)
    if L < 1e-4 then return nil end
    fwd[1], fwd[2], fwd[3] = fwd[1] / L, fwd[2] / L, fwd[3] / L
    return eye, fwd
end
M.ReadInvView = readInvView

-- Fire one ray from the camera. Returns a result table or nil if no hit.
--   maxDist   straight-line reach.
--   includeChars  if false, hits characters are skipped (walls only).
function M.CrosshairRay(maxDist, includeChars)
    maxDist = maxDist or 60.0
    local eye, fwd = readInvView()
    if not eye then return nil end
    local nudge = 0.4
    local from = { eye[1] + fwd[1] * nudge, eye[2] + fwd[2] * nudge, eye[3] + fwd[3] * nudge }
    local flags = includeChars and COLLIDES_WITH_ANYTHING or COLLIDES_WITH_WORLD
    -- hit.Distance is reliable; hit.Position bugged per DECISIONS 2026-10-08.
    local dist, uuid = rayIgnoringSelf(from, fwd, maxDist - nudge, flags, selfUuid())
    if not dist then
        return { eye = eye, forward = fwd }
    end
    local pos = {
        from[1] + fwd[1] * dist,
        from[2] + fwd[2] * dist,
        from[3] + fwd[3] * dist,
    }
    return { eye = eye, forward = fwd, hit = { pos = pos, target = uuid, distance = dist } }
end

-- Build a fan of forward directions around the camera forward, spread
-- horizontally (yaw) and tilted vertically (pitch). Returns a list of
-- unit vectors. yawDeg = total arc, splitRays = odd number of rays
-- (centre + even distribution).
function M.FanDirections(eye, forward, yawDeg, pitchDeg, rays)
    rays = rays or 7
    yawDeg = yawDeg or 90
    pitchDeg = pitchDeg or 0
    local step = (rays > 1) and (yawDeg / (rays - 1)) or 0
    -- World up = (0,1,0). Right = cross(forward, up). Up' = cross(right, forward).
    local upY = { 0, 1, 0 }
    local function cross(a, b)
        return {
            a[2] * b[3] - a[3] * b[2],
            a[3] * b[1] - a[1] * b[3],
            a[1] * b[2] - a[2] * b[1],
        }
    end
    local function norm(v)
        local L = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
        if L < 1e-6 then return { 0, 0, 1 } end
        return { v[1] / L, v[2] / L, v[3] / L }
    end
    local right = norm(cross(forward, upY))
    local up    = norm(cross(right, forward))
    -- Apply a single pitch offset to the forward.
    local pr = math.rad(pitchDeg)
    local cp, sp = math.cos(pr), math.sin(pr)
    local fx = forward[1] * cp + up[1] * sp
    local fy = forward[2] * cp + up[2] * sp
    local fz = forward[3] * cp + up[3] * sp
    local pitched = norm({ fx, fy, fz })
    -- Fan rays left-to-right in yaw.
    local out = {}
    for i = 1, rays do
        local y = -yawDeg / 2 + step * (i - 1)
        local yr = math.rad(y)
        local cy, sy = math.cos(yr), math.sin(yr)
        local dx = pitched[1] * cy + right[1] * sy
        local dy = pitched[2] * cy + right[2] * sy
        local dz = pitched[3] * cy + right[3] * sy
        table.insert(out, norm({ dx, dy, dz }))
    end
    return out, right, up
end

-- Sweep a fan of rays from eye + forward*nudge for reach_m, return the
-- nearest character hit as { targetUuid, pos, distance }. Picks the ray
-- with the smallest distance (which is the "closest surface hit").
function M.FanClosestCharacter(eye, forward, reach, yawDeg, pitchDeg, rays, nudge)
    nudge = nudge or 0.3
    local dirs = M.FanDirections(eye, forward, yawDeg, pitchDeg, rays)
    local best
    local me = selfUuid()
    for _, d in ipairs(dirs) do
        local from = { eye[1] + d[1] * nudge, eye[2] + d[2] * nudge, eye[3] + d[3] * nudge }
        local dist, u = rayIgnoringSelf(from, d, reach - nudge, COLLIDES_WITH_ANYTHING, me)
        if dist then
            if u then
                if not best or dist < best.distance then
                    best = {
                        targetUuid = u,
                        distance   = dist,
                        pos        = {
                            from[1] + d[1] * dist,
                            from[2] + d[2] * dist,
                            from[3] + d[3] * dist,
                        },
                    }
                end
            end
        end
    end
    return best
end

-- Classify a hit height relative to the target's feet. Approximate with
-- Osi since bone data isn't live Lua.
function M.ClassifyZone(targetUuid, hitY)
    local okY, feet = pcall(function() return Osi.GetY(targetUuid) end)
    if not okY then return "torso" end
    local dy = (hitY or 0) - (tonumber(feet) or 0)
    if dy > 1.6 then return "head" end
    if dy < 0.9 then return "limbs" end
    return "torso"
end

return M
