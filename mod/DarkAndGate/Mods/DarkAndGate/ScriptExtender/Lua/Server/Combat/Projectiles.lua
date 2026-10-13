-- SPDX-License-Identifier: GPL-3.0-or-later
-- Projectile system v1, server side (docs/design/projectiles.md,
-- docs/spikes/projectiles.md, data/projectiles.lua).
--
--   Launch(caster, spell, claim)   from SpellCast on release:
--     1. our flight: origin on the crosshair line (claim.eye / claim.dir,
--        also right in mid-air), speed from the spell's projectile template;
--     2. the look: BG3 casts the "visual" clone (no effect) at a point far
--        along the line -- its cast animation, trail and projectile;
--     3. our flight starts when BG3's projectile appears (OnCreate
--        ServerProjectile, matched by caster), or after launch_wait_s.
--   Every server tick each projectile moves in steps of step_s; each step's
--   segment is swept against the world (raycast) and against every nearby
--   character's CURRENT cylinder, inflated by the projectile's radius
--   (Shared/Hitbox.lua; a jumping player's cylinder follows the real jump
--   via JumpLift). First contact wins, anywhere mid-flight.
--   On contact: BG3's projectile is removed (RequestDelete), the "impact"
--   clone is applied (Osi.CreateExplosion on the character, or
--   CreateExplosionAtPosition at the point), clients get ProjectileHit.
--
--   !dag_proj_debug on|off   log every step's candidates (noisy)
--
-- Real-time combat pass (2026-10-12):
--   * NPC and companion shots come through here too (Server/Combat/
--     NpcCombat.lua: arrows and projectile spells with imperfect aim). Their
--     visual clone is cast through the cast request queue (castAt).
--   * impact_mode "weapon" (arrows): no impact clone, the hit calls the weapon
--     handler (NpcCombat: weapon dice on our damage path).
--   * Shields: each candidate's shield disc (Server/Combat/Shields.lua) is
--     tested before its cylinder; a hit on it loses data/combat.lua
--     shield.reduction (weapon damage scaled, a spell impact healed back).
--   * A player-controlled target gets the DAG_IP_ impact clone (same spell,
--     HitAnimationType None: no hit reaction), also when one stands inside a
--     point impact's area.
-- Bows (2026-10-12, data/bows.lua): a launch can carry its own speed_mps,
-- gravity, launch_wait_s and dmgMult / draw (claim fields); arrows drop.
-- Ballistic(origin, point, speed, g) is the launch direction that lands on
-- point (NPC archers aim with it).

local Log       = Ext.Require("Shared/Log.lua")
local Net       = Ext.Require("Shared/Net.lua")
local ServerNet = Ext.Require("Server/Net.lua")
local Hitbox    = Ext.Require("Shared/Hitbox.lua")
local PSpells   = Ext.Require("Shared/ProjectileSpells.lua")
local data      = Ext.Require("data/projectiles.lua")
local Shields   = Ext.Require("Server/Combat/Shields.lua")
local Party     = Ext.Require("Server/Party.lua")
local Damage    = Ext.Require("Server/Combat/Damage.lua")
local SpellRange = Ext.Require("Shared/SpellRange.lua")

local M = {}

local nextId = 1
local pending = {}    -- casterUuid -> launch waiting for BG3's projectile
local active = {}     -- id -> projectile
local debugSteps = false
-- Physics groups for the world ray. The server rejected "Door" (playtest
-- 2026-10-12: "not a valid 'PhysicsGroupFlags' bitfield value: Door"), so
-- the sets are tried in order and the first one the server accepts is kept.
local WORLD_SETS = { { "Terrain", "Scenery", "Item" }, { "Terrain", "Scenery" }, { "Terrain" } }
local worldSet = 1

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local function v3(p) return { tonumber(p.x or p[1]) or 0, tonumber(p.y or p[2]) or 0, tonumber(p.z or p[3]) or 0 } end
local function add(a, b, s) s = s or 1; return { a[1] + b[1] * s, a[2] + b[2] * s, a[3] + b[3] * s } end
local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function len(a) return math.sqrt(a[1] * a[1] + a[2] * a[2] + a[3] * a[3]) end
local function norm(a) local l = len(a); return l > 1e-6 and { a[1] / l, a[2] / l, a[3] / l } or { 0, 0, 1 } end
local function fmt(p) return string.format("(%.2f,%.2f,%.2f)", p[1], p[2], p[3]) end

