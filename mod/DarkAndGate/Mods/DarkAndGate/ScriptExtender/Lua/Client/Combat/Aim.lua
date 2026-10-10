-- SPDX-License-Identifier: GPL-3.0-or-later
-- Aim helpers: camera eye/forward, ground point under the crosshair,
-- and character targeting.
--
-- fix3 (2026-10-08):
--   * Ext.Level.RaycastClosest's hit.Distance is a FRACTION (0..1) of the
--     ray length (spike 2), not metres. Old code used it as metres, so every
--     "ground hit" landed ~0.3 m in front of the eye -> Misty Step /
--     Fireball had nowhere to go.
--   * Ray hits can't be resolved to an entity from Lua (hit.HitEntity does
--     not exist), so character targeting is purely geometric: the closest
--     living character to the crosshair inside a cone, with a world-only
--     line-of-sight ray.
--   * The character list is refreshed INCREMENTALLY (a slice per tick, far
--     ones dropped) -- scanning all ~780 level characters in one tick took
--     ~5 ms and made SE spam "Dispatching event Tick ... took 5 ms".
--   * GroundPoint falls back to the plane at the player's feet when the
--     world ray misses, so a ground cast always has a point.

local Log = Ext.Require("Shared/Log.lua")
local Hitbox = Ext.Require("Shared/Hitbox.lua")

local M = {}

local WORLD = { "Terrain", "Scenery", "Item", "Door" }
local IGNORED = {}

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

-- ---------------------------------------------------------------------
-- Player
-- ---------------------------------------------------------------------
local selfCache = { at = -1e9, ent = nil, uuid = nil }
local function getUuid(e) return e.Uuid.EntityUuid end
local function getTranslate(e) return e.Transform.Transform.Translate end
local function getHp(e) return e.Health.Hp end

local function refreshSelf()
    local t = now()
    if t - selfCache.at < 1000 and selfCache.ent then return end
    selfCache.at = t
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    if ok and ents and ents[1] then
        selfCache.ent = ents[1]
        local okU, u = pcall(getUuid, ents[1])
        selfCache.uuid = okU and u or nil
    end
end

local function vec3(t)
    if not t then return nil end
    local x, y, z = t[1] or t.x, t[2] or t.y, t[3] or t.z
    if x and y and z then return { tonumber(x), tonumber(y), tonumber(z) } end
    return nil
end

function M.SelfUuid() refreshSelf(); return selfCache.uuid end

function M.SelfFeet()
    refreshSelf()
    if not selfCache.ent then return nil end
    local ok, t = pcall(getTranslate, selfCache.ent)
    return ok and vec3(t) or nil
end

-- ---------------------------------------------------------------------
-- Camera
-- ---------------------------------------------------------------------
local camCache = { at = -1e9, ctl = nil }
local function findController()
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

local function activeCameraController()
    local t = now()
    if camCache.ctl and t - camCache.at < 1000 then return camCache.ctl end
    camCache.at = t
    local ok, ctl = pcall(findController)
    camCache.ctl = ok and ctl or nil
    return camCache.ctl
end
M.ActiveCameraController = activeCameraController

-- fix4: which way the view matrix's 3rd column points. Spike 2 assumed
-- the GL convention (forward = -col3); in-game the crosshair aimed
-- straight BEHIND the player (swing fwd matched the DLL's pivot->eye
-- vector, i.e. backwards), so BG3's forward is +col3. The sign is still
-- re-checked every second against the DLL's own eye -> look-at vector
-- (native-pov-status.txt) and flips itself if it ever disagrees.
local fwdSign = 1

local function rawMatrix()
    local ctl = activeCameraController()
    if not ctl then return nil end
    local okI, inner = pcall(function() return ctl.Camera end)
    if not okI or not inner then camCache.ctl = nil; return nil end
    local okM, m = pcall(function() return inner.InvViewMatrix end)
    if not okM or not m then camCache.ctl = nil; return nil end
    local function el(i)
        local ok, v = pcall(function() return m[i] end)
        return (ok and tonumber(v)) or 0
    end
    local eye = { el(13), el(14), el(15) }
    local c3 = { el(9), el(10), el(11) }
    local L = math.sqrt(c3[1] ^ 2 + c3[2] ^ 2 + c3[3] ^ 2)
    if L < 1e-4 then camCache.ctl = nil; return nil end
    return eye, { c3[1] / L, c3[2] / L, c3[3] / L }
