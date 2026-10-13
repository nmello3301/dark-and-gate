-- SPDX-License-Identifier: GPL-3.0-or-later
-- What the crosshair is on: one shared client service (DECISIONS 2026-10-12,
-- docs/spikes/lookat.md) for F interaction, targeted spells, area-spell
-- indicators and the revive prompt.
--
--   LookAt.Get() -> {
--     eye, fwd            the camera ray (Client/Combat/Aim.lua)
--     point, dist, via    the first world hit within data/interact.lua max_m
--                         ("world"), else the point max_m out ("far")
--     character           { uuid, dist, point, zone }: the first living
--                         character cylinder on the line, before the world
--     object              { uuid, dist, how, kind, verb, name, ent }: the
--                         interactive thing under the crosshair within reach_m
--                         (nil if there is none; kind from the server)
--   } or nil (camera unreadable). Recomputed update_hz times a second.
--   LookAt.LOS(point [, eye])   nothing solid between the eye and point
--   LookAt.Info(uuid)           the server's "what is this" (cached), nil while asked
--   LookAt.Entity(uuid)         the client entity
--
-- How the interactive thing is found, best first:
--   1. a physics ray (Items + Characters, Static + Dynamic) whose hit names
--      its entity (hit.Shape.PhysicsObject.Entity, SE v33);
--   2. the living character the crosshair line hits (cylinder), within reach;
--   3. a scan of the items and corpses around the player (the engine's
--      spatial grid, Ext.Entity.GetEntitiesAroundPosition, or a sliced scan
--      of every item): the one closest to the crosshair inside cone_deg, in
--      line of sight.
-- The server classifies each (Server/Combat/Interact.lua: talk, loot, door,
-- open, pickup, use, climb or none); the first that is "something" is
-- highlighted, so a decoration in front doesn't hide what's next to it.
--
--   !dag_lookat            one line: world point, character, object, and the
--                          engine's own hover (picking helper) to compare
--   !dag_lookat on|off     that line every 0.5 s

local Log        = Ext.Require("Shared/Log.lua")
local Net        = Ext.Require("Shared/Net.lua")
local Hitbox     = Ext.Require("Shared/Hitbox.lua")
local TickBudget = Ext.Require("Shared/TickBudget.lua")
local ClientNet  = Ext.Require("Client/Net.lua")
local Aim        = Ext.Require("Client/Combat/Aim.lua")
local State      = Ext.Require("Client/Combat/State.lua")
local cfg        = Ext.Require("data/interact.lua")

local M = {}

local cur = nil
local lastAt = -1e9
local info = {}          -- uuid -> { kind, verb, name, at }
local asked = {}         -- uuid -> ms
local entityRay = nil    -- nil = untested, true = names entities, false = can't
local physMode = 1
local PHYS = { { "Static", "Dynamic" }, "Static" }
local RAY_GROUPS = { "Item", "Character" }
local logOn, logAt = false, -1e9

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local function add(a, b, s) s = s or 1; return { a[1] + b[1] * s, a[2] + b[2] * s, a[3] + b[3] * s } end
local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function len(a) return math.sqrt(dot(a, a)) end
local function fmt(p) return p and string.format("(%.2f,%.2f,%.2f)", p[1], p[2], p[3]) or "-" end

local function uuidOf(e)
    local ok, u = pcall(function() return tostring(e.Uuid.EntityUuid) end)
    if ok and u and u ~= "nil" then return u end
    return nil
end

local function posOf(e)
    local ok, t = pcall(function() return e.Transform.Transform.Translate end)
    if ok and t then return { t[1], t[2], t[3] } end
    return nil
end

local entCache = {}
function M.Entity(uuid)
    if not uuid then return nil end
    local e = entCache[uuid]
    if e then return e end
    local ok, en = pcall(Ext.Entity.Get, uuid)
    if ok and en then entCache[uuid] = en; return en end
    return nil
end

-- ---------------------------------------------------------------------
-- Server classification
-- ---------------------------------------------------------------------
function M.Info(uuid)
    if not uuid then return nil end
    local i = info[uuid]
    local t = now()
    if i and t - i.at < (cfg.classify_ttl_s or 10) * 1000 then return i end
    if not asked[uuid] or t - asked[uuid] > 1500 then
        asked[uuid] = t
        ClientNet.Send(Net.Channels.InteractClassify, { target = uuid })
    end
    return i