local function broadcast(channel, t)
    local msg = Ext.Json.Stringify(t)
    local ok = pcall(function() Ext.Net.BroadcastMessage(channel, msg) end)
    if not ok then pcall(function() Ext.ServerNet.BroadcastMessage(channel, msg) end) end
end

-- ---------------------------------------------------------------------
-- Characters near the host, scanned a slice per tick (like Client Aim:
-- one pass over ~800 level characters in one tick costs milliseconds).
-- ---------------------------------------------------------------------
local scan = { handles = nil, idx = 1, at = -1e9 }
local near = {}        -- uuid -> { uuid, ent }
local NEAR_M, SLICE, REFRESH_MS = 140, 48, 3000

local function uuidOf(e) local ok, u = pcall(function() return tostring(e.Uuid.EntityUuid) end); return ok and u or nil end
local function feetOf(e)
    local ok, t = pcall(function() return e.Transform.Transform.Translate end)
    return ok and t and { t[1], t[2], t[3] } or nil
end
local function aliveOf(e)
    local ok, hp = pcall(function() return e.Health.Hp end)
    return not ok or tonumber(hp) == nil or tonumber(hp) > 0
end

local hostFeet = nil
local function stepScan()
    local t = now()
    if not scan.handles or (scan.idx > #scan.handles and t - scan.at > REFRESH_MS) then
        local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerCharacter")
        scan.handles, scan.idx, scan.at = (ok and ents) or {}, 1, t
        local okH, host = pcall(Osi.GetHostCharacter)
        if okH and host then
            local okE, he = pcall(Ext.Entity.Get, host)
            hostFeet = okE and he and feetOf(he) or hostFeet
        end
        return
    end
    if not hostFeet then return end
    local last = math.min(#scan.handles, scan.idx + SLICE - 1)
    for i = scan.idx, last do
        local e = scan.handles[i]
        local f = feetOf(e)
        local u = uuidOf(e)
        if f and u then
            local dx, dz = f[1] - hostFeet[1], f[3] - hostFeet[3]
            if dx * dx + dz * dz <= NEAR_M * NEAR_M and aliveOf(e) then
                near[u] = near[u] or { uuid = u, ent = e }
            else
                near[u] = nil
            end
        end
    end
    scan.idx = last + 1
end

-- ---------------------------------------------------------------------
-- Launch
-- ---------------------------------------------------------------------
local tplCache = {}
local function templateSpeed(spell)
    if tplCache[spell] then return tplCache[spell] end
    local r = { speed = nil, accel = 0, mode = "?", traj = "?" }
    pcall(function()
        local st = Ext.Stats.Get(spell)
        r.traj = tostring(st.Trajectories or "")
        local tid = r.traj:match("%x+%-%x+%-%x+%-%x+%-%x+")
        local tpl = tid and Ext.Template.GetTemplate(tid)
        if tpl then
            r.speed = tonumber(tpl.InitialSpeed)
            r.mode = tostring(tpl.VelocityMode)
            if r.mode == "Linear" then r.accel = tonumber(tpl.Acceleration) or 0 end
        end
    end)
    tplCache[spell] = r
    Log.Write(string.format("Projectiles: %s template %s: InitialSpeed %s, VelocityMode %s, Acceleration %.2f", spell, r.traj,
        tostring(r.speed), r.mode, r.accel))
    return r
end

local function casterLevel(caster)
    local ok, l = pcall(function() return Osi.GetLevel(caster) end)
    if ok and tonumber(l) then return tonumber(l) end
    local okE, lv = pcall(function() return Ext.Entity.Get(caster).EocLevel.Level end)
    return okE and tonumber(lv) or 1
end

-- castAt(caster, spellId, point) = SpellCast's UseSpellAtPosition wrapper.
-- impact_mode "weapon": the hit is resolved by this handler (NpcCombat sets it):
-- fn(p, targetUuid, pos, zone, shielded) -- p.caster, p.spell, p.npc.
local weaponHandler = nil
function M.SetWeaponHandler(fn) weaponHandler = fn end

function M.Def(spell) return data.enabled ~= false and data.spells[spell] or nil end
function M.Speed(spell)
    local def = data.spells[spell]
    if not def then return nil end
    local tsp = templateSpeed(spell)
    local speed = (def.speed_mps == "template" and tsp.speed) or tonumber(def.speed_mps) or def.fallback_speed_mps or 25
    return (speed and speed > 0) and speed or (def.fallback_speed_mps or 25)
end

-- The low-arc launch direction from `o` that passes through `p` at `speed`
-- under gravity `g`. Returns dir, angle (deg); nil when `p` is out of reach
-- (then the 45 degree shot toward it is returned as the third value).
function M.Ballistic(o, p, speed, g)
    local d = sub(p, o)
    local dh = math.sqrt(d[1] * d[1] + d[3] * d[3])
    if dh < 1e-3 or not g or g <= 0 then return norm(d), nil end
    local v2 = speed * speed
    local disc = v2 * v2 - g * (g * dh * dh + 2 * d[2] * v2)
    local hx, hz = d[1] / dh, d[3] / dh
    if disc < 0 then
        local c = math.sqrt(0.5)
        return nil, nil, { hx * c, c, hz * c }
    end
    local th = math.atan((v2 - math.sqrt(disc)) / (g * dh))
    return { hx * math.cos(th), math.sin(th), hz * math.cos(th) }, math.deg(th)
end

function M.Launch(caster, spell, claim, castAt)
    local def = data.spells[spell]
    if data.enabled == false or not def then return false, "not a projectile spell" end
    local weapon = def.impact_mode == "weapon"
    if weapon then
        if not PSpells.VisualReady(spell) then return false, "visual clone " .. PSpells.VisualId(spell) .. " not loaded" end
    elseif not PSpells.Ready(spell) then return false, "clones " .. PSpells.VisualId(spell) .. " / " .. PSpells.ImpactId(spell) .. " not loaded" end
    local eye = claim.eye and v3(claim.eye) or nil
    local dir = claim.dir and norm(v3(claim.dir)) or nil
    if not eye or not dir then
        -- Older client: aim from the caster toward the hit point.
        local okE, ce = pcall(Ext.Entity.Get, caster)
        local f = okE and ce and feetOf(ce)
        if not f or not claim.hitPoint then return false, "no aim line" end
        eye = { f[1], f[2] + 1.6 + Hitbox.Lift(caster), f[3] }
        dir = norm(sub(v3(claim.hitPoint), eye))
    end
    local origin = add(add(eye, dir, data.origin_fwd_m or 0.6), { 0, -1, 0 }, data.origin_down_m or 0.25)
    -- Aim the flight at the crosshair point, so the slight origin offset
    -- still converges on what the player aimed at.
    if claim.hitPoint then dir = norm(sub(v3(claim.hitPoint), origin)) end
    local tsp = templateSpeed(spell)
    local speed = tonumber(claim.speed) or (def.speed_mps == "template" and tsp.speed) or tonumber(def.speed_mps) or def.fallback_speed_mps or 25
    if speed <= 0 then speed = def.fallback_speed_mps or 25 end
    local gravity = tonumber(claim.gravity) or def.gravity or 0

    -- The visual clone flies to just past what you aimed at, at most
    -- visual_far_m (playtest 2026-10-12: a clone target 150 m out, often under
    -- the ground, sent BG3's in-fight spell camera halfway there at the cast:
    -- Fireball blacked out in fights).
    local farD = data.visual_far_m or 40
    if claim.hitPoint then
        local h = sub(v3(claim.hitPoint), origin)
        farD = math.min(farD, math.sqrt(h[1] * h[1] + h[2] * h[2] + h[3] * h[3]) + (data.visual_overshoot_m or 2))
    end
    local far = add(origin, dir, farD)
    -- The flight ends at the spell's range (data/projectiles.lua max_range_m:
    -- 70 m shots and arrows); an area spell (Fireball) at its area range, or
    -- just past the ring it was aimed at, + range_slack_m.
    local maxRange = data.max_range_m or 70
    if SpellRange.ClassOf(spell) == "area" then
        local r = SpellRange.RangeOf(spell) or maxRange
        if claim.hitPoint then r = math.max(r, len(sub(v3(claim.hitPoint), origin))) end
        maxRange = math.min(maxRange, r + (data.range_slack_m or 3))
    end
    local okV = castAt(caster, PSpells.VisualId(spell), { x = far[1], y = far[2], z = far[3] })
    local id = nextId; nextId = nextId + 1
    pending[caster] = {
        id = id, caster = caster, spell = spell, def = def, origin = origin, dir = dir, speed = speed, gravity = gravity,
        accel = tsp.accel or 0, at = now(), target = claim.targetUuid, visualCast = okV, npc = claim.npc,
        dmgMult = tonumber(claim.dmgMult), draw = tonumber(claim.draw), launchWait = tonumber(claim.launch_wait_s),
        maxRange = maxRange,
    }
    Log.Write(string.format("PROJ #%d launch %s: origin %s dir (%.3f,%.3f,%.3f) speed %.1f m/s accel %.1f gravity %.2f r %.2f m, range %.0f m%s, visual clone %s %s",
        id, spell, fmt(origin), dir[1], dir[2], dir[3], speed, tsp.accel or 0, gravity, def.radius_m or 0.15, maxRange,
        claim.draw and string.format(", draw %.0f %% (damage x%.2f)", claim.draw * 100, tonumber(claim.dmgMult) or 1) or "",
        PSpells.VisualId(spell), okV and ("cast at " .. fmt(far)) or "FAILED to cast"))
    return true
end

local function start(p, projEnt, why)
    pending[p.caster] = nil
    p.t0 = now()
    p.last = p.t0
    p.pos = { p.origin[1], p.origin[2], p.origin[3] }
    p.vel = { p.dir[1] * p.speed, p.dir[2] * p.speed, p.dir[3] * p.speed }
    p.traveled = 0
    p.proj = projEnt
    active[p.id] = p
    broadcast(Net.Channels.ProjectileLaunch, {
        id = p.id, caster = p.caster, spell = p.spell, origin = p.origin, vel = p.vel,
        gravity = p.gravity or p.def.gravity or 0, drag = p.def.drag or 0, accel = p.accel or 0,
        radius = p.def.radius_m or 0.15, maxT = (p.maxRange or data.max_range_m or 70) / math.max(1, p.speed),
    })
    Log.Write(string.format("PROJ #%d flight starts (%s)%s", p.id, why,
        p.srcPos and string.format(", BG3 projectile SourcePos %s is %.2f m from our origin", fmt(p.srcPos), len(sub(p.srcPos, p.origin))) or ""))
end

-- BG3's projectile for a pending launch: polled every tick while a launch
-- waits (the OnCreate subscription never matched in the 2026-10-12
-- playtest, so every flight started 1.2 s late). Each projectile entity is
-- looked at once; the first unreadable one logs why.
local seenProj = {}
local readErrLogged = false
local function pollProjectiles()
    if next(pending) == nil then return end
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerProjectile")
    if not ok or not ents then
        if not readErrLogged then readErrLogged = true; Log.Write("Projectiles: can not list ServerProjectile entities: " .. tostring(ents)) end
        return
    end
    for _, e in ipairs(ents) do
        local key = tostring(e)
        if not seenProj[key] then
            seenProj[key] = now()
            -- Round 3 (2026-10-12): Caster is empty on our script-cast visual
            -- clone ("attempt to index a nil value (field 'Caster')"), so every
            -- flight started 1.2 s late. Try Caster, Source, Owner; otherwise
            -- match the clone's spell id near our origin.
            local okC, info = pcall(function()
                local c = e.ServerProjectile
                local r = { spell = "?" }
                pcall(function() r.spell = tostring(c.Spell.Prototype or c.Spell.OriginatorPrototype) end)
                pcall(function() r.src = { c.SourcePos[1], c.SourcePos[2], c.SourcePos[3] } end)
                for _, f in ipairs({ "Caster", "Source" }) do
                    if not r.caster then pcall(function() r.caster = tostring(c[f].Uuid.EntityUuid) end) end
                end
                if not r.caster then pcall(function() r.caster = tostring(c.Owner.Uuid.EntityUuid) end) end
                return r
            end)
            if not okC then
                if not readErrLogged then readErrLogged = true; Log.Write("Projectiles: can not read a ServerProjectile: " .. tostring(info)) end
            else
                local p = info.caster and pending[info.caster] or nil
                local how = "caster"
                if not p and info.src then
                    for _, q in pairs(pending) do
                        if info.spell == PSpells.VisualId(q.spell) and len(sub(info.src, q.origin)) < (data.match_radius_m or 6) then
                            p, how = q, "spell + origin"
                            break
                        end
                    end
                end
                if p then
                    p.srcPos = info.src
                    start(p, e, string.format("BG3 projectile %s seen after %d ms, matched by %s", tostring(info.spell),
                        math.floor(now() - p.at), how))
                end
            end
        end
    end
    local t = now()
    for k, at in pairs(seenProj) do if t - at > 30000 then seenProj[k] = nil end end
end

-- BG3's projectile for a pending launch appeared.
local function onProjectileCreated(ent)
    Ext.OnNextTick(function()
        local ok, caster, src = pcall(function()
            local c = ent.ServerProjectile
            return tostring(c.Caster.Uuid.EntityUuid), { c.SourcePos[1], c.SourcePos[2], c.SourcePos[3] }
        end)
        if not ok or not caster then return end
        local p = pending[caster]
        if not p then return end
        p.srcPos = src
        start(p, ent, "BG3 projectile seen after " .. math.floor(now() - p.at) .. " ms")
    end)
end

-- ---------------------------------------------------------------------
-- Flight + hits
-- ---------------------------------------------------------------------
local function worldHit(a, b)
    local seg = sub(b, a)
    local L = len(seg)
    if L < 1e-4 then return nil end
    while worldSet <= #WORLD_SETS do
        local okR, hit = pcall(Ext.Level.RaycastClosest, a, b, "Static", WORLD_SETS[worldSet], {}, 1)
        if okR then
            if not M.raySetLogged then
                M.raySetLogged = true
                Log.Write("Projectiles: server world ray uses groups " .. table.concat(WORLD_SETS[worldSet], ","))
            end
            if not hit then return nil end
            local okD, raw = pcall(function() return hit.Distance end)
            raw = okD and tonumber(raw) or nil
            if not raw then return nil end
            return raw <= 1.0001 and raw * L or raw   -- Distance is a 0..1 fraction (spike 2)
        end
        Log.Write(string.format("Projectiles: server RaycastClosest groups %s rejected (%s)",
            table.concat(WORLD_SETS[worldSet], ","), tostring(hit)))
        worldSet = worldSet + 1
    end
    return nil
end

-- For other server systems (NpcCombat's swing line of sight / wall stop).
function M.WorldHit(a, b) return worldHit(a, b) end
-- Characters near the host: uuid -> { uuid, ent } (refreshed a slice per tick).
function M.Near() return near end
function M.FeetOf(e) return feetOf(e) end
function M.AliveOf(e) return aliveOf(e) end

-- Distance from point p to segment a-b (for candidate filtering).
local function segDist(p, a, b)
    local ab = sub(b, a)
    local t = 0
    local l2 = ab[1] * ab[1] + ab[2] * ab[2] + ab[3] * ab[3]
    if l2 > 1e-8 then t = math.max(0, math.min(1, ((p[1] - a[1]) * ab[1] + (p[2] - a[2]) * ab[2] + (p[3] - a[3]) * ab[3]) / l2)) end
    return len(sub(p, add(a, ab, t)))
end

local function charHit(p, a, b)
    local seg = sub(b, a)
    local L = len(seg)
    if L < 1e-4 then return nil end
    local dir = { seg[1] / L, seg[2] / L, seg[3] / L }
    local r = p.def.radius_m or 0.15
    local best, bestU, bestCyl, bestShield = nil, nil, nil, false
    local t = now()
    local pad = (data.candidate_pad_m or 3.0) + L
    local grace = (t - p.t0) / 1000 < (data.self_grace_s or 10)
    local n = 0
    for u, c in pairs(near) do
        if not (grace and u == p.caster) then
            local f = feetOf(c.ent)
            if f and segDist({ f[1], f[2] + 0.9, f[3] }, a, b) <= pad then
                n = n + 1
                if aliveOf(c.ent) then
                    local cyl = Hitbox.Cylinder(u, f)
                    -- Swept sphere vs cylinder = the segment vs the cylinder grown by r.
                    local big = { x = cyl.x, z = cyl.z, y0 = cyl.y0 - r, y1 = cyl.y1 + r, r = cyl.r + r }
                    local d = Hitbox.RayHit(big, a, dir, L)
                    -- The shield disc is tested before the body.
                    local ds = Shields.Has(u) and Shields.Blocks(u, a, b, r) or nil
                    local shielded = false
                    if ds and (not d or ds <= d + 0.05) then d, shielded = ds, true end
                    if d and (not best or d < best) then best, bestU, bestCyl, bestShield = d, u, cyl, shielded end
                    -- Closest approach (logged when the projectile misses).
                    local mid = { f[1], math.max(cyl.y0, math.min(cyl.y1, (a[2] + b[2]) / 2)), f[3] }
                    local gap = segDist(mid, a, b) - cyl.r - r
                    if not p.closest or gap < p.closest.gap then p.closest = { gap = gap, uuid = u } end
                end
            end
        end
    end
    if debugSteps then Log.Write(string.format("PROJ #%d step %s->%s: %d candidate(s)%s", p.id, fmt(a), fmt(b), n,
        bestU and (" hit " .. bestU .. (bestShield and " (shield)" or "")) or "")) end
    return best, bestU, bestCyl, bestShield
end

-- Osi.GetHitpoints returned -1 for spawned goblins (playtest 2026-10-12):
-- read the Health component instead.
local function hpOf(uuid)
    local ok, hp = pcall(function() return Ext.Entity.Get(uuid).Health.Hp end)
    if ok and tonumber(hp) then return tonumber(hp) end
    local okO, h2 = pcall(function() return Osi.GetHitpoints(uuid) end)
    return okO and tonumber(h2) or nil
end

-- A player-controlled character inside radius r of pos?
local function controlledNear(pos, r)
    for _, u in ipairs(Party.Members()) do
        if Party.IsControlled(u) then
            local c = near[u]
            local f = c and feetOf(c.ent)
            if f and len(sub({ f[1], f[2] + 0.9, f[3] }, pos)) <= r + 0.9 then return u end
        end
    end
    return nil
end

local function impact(p, pos, targetUuid, what, cyl, shielded)
    active[p.id] = nil
    -- BG3's projectile: gone at our hit.
    local removed = "no BG3 projectile matched"
    if p.proj then
        local ok = pcall(function() p.proj.ServerProjectile.RequestDelete = true end)
        removed = ok and "RequestDelete set" or "RequestDelete FAILED"
    end
    broadcast(Net.Channels.ProjectileHit, { id = p.id, pos = pos, target = targetUuid, what = what })
    if what == "expired" or what == "world" or what == "range" then
        local c = p.closest
        p.missNote = c and string.format(" (closest character %s passed %.2f m from its cylinder)", c.uuid, math.max(0, c.gap)) or
            " (no character near the path)"
    end
    if what == "expired" then
        Log.Write(string.format("PROJ #%d expired after %.1f m (no hit)%s; BG3 projectile: %s", p.id, p.traveled, p.missNote, removed))
        return
    end
    local mode = p.def.impact_mode or "target"
    local zone = (cyl and targetUuid) and Hitbox.Zone(cyl, pos[2]) or nil
    if mode == "weapon" then
        local how = "no weapon handler"
        if targetUuid and weaponHandler then
            local ok, r = pcall(weaponHandler, p, targetUuid, pos, zone or "torso", shielded)
            how = ok and tostring(r) or ("handler ERROR " .. tostring(r))
        elseif not targetUuid then
            how = "no character hit"
        end
        Log.Write(string.format("PROJ #%d HIT %s%s at %s after %.1f m / %.2f s%s%s: %s; BG3 projectile: %s%s", p.id, what,
            targetUuid and (" " .. targetUuid) or "", fmt(pos), p.traveled, (now() - p.t0) / 1000, zone and (" zone " .. zone) or "",
            shielded and " ON THE SHIELD" or "", how, removed, p.missNote or ""))
        return
    end
    local spellId = PSpells.ImpactId(p.spell)
    -- No hit reaction on a player-controlled target (DECISIONS 2026-10-12).
    local playerHit = nil
    if mode == "target" and targetUuid and Party.IsControlled(targetUuid) then playerHit = targetUuid end
    if not playerHit and (mode ~= "target" or not targetUuid) then
        local area = tonumber(p.def.area_m) or 0
        if area > 0 then playerHit = controlledNear(pos, area) end
    end
    if playerHit and PSpells.NoReactionReady(p.spell) then spellId = PSpells.NoReactionId(p.spell) end
    local level = casterLevel(p.caster)
    local hp0 = targetUuid and hpOf(targetUuid) or nil
    local how
    if mode == "target" and targetUuid then
        local ok, err = pcall(function() Osi.CreateExplosion(targetUuid, spellId, level, p.caster) end)
        how = "CreateExplosion(" .. targetUuid .. ") " .. (ok and "ok" or ("ERROR " .. tostring(err)))
    else
        local ok, err = pcall(function() Osi.CreateExplosionAtPosition(pos[1], pos[2], pos[3], spellId, level, p.caster) end)
        how = "CreateExplosionAtPosition " .. fmt(pos) .. " " .. (ok and "ok" or ("ERROR " .. tostring(err)))
    end
    Log.Write(string.format("PROJ #%d HIT %s%s at %s after %.1f m / %.2f s%s%s: impact %s lvl %d via %s%s; BG3 projectile: %s%s",
        p.id, what, targetUuid and (" " .. targetUuid) or "", fmt(pos), p.traveled, (now() - p.t0) / 1000,
        zone and (" zone " .. zone) or "", shielded and " ON THE SHIELD" or "", spellId, level, how,
        playerHit and (" (no hit reaction: " .. tostring(playerHit) .. ")") or "", removed, p.missNote or ""))
    if targetUuid and hp0 then
        local t1 = now() + 600
        local function check()
            if now() < t1 then Ext.OnNextTick(check); return end
            local hp1 = hpOf(targetUuid)
            Log.Write(string.format("PROJ #%d target HP %s -> %s%s", p.id, tostring(hp0), tostring(hp1),
                (hp1 and hp1 < hp0) and " (damage applied)" or " (NO damage seen)"))
            -- The shield's share of a spell impact: the clone can't be scaled
            -- before it lands, so that share is healed back (never revives).
            if shielded and hp1 and hp1 < hp0 and hp1 > 0 then
                local _, r = Shields.Reduce(hp0 - hp1)
                Damage.HealBack(targetUuid, (hp0 - hp1) * r, string.format("PROJ #%d hit the shield, %.0f %% of %d", p.id, r * 100, hp0 - hp1))
            end
        end
        Ext.OnNextTick(check)
    end
end

local function stepOne(p, dt)
    local g = p.gravity or p.def.gravity or 0
    local drag = p.def.drag or 0
    local a = p.pos
    local v = p.vel
    local sp = len(v)
    local acc = { 0, -g, 0 }
    if p.accel and p.accel ~= 0 and sp > 1e-3 then acc = add(acc, v, p.accel / sp) end
    if drag > 0 then acc = add(acc, v, -drag) end
    local nv = add(v, acc, dt)
    local b = add(a, nv, dt)
    local L = len(sub(b, a))
    local dw = worldHit(a, b)
    local dc, u, cyl, shielded = charHit(p, a, b)
    local dirN = norm(sub(b, a))
    if dc and (not dw or dc <= dw) then
        impact(p, add(a, dirN, dc), u, "character", cyl, shielded)
        return true
    elseif dw then
        impact(p, add(a, dirN, math.max(0, dw - (p.def.radius_m or 0.15))), nil, "world")
        return true
    end
    p.pos, p.vel = b, nv
    p.traveled = p.traveled + L
    -- Out of range: gone, or an area spell (burst_at_range) bursts there.
    if p.traveled >= (p.maxRange or data.max_range_m or 70) then impact(p, b, nil, p.def.burst_at_range and "range" or "expired"); return true end
    return false
end

local function tick()
    pcall(stepScan)
    local okP, errP = pcall(pollProjectiles)
    if not okP and not M.pollErrLogged then M.pollErrLogged = true; Log.Write("Projectiles: poll error " .. tostring(errP)) end
    local t = now()
    for caster, p in pairs(pending) do
        local wait = p.launchWait or p.def.launch_wait_s or data.launch_wait_s or 1.2
        if t - p.at > wait * 1000 then
            start(p, nil, string.format("no BG3 projectile seen within %.1f s", wait))
        end
    end
    for _, p in pairs(active) do
        local dt = math.min(0.25, (t - p.last) / 1000)
        p.last = t
        local step = data.step_s or (1 / 60)
        while dt > 1e-6 do
            local h = math.min(step, dt)
            dt = dt - h
            if stepOne(p, h) then break end
        end
    end
end

function M.Register()
    local okC = pcall(function()
        Ext.Entity.OnCreate("ServerProjectile", function(ent) pcall(onProjectileCreated, ent) end)
    end)
    Log.Write("Projectiles: OnCreate(ServerProjectile) " .. (okC and "subscribed" or "NOT available (flights start after launch_wait_s)"))
    local lastErr = -1e9
    Ext.Events.Tick:Subscribe(function()
        local ok, err = pcall(tick)
        if not ok and now() - lastErr > 3000 then lastErr = now(); Log.Write("Projectiles: tick error " .. tostring(err)) end
    end)
    Ext.RegisterConsoleCommand("dag_proj_debug", function(_, a)
        debugSteps = (a == "on")
        Log.Write("Projectiles: step debug " .. (debugSteps and "on" or "off"))
    end)
    Log.Write("Projectiles: registered (v1: our flight + swept hits, BG3 visual clone, impact clone)")
end

return M