end

-- DLL status: eye and look-at point actually committed to the camera.
local STATUS_PATH = "DarkAndGate/native-pov-status.txt"
local dll = { at = -1e9, eye = nil, fwd = nil, t = nil }
local function readDll()
    local t = now()
    if t - dll.at < 250 then return dll.eye, dll.fwd end
    dll.at = t
    dll.eye, dll.fwd = nil, nil
    local ok, s = pcall(Ext.IO.LoadFile, STATUS_PATH)
    if not ok or not s then return nil end
    if not s:find("applied=1", 1, true) then return nil end
    local ex, ey, ez = s:match("eye=([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)")
    local px, py, pz = s:match(" P=([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)")
    if not (ex and px) then return nil end
    local e = { tonumber(ex), tonumber(ey), tonumber(ez) }
    local d = { tonumber(px) - e[1], tonumber(py) - e[2], tonumber(pz) - e[3] }
    local L = math.sqrt(d[1] ^ 2 + d[2] ^ 2 + d[3] ^ 2)
    if L < 1e-4 then return nil end
    dll.eye, dll.fwd = e, { d[1] / L, d[2] / L, d[3] / L }
    return dll.eye, dll.fwd
end

local flipVotes = 0
local lastCal = -1e9
local function calibrate()
    local t = now()
    if t - lastCal < 1000 then return end
    lastCal = t
    local _, c3 = rawMatrix()
    local _, dfwd = readDll()
    if not c3 or not dfwd then return end
    local s = c3[1] * dfwd[1] + c3[2] * dfwd[2] + c3[3] * dfwd[3]
    local want = (s > 0.8 and 1) or (s < -0.8 and -1) or nil
    if want and want ~= fwdSign then
        flipVotes = flipVotes + 1
        if flipVotes >= 2 then
            fwdSign = want
            flipVotes = 0
            Log.Write(string.format("Aim: forward sign recalibrated to %+d (dot=%.2f vs DLL view)", want, s))
        end
    else
        flipVotes = 0
    end
end

local function readInvView()
    local eye, c3 = rawMatrix()
    if eye then
        return eye, { c3[1] * fwdSign, c3[2] * fwdSign, c3[3] * fwdSign }
    end
    -- Camera entity briefly unreadable (e.g. right after a teleport):
    -- fall back to the DLL's last committed view.
    return readDll()
end
M.ReadInvView = readInvView

-- ---------------------------------------------------------------------
-- World ray
-- ---------------------------------------------------------------------
local lastRawDistance = nil
-- Distance in metres from `from` along unit `dir` to the first world hit
-- within `len`, or nil. hit.Distance is a 0..1 fraction (spike 2); a value
-- above 1 is taken as metres in case a future SE build changes it.
function M.WorldRay(from, dir, len)
    local to = { from[1] + dir[1] * len, from[2] + dir[2] * len, from[3] + dir[3] * len }
    local okR, hit = pcall(Ext.Level.RaycastClosest, from, to, "Static", WORLD, IGNORED, 1)
    if not okR or not hit then return nil end
    local okD, raw = pcall(function() return hit.Distance end)
    raw = okD and tonumber(raw) or nil
    if not raw then return nil end
    lastRawDistance = raw
    if raw <= 1.0001 then return raw * len end
    return raw
end
function M.LastRawDistance() return lastRawDistance end

