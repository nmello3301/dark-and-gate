-- SPDX-License-Identifier: GPL-3.0-or-later
-- World line checks for the crosshair (Client/Combat/Aim.lua) and our
-- projectile flight (Server/Combat/Projectiles.lua).
--
-- Playtest 2026-10-15 (the roofed wreck on the beach): under a roof the
-- crosshair ray "hit" something 0.4 m in front of the eye, at the ray's
-- very start, and the server's flight hit the same nothing at its origin:
-- the camera sat inside an invisible collision shape. A ray that starts
-- inside a shape reports a hit at distance 0. So:
--   * every hit along the line is read (Ext.Level.RaycastAll) and hits
--     closer than min_hit_m to the start (a shape the line starts inside)
--     are skipped;
--   * BG3's pass-through groups (data/projectiles.lua world_ray.ignore_groups,
--     "CanShootThrough": what BG3's own projectiles fly through) are left
--     out of the query;
--   * each hit's physics groups are kept (Last()) for the logs, so a shape
--     that still gets in the way can be named and added to ignore_groups.
-- RaycastClosest stays as the fallback if RaycastAll is refused.
--
--   WorldRay.Cast(from, to) -> distance in metres from `from`, or nil
--   WorldRay.Last()         -> { groups = "...", skipped = n, via = "all"|"closest" } of the last hit

local Log  = Ext.Require("Shared/Log.lua")
local data = Ext.Require("data/projectiles.lua")

local M = {}

local CFG = data.world_ray or {}
-- Physics groups that block a shot. The server rejected "Door" (2026-10-12:
-- "not a valid 'PhysicsGroupFlags' bitfield value: Door"), so the sets are
-- tried in order and the first one accepted is kept.
local INCLUDE_SETS = { { "Terrain", "Scenery", "Item" }, { "Terrain", "Scenery" }, { "Terrain" } }
local includeSet = 1
local exclude = CFG.ignore_groups or {}
local useAll = true
local last = nil

local function len3(a) return math.sqrt(a[1] * a[1] + a[2] * a[2] + a[3] * a[3]) end

-- A physics groups value as text for the logs.
local function groupsText(v)
    if v == nil then return "?" end
    local ok, s = pcall(Ext.Json.Stringify, v)
    if ok and s and s ~= "" and s ~= "null" then return (s:gsub('[%[%]"]', ""):gsub(",", "|")) end
    return tostring(v)
end

-- hit.Distance is a 0..1 fraction of the ray for RaycastClosest (spike 2);
-- RaycastAll's unit is unverified. With the hit's Position known, the
-- reading (fraction x length, or metres) closest to |Position - from| wins;
-- without it, a value above 1 is metres. Both are logged once.
local unitLogged = false
local function metres(raw, L, pos, a)
    raw = tonumber(raw)
    if not raw then return nil end
    local asFrac = raw <= 1.0001 and raw * L or nil
    local px, py, pz
    if type(pos) == "table" or type(pos) == "userdata" then
        pcall(function() px, py, pz = tonumber(pos[1] or pos.x), tonumber(pos[2] or pos.y), tonumber(pos[3] or pos.z) end)
    end
    if px and py and pz and a and (px ~= 0 or py ~= 0 or pz ~= 0) then
        local dp = len3({ px - a[1], py - a[2], pz - a[3] })
        if not unitLogged and raw > 0 then
            unitLogged = true
            Log.Write(string.format("WorldRay: hit Distance %.4f on a %.2f m line; |Position - from| = %.2f m -> %s",
                raw, L, dp, (asFrac and math.abs(asFrac - dp) <= math.abs(raw - dp)) and "a fraction" or "metres"))
        end
        if asFrac and math.abs(asFrac - dp) <= math.abs(raw - dp) then return asFrac end
        return raw
    end
    return asFrac or raw
end

local function query(fn, a, b)
    while includeSet <= #INCLUDE_SETS do
        local ok, hit = pcall(fn, a, b, "Static", INCLUDE_SETS[includeSet], exclude, 1)
        if ok then return true, hit end
        if #exclude > 0 then
            Log.Write(string.format("WorldRay: ignore groups %s refused (%s) -> none ignored", table.concat(exclude, ","), tostring(hit)))
            exclude = {}
        else
            Log.Write(string.format("WorldRay: groups %s refused (%s)", table.concat(INCLUDE_SETS[includeSet], ","), tostring(hit)))
            includeSet = includeSet + 1
        end
    end
    return false, nil
end

local function castAll(a, b, L)
    local ok, all = query(Ext.Level.RaycastAll, a, b)
    if not ok then return false end
    if not all then return true, nil end
    local dists, groups, positions
    pcall(function() dists, groups, positions = all.Distances, all.PhysicsGroup, all.Positions end)
    local best, bestI, skipped = nil, nil, 0
    local minHit = CFG.min_hit_m or 0.02
    for i = 1, (dists and #dists or 0) do
        local d = metres(dists[i], L, positions and positions[i], a)
        if d then
            if d < minHit then
                skipped = skipped + 1
            elseif not best or d < best then
                best, bestI = d, i
            end
        end
    end
    if skipped > 0 and not M.skipLogged then
        M.skipLogged = true
        Log.Write(string.format("WorldRay: a line started inside a shape (groups %s): that hit is skipped (logged once)",
            groupsText(groups and groups[1])))
    end
    if best then last = { groups = groupsText(groups and groups[bestI]), skipped = skipped, via = "all" } end
    return true, best
end

local function castClosest(a, b, L)
    local ok, hit = query(Ext.Level.RaycastClosest, a, b)
    if not ok or not hit then return nil end
    local okD, raw = pcall(function() return hit.Distance end)
    local pos = nil
    pcall(function() pos = hit.Position end)
    local d = okD and metres(raw, L, pos, a) or nil
    if not d then return nil end
    local g = nil
    pcall(function() g = hit.PhysicsGroup end)
    last = { groups = groupsText(g), skipped = 0, via = "closest" }
    return d
end

function M.Cast(a, b)
    local L = len3({ b[1] - a[1], b[2] - a[2], b[3] - a[3] })
    if L < 1e-4 then return nil end
    if useAll then
        local ok, d = castAll(a, b, L)
        if ok then return d end
        useAll = false
        Log.Write("WorldRay: RaycastAll unavailable -> RaycastClosest (a line starting inside a shape hits at once)")
    end
    return castClosest(a, b, L)
end

function M.Last() return last end
function M.Groups() return table.concat(INCLUDE_SETS[includeSet] or {}, ","), table.concat(exclude, ",") end

return M