end
function M.Forget(uuid) info[uuid] = nil end

-- ---------------------------------------------------------------------
-- 1. Physics ray naming the entity
-- ---------------------------------------------------------------------
local function rayEntity(eye, fwd, reach)
    if entityRay == false then return nil end
    local from = add(eye, fwd, 0.3)
    local to = add(eye, fwd, reach)
    local ok, hit = pcall(Ext.Level.RaycastClosest, from, to, PHYS[physMode], RAY_GROUPS, {}, 1)
    if not ok then
        if physMode == 1 then
            physMode = 2
            Log.Write("LookAt: physics type {Static, Dynamic} rejected (" .. tostring(hit) .. "), using Static")
        else
            entityRay = false
            Log.Write("LookAt: the entity ray errors (" .. tostring(hit) .. ") -> nearby scan only")
        end
        return nil
    end
    if not hit then return nil end
    local okD, raw = pcall(function() return tonumber(hit.Distance) end)
    local d = (okD and raw) and ((raw <= 1.0001) and (0.3 + raw * (reach - 0.3)) or raw) or nil
    local okE, ent = pcall(function() return hit.Shape.PhysicsObject.Entity end)
    local u = okE and ent and uuidOf(ent) or nil
    if not u and okE and ent then
        local okG, e2 = pcall(Ext.Entity.Get, ent)
        u = okG and e2 and uuidOf(e2) or nil
    end
    if not u then
        if entityRay == nil then
            entityRay = false
            Log.Write("LookAt: the physics ray can't name entities (hit.Shape.PhysicsObject.Entity -> " .. tostring(okE and ent or "error")
                .. ") -> nearby scan only")
        end
        return nil
    end
    if entityRay == nil then
        entityRay = true
        Log.Write("LookAt: the physics ray names entities (hit.Shape.PhysicsObject.Entity) -> used for F")
    end
    return u, d
end

-- ---------------------------------------------------------------------
-- 3. Nearby items and corpses
-- ---------------------------------------------------------------------
local near = {}          -- uuid -> { uuid, ent, pos, corpse, seen }
local aroundOk = nil     -- the spatial grid query works on the client
local aroundEmpty = 0
local aroundAt = -1e9
local slice = { list = nil, idx = 1, at = -1e9, which = "IsItem" }

local function consider(e, feet, t)
    local u = uuidOf(e)
    if not u or u == Aim.SelfUuid() then return end
    local p = posOf(e)
    if not p then return end
    local dx, dz = p[1] - feet[1], p[3] - feet[3]
    local R = cfg.scan_radius_m or 8
    if dx * dx + dz * dz > R * R or math.abs(p[2] - feet[2]) > 6 then near[u] = nil; return end
    local isItem = false
    pcall(function() isItem = e.IsItem ~= nil end)
    local corpse = false
    if not isItem then
        local okH, hp = pcall(function() return e.Health.Hp end)
        corpse = okH and tonumber(hp) ~= nil and tonumber(hp) <= 0
        if not corpse then near[u] = nil; return end   -- the living are found by their cylinders
    end
    local n = near[u] or { uuid = u }
    n.ent, n.pos, n.corpse, n.seen = e, p, corpse, t
    near[u] = n
end