-- Ground point under the crosshair: world ray first, then the plane at
-- the player's feet, then a point straight ahead at `maxDist`.
-- Returns pos, distance, via ("ray" | "plane" | "ahead") or nil.
function M.GroundPoint(maxDist)
    maxDist = maxDist or 30.0
    local eye, fwd = readInvView()
    if not eye then return nil end
    local nudge = 0.4
    local from = { eye[1] + fwd[1] * nudge, eye[2] + fwd[2] * nudge, eye[3] + fwd[3] * nudge }
    local d = M.WorldRay(from, fwd, maxDist)
    if d then
        return { from[1] + fwd[1] * d, from[2] + fwd[2] * d, from[3] + fwd[3] * d }, d + nudge, "ray"
    end
    local feet = M.SelfFeet()
    local groundY = feet and feet[2] or (eye[2] - 1.7)
    if fwd[2] < -0.02 then
        local t = (groundY - eye[2]) / fwd[2]
        if t > 0 and t <= maxDist then
            return { eye[1] + fwd[1] * t, groundY, eye[3] + fwd[3] * t }, t, "plane"
        end
    end
    local fl = math.sqrt(fwd[1] * fwd[1] + fwd[3] * fwd[3])
    if fl < 1e-3 then return nil end
    local r = math.min(maxDist, 18.0)
    return { eye[1] + fwd[1] / fl * r, groundY, eye[3] + fwd[3] / fl * r }, r, "ahead"
end

-- Shooting spells: the first thing the crosshair ray hits within maxDist,
-- else the point maxDist along the view (in the air if you aim up), so a
-- spell flies that way at any distance. Returns pos, distance, via.
function M.AimPoint(maxDist)
    maxDist = maxDist or 100.0
    local eye, fwd = readInvView()
    if not eye then return nil end
    local nudge = 0.4
    local from = { eye[1] + fwd[1] * nudge, eye[2] + fwd[2] * nudge, eye[3] + fwd[3] * nudge }
    local d = M.WorldRay(from, fwd, maxDist)
    if d then
        return { from[1] + fwd[1] * d, from[2] + fwd[2] * d, from[3] + fwd[3] * d }, d + nudge, "ray"
    end
    return { eye[1] + fwd[1] * maxDist, eye[2] + fwd[2] * maxDist, eye[3] + fwd[3] * maxDist }, maxDist, "far"
end

-- Spell aim, 2026-10-10: ONE straight line from the eye (the head-anchored
-- first-person camera) along the crosshair. The first thing on that line
-- wins: a character's hitbox cylinder (exact ray test, no cone assist), else
-- the world surface, else the point maxDist along the line (sky / far).
-- No ground-plane or "ahead" fallbacks. Returns
--   { pos, distance, via = "character" | "world" | "far", target = uuid?, eye, fwd } or nil.
function M.SpellAim(maxDist)
    maxDist = maxDist or 100.0
    local eye, fwd = readInvView()
    if not eye then return nil end
    -- Start the world ray 0.4 m out so it can't hit our own body.
    local nudge = 0.4
    local from = { eye[1] + fwd[1] * nudge, eye[2] + fwd[2] * nudge, eye[3] + fwd[3] * nudge }
    local dw = M.WorldRay(from, fwd, maxDist - nudge)
    local dWorld = dw and (dw + nudge) or nil
    local limit = dWorld or maxDist
    local best, bestD
    local t = now()
    local selfUuid = M.SelfUuid()
    for _, c in ipairs(M.Characters()) do
        if c.uuid ~= selfUuid then
            local cyl = Hitbox.Cylinder(c.uuid, c.feet, t)
            local d = Hitbox.RayHit(cyl, eye, fwd, limit)
            if d and d > 0.3 and (not bestD or d < bestD) then best, bestD = c, d end
        end
    end
    local d, via = limit, dWorld and "world" or "far"
    if best then d, via = bestD, "character" end
    return {
        pos = { eye[1] + fwd[1] * d, eye[2] + fwd[2] * d, eye[3] + fwd[3] * d },
        distance = d, via = via, target = best and best.uuid or nil, eye = eye, fwd = fwd,
    }
end

-- Back-compat for older callers: { eye, forward, hit = { pos, distance } }.
function M.CrosshairRay(maxDist, _includeChars)
    local eye, fwd = readInvView()
    if not eye then return nil end
    local pos, dist, via = M.GroundPoint(maxDist)
    if not pos then return { eye = eye, forward = fwd } end
    return { eye = eye, forward = fwd, hit = { pos = pos, distance = dist, via = via } }
end

