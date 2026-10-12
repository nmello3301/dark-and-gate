-- SPDX-License-Identifier: GPL-3.0-or-later
-- Passive shields (DECISIONS 2026-10-12): a disc on the shield arm, facing
-- forward, tested BEFORE the body cylinder. A hit that physically lands on it
-- (melee swing ray, arrow, projectile spell) loses data/combat.lua
-- shield.reduction of its damage. Rough on purpose: a disc, not the mesh.
--
--   Shield.Disc(feet, fwd)              -> { c = centre, n = normal, r = radius } or nil
--   Shield.RayHit(disc, o, d, maxDist, pad) -> distance along the ray, or nil
--   Shield.Forward(entity)              -> unit facing vector from the Transform
--   Shield.CheckFacing(entity, walkDir) -> votes on the forward sign while the
--                                          character walks (it faces where it
--                                          walks); flips it after 3 votes

local cfg = Ext.Require("data/combat.lua")

local M = {}

local function add(a, b, s) s = s or 1; return { a[1] + b[1] * s, a[2] + b[2] * s, a[3] + b[3] * s } end
local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function len(a) return math.sqrt(dot(a, a)) end

-- Facing from the Transform's rotation quaternion: the character's local +Z
-- (times fwdSign, which CheckFacing corrects if the engine's forward is -Z).
local fwdSign = cfg.shield.fwd_sign or 1
local votes = 0
function M.Forward(ent)
    local ok, q = pcall(function() return ent.Transform.Transform.RotationQuat end)
    if not ok or not q then return nil end
    local x, y, z, w = q[1] or q.x, q[2] or q.y, q[3] or q.z, q[4] or q.w
    if not (x and y and z and w) then return nil end
    -- rotate (0,0,1) by q
    local fx = 2 * (x * z + w * y)
    local fy = 2 * (y * z - w * x)
    local fz = 1 - 2 * (x * x + y * y)
    local fl = math.sqrt(fx * fx + fz * fz)
    if fl < 1e-4 then return nil end
    return { fwdSign * fx / fl, 0, fwdSign * fz / fl }   -- flatten: the shield faces horizontally
end

function M.CheckFacing(ent, walkDir)
    local f = M.Forward(ent)
    if not f or not walkDir then return nil end
    local wl = math.sqrt(walkDir[1] * walkDir[1] + walkDir[3] * walkDir[3])
    if wl < 1e-3 then return nil end
    local dot = (f[1] * walkDir[1] + f[3] * walkDir[3]) / wl
    if dot < -0.8 then
        votes = votes + 1
        if votes >= 3 then fwdSign, votes = -fwdSign, 0; return dot, true end
    elseif dot > 0.8 then
        votes = 0
    end
    return dot, false
end
function M.FwdSign() return fwdSign end

-- Who holds a shield is decided by the caller's hasShield(uuid) (server: the
-- equipped off-hand item's stats), so this file stays pure geometry.
function M.Disc(feet, fwd)
    local s = cfg.shield
    if not feet or not fwd then return nil end
    local side = { fwd[3] * (s.side_sign or 1), 0, -fwd[1] * (s.side_sign or 1) }
    local c = add(add(add(feet, { 0, 1, 0 }, s.height_m), fwd, s.fwd_m), side, s.side_m)
    return { c = c, n = fwd, r = s.radius_m }
end

-- Ray o + d*t (d unit) against the disc; pad grows the disc (projectile radius).
function M.RayHit(disc, o, d, maxDist, pad)
    if not disc then return nil end
    local denom = dot(d, disc.n)
    if math.abs(denom) < 1e-4 then return nil end
    local t = dot(sub(disc.c, o), disc.n) / denom
    if t < 0 or (maxDist and t > maxDist) then return nil end
    local p = add(o, d, t)
    if len(sub(p, disc.c)) <= disc.r + (pad or 0) then return t end
    return nil
end

function M.Reduction() return cfg.shield.reduction or 0.4 end
function M.SetReduction(v) cfg.shield.reduction = math.max(0, math.min(1, tonumber(v) or cfg.shield.reduction)) end

return M
