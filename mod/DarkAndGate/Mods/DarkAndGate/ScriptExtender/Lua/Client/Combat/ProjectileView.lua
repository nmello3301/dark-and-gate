-- SPDX-License-Identifier: GPL-3.0-or-later
-- Client side of the projectile system (Server/Combat/Projectiles.lua).
-- PROBE for the visual (docs/spikes/projectiles.md, risks 4-5): on each
-- ProjectileLaunch, find BG3's client-side projectile entity, log what it
-- is, measure how far its drawn position drifts from our flight, and (with
-- data/projectiles.lua client_steer) move its Visual onto our path every
-- tick with Lua SetWorldTranslate. The DLL route (VisualLift-style hook)
-- follows only if this probe shows the visual can be found but fights back.
-- On ProjectileHit the steering stops (the server removed the projectile).

local Log  = Ext.Require("Shared/Log.lua")
local Net  = Ext.Require("Shared/Net.lua")
local data = Ext.Require("data/projectiles.lua")

local M = {}

local flights = {}   -- id -> { p (launch), t0, ent, comp, steer, lastDrift, misses }
local CANDIDATE_COMPONENTS = { "ProjectileSource", "ClientProjectile", "Projectile" }

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local function fmt(p) return string.format("(%.2f,%.2f,%.2f)", p[1], p[2], p[3]) end

-- Our flight at time t (s) after launch, same kinematics as the server.
local function simAt(f, t)
    local p = f.p
    local g, accel = tonumber(p.gravity) or 0, tonumber(p.accel) or 0
    local o, v = p.origin, p.vel
    local sp = math.sqrt(v[1] ^ 2 + v[2] ^ 2 + v[3] ^ 2)
    local k = sp > 1e-3 and (accel / sp) or 0
    local s = t + 0.5 * k * t * t   -- distance factor along v with constant acceleration
    return { o[1] + v[1] * s, o[2] + v[2] * s - 0.5 * g * t * t, o[3] + v[3] * s }
end

local function translateOf(ent)
    local ok, t = pcall(function() return ent.Transform.Transform.Translate end)
    return ok and t and { t[1], t[2], t[3] } or nil
end

local seen = {}   -- entity handles we already matched (string)
local function findClientProjectile(f)
    for _, comp in ipairs(CANDIDATE_COMPONENTS) do
        local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, comp)
        if ok and ents then
            local best, bestD = nil, 1e9
            for _, e in ipairs(ents) do
                local key = tostring(e)
                if not seen[key] then
                    local pos = translateOf(e)
                    local d = pos and math.sqrt((pos[1] - f.p.origin[1]) ^ 2 + (pos[2] - f.p.origin[2]) ^ 2 + (pos[3] - f.p.origin[3]) ^ 2) or 99
                    if d < bestD then best, bestD = e, d end
                end
            end
            if best and bestD < 8 then
                seen[tostring(best)] = true
                return best, comp, bestD
            end
        end
    end
    return nil
end

local function componentNames(e)
    local ok, names = pcall(function() return e:GetAllComponentNames() end)
    if not ok or not names then return "?" end
    table.sort(names)
    return table.concat(names, ",")
end

local function tick()
    local t = now()
    for id, f in pairs(flights) do
        local el = (t - f.t0) / 1000
        if el > (tonumber(f.p.maxT) or 6) + 1 then
            flights[id] = nil
        else
            if not f.ent and el < 1.5 then
                local e, comp, d = findClientProjectile(f)
                if e then
                    f.ent, f.comp = e, comp
                    Log.Write(string.format("ProjView #%d: client projectile FOUND via %s, %.2f m from our origin; components: %s",
                        id, comp, d, componentNames(e)))
                end
            elseif not f.ent and not f.reportedMissing then
                f.reportedMissing = true
                Log.Write(string.format("ProjView #%d: client projectile NOT found (tried %s) -> no steering; BG3 flies its own path",
                    id, table.concat(CANDIDATE_COMPONENTS, ", ")))
            end
            if f.ent then
                local sim = simAt(f, el)
                local cur = translateOf(f.ent)
                if cur and t - (f.lastDrift or 0) > 250 then
                    f.lastDrift = t
                    local d = math.sqrt((cur[1] - sim[1]) ^ 2 + (cur[2] - sim[2]) ^ 2 + (cur[3] - sim[3]) ^ 2)
                    f.maxDrift = math.max(f.maxDrift or 0, d)
                    if (f.driftLogs or 0) < 6 then
                        f.driftLogs = (f.driftLogs or 0) + 1
                        Log.Write(string.format("ProjView #%d: t=%.2fs BG3 visual at %s, our flight at %s, drift %.2f m%s", id, el,
                            fmt(cur), fmt(sim), d, f.steer and " (steered last tick)" or ""))
                    end
                end
                if data.client_steer then
                    local ok = pcall(function() f.ent.Visual.Visual:SetWorldTranslate(sim) end)
                    if f.steer == nil then
                        Log.Write(string.format("ProjView #%d: steering via Visual:SetWorldTranslate %s", id, ok and "works (call accepted)" or "FAILED"))
                    end
                    f.steer = ok
                end
            end
        end
    end
end

function M.Register()
    Ext.RegisterNetListener(Net.Channels.ProjectileLaunch, function(_, payload)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or not p then return end
        flights[p.id] = { p = p, t0 = now() }
        Log.Write(string.format("ProjView #%d: launch %s from %s, %.1f m/s", p.id, tostring(p.spell), fmt(p.origin),
            math.sqrt(p.vel[1] ^ 2 + p.vel[2] ^ 2 + p.vel[3] ^ 2)))
    end)
    Ext.RegisterNetListener(Net.Channels.ProjectileHit, function(_, payload)
        local ok, h = pcall(Ext.Json.Parse, payload)
        if not ok or not h then return end
        local f = flights[h.id]
        flights[h.id] = nil
        Log.Write(string.format("ProjView #%d: %s at %s%s%s", h.id, tostring(h.what), h.pos and fmt(h.pos) or "?",
            h.target and (" " .. h.target) or "", f and f.maxDrift and string.format(" (max visual drift %.2f m)", f.maxDrift) or ""))
    end)
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
    Log.Write("ProjView: registered (client projectile probe, steer " .. tostring(data.client_steer) .. ")")
end

return M