-- True if nothing solid (terrain / scenery / door) blocks eye -> point.
function M.LineOfSight(eye, point)
    local dx, dy, dz = point[1] - eye[1], point[2] - eye[2], point[3] - eye[3]
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d < 0.8 then return true end
    local dir = { dx / d, dy / d, dz / d }
    local from = { eye[1] + dir[1] * 0.4, eye[2] + dir[2] * 0.4, eye[3] + dir[3] * 0.4 }
    local hitD = M.WorldRay(from, dir, d - 0.4)
    return (not hitD) or hitD >= (d - 0.4) - 0.6
end

-- ---------------------------------------------------------------------
-- Characters (incremental scan)
-- ---------------------------------------------------------------------
local NEAR_M = 100.0          -- keep characters within this radius (spell aim reaches 100 m)
local SLICE = 48              -- entities examined per tick
local LIST_REFRESH_MS = 3000  -- re-fetch the entity list this often

local scan = { handles = nil, idx = 1, at = -1e9 }
local near = {}               -- uuid -> { uuid, feet, seen }
local nearList = {}
local nearDirty = true

local function stepScan()
    local t = now()
    if not scan.handles or (scan.idx > #scan.handles and t - scan.at > LIST_REFRESH_MS) then
        local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientCharacter")
        if not ok or not ents or #ents == 0 then
            ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Character")
        end
        scan.handles = (ok and ents) or {}
        scan.idx = 1
        scan.at = t
        -- Expire entries not seen for two full passes.
        for u, c in pairs(near) do
            if t - c.seen > 2 * LIST_REFRESH_MS + 2000 then near[u] = nil; nearDirty = true end
        end
        return
    end
    if scan.idx > #scan.handles then return end
    local me = M.SelfFeet()
    if not me then return end
    local myUuid = selfCache.uuid
    local last = math.min(#scan.handles, scan.idx + SLICE - 1)
    for i = scan.idx, last do
        local e = scan.handles[i]
        local okT, tr = pcall(getTranslate, e)
        local feet = okT and vec3(tr) or nil
        if feet then
            local dx, dz = feet[1] - me[1], feet[3] - me[3]
            if dx * dx + dz * dz <= NEAR_M * NEAR_M and math.abs(feet[2] - me[2]) < 20 then
                local okU, u = pcall(getUuid, e)
                if okU and u and u ~= myUuid then
                    local okH, hp = pcall(getHp, e)
                    local dead = okH and tonumber(hp) ~= nil and tonumber(hp) <= 0
                    if dead then
                        if near[u] then near[u] = nil; nearDirty = true end
                    else
                        local c = near[u]
                        if not c then c = { uuid = u, ent = e }; near[u] = c; nearDirty = true end
                        c.feet, c.seen = feet, t
                    end
                end
            end
        end
    end
    scan.idx = last + 1
end

-- Positions of known-near characters are refreshed every call (cheap:
-- only the near set, usually < 30).
local posAt = -1e9
function M.Characters()
    local t = now()
    if nearDirty then
        nearList = {}
        for _, c in pairs(near) do nearList[#nearList + 1] = c end
        nearDirty = false
    end
    if t - posAt > 100 then
        posAt = t
        for _, c in ipairs(nearList) do
            local okT, tr = pcall(getTranslate, c.ent)
            local feet = okT and vec3(tr) or nil
            if feet then c.feet = feet end
        end
    end
    return nearList
end

function M.Tick()
    pcall(stepScan)
    pcall(calibrate)
end

-- ---------------------------------------------------------------------
-- Cone targeting
-- ---------------------------------------------------------------------
-- Each character is a cylinder hitbox (Shared/Hitbox.lua, data/hitbox.lua)
-- that rises with the character's jump. A ray that hits the cylinder wins
-- outright (angle 0); otherwise the angle is measured to the closest of 7
-- points on its axis and must be inside the cone. Distance is measured to
-- the cylinder's surface, not its axis.
local AXIS_SAMPLES = 7
function M.ConeTarget(eye, fwd, maxDist, halfDeg)
    local cosMax = math.cos(math.rad(halfDeg))
    local t = now()
    local best
    for _, c in ipairs(M.Characters()) do
        local cyl = Hitbox.Cylinder(c.uuid, c.feet, t)
        local cBest
        local rd = Hitbox.RayHit(cyl, eye, fwd, maxDist)
        if rd then
            cBest = { cosA = 1, pos = { eye[1] + fwd[1] * rd, eye[2] + fwd[2] * rd, eye[3] + fwd[3] * rd }, d = rd }
        else
            for i = 0, AXIS_SAMPLES - 1 do
                local py = cyl.y0 + 0.1 + (cyl.y1 - cyl.y0 - 0.15) * i / (AXIS_SAMPLES - 1)
                local px, pz = cyl.x, cyl.z
                local dx, dy, dz = px - eye[1], py - eye[2], pz - eye[3]
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                local surf = math.max(0, d - cyl.r)
                if d > 1e-3 and surf <= maxDist then
                    local cosA = (dx * fwd[1] + dy * fwd[2] + dz * fwd[3]) / d
                    if cosA >= cosMax and (not cBest or cosA > cBest.cosA) then
                        cBest = { cosA = cosA, pos = { px, py, pz }, d = surf }
                    end
                end
            end
        end
        if cBest then
            local ang = math.deg(math.acos(math.min(1, cBest.cosA)))
            if not best or ang < best.angle - 0.5 or (math.abs(ang - best.angle) <= 0.5 and cBest.d < best.distance) then
                best = { targetUuid = c.uuid, pos = cBest.pos, distance = cBest.d, angle = ang,
                         zone = Hitbox.Zone(cyl, cBest.pos[2]), lift = cyl.lift }
            end
        end
    end
    return best
end

-- Character under the crosshair (6 degree aim assist, line of sight).
-- Returns { target, pos, distance, via = "cone" } or nil.
function M.TargetAtCrosshair(maxDist, halfDeg)
    local eye, fwd = readInvView()
    if not eye then return nil end
    local c = M.ConeTarget(eye, fwd, maxDist or 40.0, halfDeg or 6.0)
    if c and M.LineOfSight(eye, c.pos) then
        return { target = c.targetUuid, pos = c.pos, distance = c.distance, via = "cone" }
    end
    return nil
end

-- Melee: best body inside the swing arc within reach, with line of sight.
function M.MeleeTarget(eye, fwd, reach, halfDeg)
    local c = M.ConeTarget(eye, fwd, reach, halfDeg)
    if c and M.LineOfSight(eye, c.pos) then return c end
    return nil
end

-- Kept for older callers; now just the geometric melee test.
function M.FanClosestCharacter(eye, forward, reach, yawDeg, _pitchDeg, _rays, _nudge)
    return M.MeleeTarget(eye, forward, reach + 0.5, math.max(35, (yawDeg or 90) / 2))
end

-- Hit zone from the hit height on the target's cylinder hitbox.
function M.ClassifyZone(targetUuid, hitY)
    for _, c in ipairs(nearList) do
        if c.uuid == targetUuid and c.feet then
            return Hitbox.Zone(Hitbox.Cylinder(c.uuid, c.feet), hitY or c.feet[2])
        end
    end
    return "torso"
end

local registered = false
function M.Register()
    if registered then return end
    registered = true
    Ext.Events.Tick:Subscribe(M.Tick)
    Ext.RegisterConsoleCommand("dag_aim_test", function()
        local eye, fwd = readInvView()
        local deye, dfwd = readDll()
        local pos, d, via = M.GroundPoint(30)
        local t = M.TargetAtCrosshair(40)
        local function v(x) return x and string.format("(%.2f,%.2f,%.2f)", x[1], x[2], x[3]) or "nil" end
        Log.Write(string.format("Aim test: sign=%+d eye=%s fwd=%s | DLL eye=%s fwd=%s", fwdSign,
            v(eye), v(fwd), v(deye), v(dfwd)))
        Log.Write(string.format("Aim test: ground=%s d=%s via=%s rawDistance=%s target=%s near=%d",
            v(pos),
            d and string.format("%.2f", d) or "nil", tostring(via), tostring(lastRawDistance),
            t and string.format("%s @%.1fm", t.target, t.distance) or "none", #M.Characters()))
    end)
    Log.Write("Aim: registered fix4 (forward = +col3, self-calibrating; !dag_aim_test)")
end

return M
