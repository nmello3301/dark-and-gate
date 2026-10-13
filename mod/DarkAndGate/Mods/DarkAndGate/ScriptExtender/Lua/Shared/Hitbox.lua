-- SPDX-License-Identifier: GPL-3.0-or-later
-- Character hitboxes, shared by client (aim, melee) and server (hit
-- validation, later AI melee): one vertical cylinder per character, sized
-- by data/hitbox.lua. A character that is jumping has its cylinder lifted
-- by the same curve the DLL uses for the visual lift:
--   lift(t) = h * (1 - |2u - 1|^k), u = t / T
-- Jumps are registered with SetJump (the local jump on the client, the
-- JumpStart message on the server, JumpNotify for other players' jumps on
-- a client). Each side uses its own clock, so the curve is only as close as
-- the network delay between them -- fine for the cylinder sizes we use.

local data = Ext.Require("data/hitbox.lua")

local M = {}

local jumps = {}   -- uuid -> { t0 = ms, dur = ms, h = m, k = flatness }
-- Real jump (2026-10-10 default): the body really rises on the jumper's
-- client, which the server can't see. That client reports its height above
-- the take-off ground (JumpLift, ~15 Hz); a fresh sample wins over the curve.
local samples = {} -- uuid -> { lift = m, at = ms }
local SAMPLE_TTL_MS = 300

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

function M.SetJump(uuid, durMs, h, k, t0)
    if not uuid then return end
    jumps[uuid] = { t0 = t0 or now(), dur = tonumber(durMs) or 0, h = tonumber(h) or 0, k = tonumber(k) or 2 }
end

-- In the air right now: a jump window that hasn't ended (AirSurfaces.lua).
function M.Airborne(uuid, t)
    local j = uuid and jumps[uuid]
    if not j then return false end
    local dt = (t or now()) - j.t0
    return dt >= 0 and dt < j.dur
end

function M.SetLiftSample(uuid, lift)
    if not uuid then return end
    lift = tonumber(lift) or 0
    if lift <= 0.001 then samples[uuid] = nil else samples[uuid] = { lift = lift, at = now() } end
end

-- Current lift of a character's hitbox, metres.
function M.Lift(uuid, t)
    local smp = uuid and samples[uuid]
    if smp then
        if now() - smp.at <= SAMPLE_TTL_MS then return smp.lift end
        samples[uuid] = nil
    end
    local j = uuid and jumps[uuid]
    if not j or j.dur <= 0 then return 0 end
    local dt = (t or now()) - j.t0
    if dt < 0 then return 0 end
    if dt >= j.dur then jumps[uuid] = nil; return 0 end
    local u = dt / j.dur
    return j.h * (1 - math.abs(2 * u - 1) ^ math.max(1, j.k))
end

-- Cylinder for a character standing at `feet` ({x, y, z}):
-- { x, z, y0 (bottom), y1 (top), r, lift }.
function M.Cylinder(uuid, feet, t)
    local lift = M.Lift(uuid, t)
    local y0 = feet[2] + data.base_m + lift
    return { x = feet[1], z = feet[3], y0 = y0, y1 = y0 + data.height_m, r = data.radius_m, lift = lift }
end

local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end

-- Closest point on the cylinder's axis segment to point p.
function M.AxisPoint(c, p)
    return { c.x, clamp(p[2], c.y0, c.y1), c.z }
end

-- Distance from point p to the cylinder's surface (0 when inside).
function M.Distance(c, p)
    local dx, dz = p[1] - c.x, p[3] - c.z
    local radial = math.max(0, math.sqrt(dx * dx + dz * dz) - c.r)
    local vertical = 0
    if p[2] < c.y0 then vertical = c.y0 - p[2] elseif p[2] > c.y1 then vertical = p[2] - c.y1 end
    return math.sqrt(radial * radial + vertical * vertical)
end

-- Ray (origin o, unit dir d) against the cylinder. Returns the distance
-- along the ray to the first hit, or nil. Side wall plus both caps.
function M.RayHit(c, o, d, maxDist)
    local best
    local ox, oz = o[1] - c.x, o[3] - c.z
    local a = d[1] * d[1] + d[3] * d[3]
    if a > 1e-8 then
        local b = 2 * (ox * d[1] + oz * d[3])
        local cc = ox * ox + oz * oz - c.r * c.r
        local disc = b * b - 4 * a * cc
        if disc >= 0 then
            local s = math.sqrt(disc)
            for _, t in ipairs({ (-b - s) / (2 * a), (-b + s) / (2 * a) }) do
                if t >= 0 then
                    local y = o[2] + d[2] * t
                    if y >= c.y0 and y <= c.y1 and (not best or t < best) then best = t end
                end
            end
        end
    end
    if math.abs(d[2]) > 1e-8 then
        for _, yc in ipairs({ c.y0, c.y1 }) do
            local t = (yc - o[2]) / d[2]
            if t >= 0 then
                local px, pz = o[1] + d[1] * t - c.x, o[3] + d[3] * t - c.z
                if px * px + pz * pz <= c.r * c.r and (not best or t < best) then best = t end
            end
        end
    end
    -- Origin inside the cylinder counts as an immediate hit.
    if not best and M.Distance(c, o) == 0 then best = 0 end
    if best and maxDist and best > maxDist then return nil end
    return best
end

-- Zone for a hit at height y on cylinder c.
function M.Zone(c, y)
    local f = (y - c.y0) / math.max(0.01, c.y1 - c.y0)
    if f >= data.zones.head then return "head" end
    if f >= data.zones.torso then return "torso" end
    return "limbs"
end

function M.ZoneMult(zone) return data.zone_mult[zone] or 1.0 end
function M.ReachSlack() return data.reach_slack_m end

return M