local function scanNear()
    local t = now()
    local feet = Aim.SelfFeet()
    if not feet then return end
    if aroundOk ~= false and t - aroundAt > 250 then
        aroundAt = t
        local ok, list = pcall(Ext.Entity.GetEntitiesAroundPosition, feet, cfg.scan_radius_m or 8, true, true)
        if not ok or type(list) ~= "table" and type(list) ~= "userdata" then
            aroundOk = false
            Log.Write("LookAt: Ext.Entity.GetEntitiesAroundPosition unavailable on the client (" .. tostring(list) .. ") -> sliced item scan")
            return
        end
        local n = 0
        for _, e in ipairs(list) do n = n + 1; consider(e, feet, t) end
        if n == 0 then
            aroundEmpty = aroundEmpty + 1
            if aroundEmpty >= 3 and aroundOk == nil then
                aroundOk = false
                Log.Write("LookAt: the spatial grid returns nothing on the client (not even the player) -> sliced item scan")
            end
        elseif aroundOk == nil then
            aroundOk = true
            Log.Write(string.format("LookAt: nearby objects from the engine's spatial grid (%d within %.0f m)", n, cfg.scan_radius_m or 8))
        end
        for u, o in pairs(near) do if t - o.seen > 1500 then near[u] = nil end end
        return
    end
    if aroundOk ~= false then return end
    -- Sliced fallback: every item, then every character (corpses), 64 a tick.
    if not slice.list or slice.idx > #slice.list then
        if slice.list and t - slice.at < 2000 then return end
        slice.which = (slice.which == "IsItem") and "ClientCharacter" or "IsItem"
        local ok, list = pcall(Ext.Entity.GetAllEntitiesWithComponent, slice.which)
        slice.list, slice.idx, slice.at = (ok and list) or {}, 1, t
        for u, o in pairs(near) do if t - o.seen > 6000 then near[u] = nil end end
        return
    end
    local last = math.min(#slice.list, slice.idx + 63)
    for i = slice.idx, last do consider(slice.list[i], feet, t) end
    slice.idx = last + 1
end

-- Line of sight from eye to p, ignoring the object itself (its own hit
-- counts as reaching it).
function M.LOS(p, eye)
    eye = eye or (cur and cur.eye)
    if not eye or not p then return false end
    return Aim.LineOfSight(eye, p)
end

local function coneScan(eye, fwd, reach)
    local cosMax = math.cos(math.rad(cfg.cone_deg or 8))
    local best, bestCos, bestD = nil, -1, nil
    for u, o in pairs(near) do
        local p = { o.pos[1], o.pos[2] + (o.corpse and 0.25 or 0.35), o.pos[3] }
        local v = sub(p, eye)
        local d = len(v)
        if d > 0.2 and d <= reach + 0.5 then
            local c = dot(v, fwd) / d
            if c >= cosMax and c > bestCos then
                local nudge = math.min(0.4, d * 0.5)
                local hit = Aim.WorldRay(add(eye, fwd, 0), { v[1] / d, v[2] / d, v[3] / d }, d)
                if not hit or hit >= d - (o.corpse and 0.3 or 0.7) - nudge then best, bestCos, bestD = u, c, d end
            end
        end
    end
    return best, bestD
end

-- ---------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------
-- Candidates best first: the ray's entity, the living character on the line
-- (first when nearer), then the nearby scan. One the server calls "none" no
-- longer hides the next (playtest 2026-10-13: decorations and an invisible
-- helper item in front of interactive things); one still being asked about
-- holds the answer back.
local function findObject(eye, fwd, r)
    local reach = cfg.reach_m or 4
    local cands = {}
    local u, d = rayEntity(eye, fwd, reach)
    if u and u ~= Aim.SelfUuid() then cands[1] = { uuid = u, how = "ray", dist = d } end
    if r.character and r.character.dist <= reach and not (cands[1] and cands[1].uuid == r.character.uuid) then
        local c = { uuid = r.character.uuid, how = "cylinder", dist = r.character.dist }
        if not cands[1] or not cands[1].dist or c.dist < cands[1].dist - 0.2 then table.insert(cands, 1, c)
        else cands[#cands + 1] = c end
    end
    local scanned, i = false, 1
    while true do
        local c = cands[i]
        if not c and not scanned then
            scanned = true
            local s, sd = coneScan(eye, fwd, reach)
            local dup = false
            for _, o in ipairs(cands) do if o.uuid == s then dup = true end end
            if s and not dup then cands[i] = { uuid = s, how = "scan", dist = sd }; c = cands[i] end
        end
        if not c then return nil end
        local inf = M.Info(c.uuid)
        if not inf then return { uuid = c.uuid, dist = c.dist, how = c.how, pending = true } end
        if inf.kind ~= "none" then
            return { uuid = c.uuid, dist = c.dist, how = c.how, kind = inf.kind, verb = inf.verb, name = inf.name,
                     ent = M.Entity(c.uuid), point = add(eye, fwd, c.dist or 1) }
        end
        i = i + 1
    end
end

local function update()
    local eye, fwd = Aim.ReadInvView()
    if not eye then cur = nil; return end
    local r = { eye = eye, fwd = fwd, at = now() }
    local maxM = cfg.max_m or 100
    local nudge = 0.4
    local dw = Aim.WorldRay(add(eye, fwd, nudge), fwd, maxM - nudge)
    r.dist = dw and (dw + nudge) or maxM
    r.via = dw and "world" or "far"
    r.point = add(eye, fwd, r.dist)
    local selfUuid = Aim.SelfUuid()
    local bestD, best, bestCyl = nil, nil, nil
    local t = now()
    for _, c in ipairs(Aim.Characters()) do
        if c.uuid ~= selfUuid and c.feet then
            local cyl = Hitbox.Cylinder(c.uuid, c.feet, t)
            local d = Hitbox.RayHit(cyl, eye, fwd, r.dist)
            if d and d > 0.3 and (not bestD or d < bestD) then bestD, best, bestCyl = d, c, cyl end
        end
    end
    if best then
        local p = add(eye, fwd, bestD)
        r.character = { uuid = best.uuid, dist = bestD, point = p, zone = Hitbox.Zone(bestCyl, p[2]), ent = best.ent }
    end
    r.object = findObject(eye, fwd, r)
    cur = r
end

function M.Get()
    if now() - lastAt > 1000 / (cfg.update_hz or 20) then
        lastAt = now()
        local ok, err = pcall(update)
        if not ok then cur = nil; if not M.errLogged then M.errLogged = true; Log.Write("LookAt: update error " .. tostring(err)) end end
    end
    return cur
end

local function enginePick()
    local parts = {}
    local ok, p = pcall(Ext.UI.GetPickingHelper, 1)
    if not ok or not p then return "engine hover: no picking helper" end
    pcall(function()
        local i = p.Inner.Inner[1]
        for _, f in ipairs({ "Character", "DeadCharacter", "Item", "GameObject" }) do
            local okF, e = pcall(function() return i[f] end)
            if okF and e then parts[#parts + 1] = f .. "=" .. (uuidOf(e) or tostring(e)) end
        end
    end)
    pcall(function() parts[#parts + 1] = string.format("cursor=(%.0f,%.0f)", p.WindowCursorPos[1], p.WindowCursorPos[2]) end)
    pcall(function() parts[#parts + 1] = "RequestedCursor=" .. tostring(Ext.UI.GetCursorControl().RequestedCursor) end)
    return "engine hover: " .. (#parts > 0 and table.concat(parts, " ") or "nothing")
end

local function line()
    local r = M.Get()
    if not r then return "LookAt: camera not readable" end
    local c, o = r.character, r.object
    local function nm(u)
        local i = info[u]
        return i and i.name or u
    end
    local nNear = 0
    for _ in pairs(near) do nNear = nNear + 1 end
    return string.format("LookAt: %s %.1f m %s | character %s | object %s | scan %s (%d near) | %s", r.via, r.dist, fmt(r.point),
        c and string.format("%s %.1f m %s", nm(c.uuid), c.dist, c.zone) or "-",
        o and (o.pending and string.format("%s %.1f m (asking the server)", o.uuid, o.dist or 0)
            or string.format("%s %s %.1f m via %s", tostring(o.verb), tostring(o.name), o.dist or 0, tostring(o.how))) or "-",
        aroundOk == true and "spatial grid" or (aroundOk == false and "sliced" or "?"), nNear, enginePick())
end
M.Line = line

local function tick()
    if not State.povOn then return end
    scanNear()
    if logOn and now() - logAt > 500 then
        logAt = now()
        Log.Write(line())
    end
end

function M.Register()
    Ext.RegisterNetListener(Net.Channels.InteractInfo, function(_, payload)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" or not p.target then return end
        info[p.target] = { kind = p.kind or "none", verb = p.verb, name = p.name, at = now() }
        if logOn then Log.Write(string.format("LookAt: server says %s is %s (%s %s)", p.target, tostring(p.kind), tostring(p.verb), tostring(p.name))) end
    end)
    Ext.Events.Tick:Subscribe(TickBudget.Wrap("LookAt", tick))
    Ext.RegisterConsoleCommand("dag_lookat", function(_, a)
        if a == "on" or a == "off" then
            logOn = (a == "on")
            Log.Write("LookAt: logging " .. (logOn and "ON (every 0.5 s)" or "OFF"))
        else
            lastAt = -1e9
            Log.Write(line())
        end
    end)
    Log.Write("LookAt: registered (!dag_lookat [on|off])")
end

return M
