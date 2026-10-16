-- SPDX-License-Identifier: GPL-3.0-or-later
-- Bows and crossbows, server side (DECISIONS 2026-10-12, data/bows.lua,
-- docs/design/projectiles.md).
--
-- The player (Client/Combat/Bow.lua):
--   BowDraw { on = true }    LMB went down with a bow in hand: the server
--                            notes the time (its clock checks the draw), gets
--                            the bow out if it is on the back, and tells the
--                            other clients to show the draw (BowAnim).
--   BowRelease { eye, dir, hitPoint, targetUuid?, draw }
--                            the draw fraction is capped by the server's own
--                            clock; below min_draw there is no shot. The arrow
--                            flies through the projectile system (our flight
--                            with drop, BG3's arrow as the look; at our hit the
--                            ranged weapon's dice x the draw's damage).
--   crossbows                no draw: a release right away, then reload_s.
--   WeaponSetToggle { from } Q's check: BG3's own toggle key was pressed on
--                            the client; if the set is still `from` check_s
--                            later, the server switches it itself.
-- RangedState { uuid, set, kind, family, drawS, reloadS } goes out whenever a
-- party member's weapon set or ranged weapon changes (the client decides
-- with it whether LMB draws or swings).
-- NPC / companion archers (Server/Combat/NpcCombat.lua) use Family, Shot,
-- DrawTime and Anim.
--
--   !dag_bow_draw <s>   the base draw time for the session (data: draw_s)

local Log            = Ext.Require("Shared/Log.lua")
local Net            = Ext.Require("Shared/Net.lua")
local TickBudget     = Ext.Require("Shared/TickBudget.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")
local Party          = Ext.Require("Server/Party.lua")
local Projectiles    = Ext.Require("Server/Combat/Projectiles.lua")
local SpellCast      = Ext.Require("Server/Combat/SpellCast.lua")
local cfg            = Ext.Require("data/bows.lua")
local MetaPoints     = Ext.Require("Shared/MetaPoints.lua")

local M = {}

local ARROW = cfg.arrow_spell
local famCache = {}    -- uuid -> { info, at }
local draws = {}       -- uuid -> { at = ms }
local lastShot = {}    -- uuid -> ms
local empty = {}       -- uuid -> true after a crossbow shot, until reloaded
local reloadAt = {}    -- uuid -> ms the crossbow reload started (R)
local pushed = {}      -- uuid -> last RangedState json
local pushAt = -1e9

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function name(uuid)
    local ok, n = pcall(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(uuid)) end)
    return (ok and n and n ~= "") and n or tostring(uuid)
end

-- A stats flags value (table of names, or "A;B") contains `flag`?
local function hasFlag(v, flag)
    if v == nil then return false end
    if type(v) == "string" then
        for part in v:gmatch("[^;%s]+") do if part == flag then return true end end
        return false
    end
    local found = false
    pcall(function() for _, x in ipairs(v) do if tostring(x) == flag then found = true end end end)
    if not found then pcall(function() found = tostring(v):find(flag, 1, true) ~= nil end) end
    return found
end

-- ---------------------------------------------------------------------
-- The ranged weapon and the shot
-- ---------------------------------------------------------------------
-- { kind = "bow"|"crossbow", family, speed, reloadS, statsId } or nil.
function M.Family(uuid)
    uuid = Party.Norm(uuid)
    if not uuid then return nil end
    local t = now()
    local c = famCache[uuid]
    if c and t - c.at < 3000 then return c.info end
    local info = nil
    pcall(function()
        local item = Osi.GetEquippedItem(uuid, "Ranged Main Weapon")
        if not item or item == "" then return end
        local statsId = tostring(Ext.Entity.Get(item).Data.StatsId)
        local st = Ext.Stats.Get(statsId)
        local groups = st and st["Proficiency Group"]
        local famName = nil
        for f in pairs(cfg.families) do
            if hasFlag(groups, f) then famName = f; break end
        end
        famName = famName or cfg.default_family
        local f = cfg.families[famName] or {}
        info = { kind = f.kind or "bow", family = famName, speed = f.speed_mps or 55, reloadS = f.reload_s or 0, statsId = statsId }
    end)
    famCache[uuid] = { info = info, at = t }
    return info
end

-- The draw time: a party member's STR curve on top (Meta-Points bow_draw),
-- floored at min_action_interval; everyone else the data value.
function M.DrawTime(uuid)
    local u = Party.Norm(uuid)
    if u and Party.IsMember(u) then return MetaPoints.Floor(cfg.draw_s * MetaPoints.Mult(u, "bow_draw")) end
    return cfg.draw_s
end

-- Speed / gravity / damage of a shot at `draw` (0..1).
function M.Shot(uuid, draw)
    local fam = M.Family(uuid) or { family = cfg.default_family, kind = "bow",
        speed = (cfg.families[cfg.default_family] or {}).speed_mps or 55 }
    draw = math.max(0, math.min(1, tonumber(draw) or 1))
    local span = 1 - (cfg.min_draw or 0)
    local k = span > 0 and math.max(0, math.min(1, (draw - (cfg.min_draw or 0)) / span)) or 1
    if fam.kind == "crossbow" then k = 1 end
    return {
        speed   = fam.speed * ((cfg.speed_at_min or 1) + (1 - (cfg.speed_at_min or 1)) * k),
        gravity = cfg.gravity_mps2 or 0,
        dmgMult = (cfg.damage_at_min or 1) + (1 - (cfg.damage_at_min or 1)) * k,
        family  = fam.family,
        kind    = fam.kind,
    }
end

-- Every client but `exclude`'s shows (or ends) the draw on `uuid`.
function M.Anim(uuid, phase, drawS, exclude)
    local msg = Ext.Json.Stringify({ uuid = uuid, phase = phase, drawS = drawS })
    local ok = pcall(function()
        if exclude then Ext.Net.BroadcastMessage(Net.Channels.BowAnim, msg, exclude) else Ext.Net.BroadcastMessage(Net.Channels.BowAnim, msg) end
    end)
    if not ok then pcall(function() Ext.ServerNet.BroadcastMessage(Net.Channels.BowAnim, msg) end) end
end

-- ---------------------------------------------------------------------
-- Weapon set
-- ---------------------------------------------------------------------
local function weaponSet(uuid)
    local ok, s = pcall(function() return tostring(Ext.Entity.Get(uuid).WeaponSet.WeaponSet) end)
    return ok and s or nil
end

local function unsheath(uuid)
    local ok, s = pcall(function() return tostring(Ext.Entity.Get(uuid).Unsheath.State) end)
    return ok and s or "?"
end

local function pushStates(force)
    local t = now()
    if not force and t - pushAt < 500 then return end
    pushAt = t
    for _, u in ipairs(Party.Members()) do
        local fam = M.Family(u)
        local p = { uuid = u, set = weaponSet(u) or "?", kind = fam and fam.kind or nil, family = fam and fam.family or nil,
            drawS = M.DrawTime(u), reloadS = fam and fam.reloadS or 0 }
        local js = Ext.Json.Stringify(p)
        if pushed[u] ~= js then
            pushed[u] = js
            pcall(function() Ext.Net.BroadcastMessage(Net.Channels.RangedState, js) end)
            if Party.IsControlled(u) then
                Log.Write(string.format("Bows: %s weapon set %s, ranged weapon %s%s", name(u), p.set,
                    fam and string.format("%s (%s, %.0f m/s)", fam.family, fam.kind, fam.speed) or "none",
                    fam and fam.kind == "bow" and string.format(", draw %.1f s", p.drawS) or
                    (fam and fam.kind == "crossbow" and string.format(", reload %.1f s", fam.reloadS) or "")))
            end
        end
    end
end

-- Q's fallback: BG3's own toggle didn't switch the set, so we do.
local function toggleSet(u, from)
    local cur = weaponSet(u)
    if cur and from and cur ~= from then
        Log.Write(string.format("Bows: %s's weapon set is %s now (BG3's toggle key worked)", name(u), cur))
        famCache[u] = nil
        pushStates(true)
        return
    end
    local want = (cur == "Ranged") and "Melee" or "Ranged"
    local okW, errW = pcall(function()
        local e = Ext.Entity.Get(u)
        e.WeaponSet.WeaponSet = want
        e:Replicate("WeaponSet")
    end)
    pcall(function() Osi.SetWeaponUnsheathed(u, 1, 0) end)
    Log.Write(string.format("Bows: %s's weapon set still %s after BG3's toggle key -> the server switches it to %s (%s)", name(u),
        tostring(cur), want, okW and "WeaponSet written + replicated, weapon drawn" or ("write FAILED: " .. tostring(errW))))
    Ext.Timer.WaitFor(700, function()
        Log.Write(string.format("Bows: %s weapon set now %s, stance %s", name(u), tostring(weaponSet(u)), unsheath(u)))
        famCache[u] = nil
        pushStates(true)
    end)
end

-- ---------------------------------------------------------------------
-- The player's shots
-- ---------------------------------------------------------------------
local function release(peer, p)
    local u = Party.CharacterOfPeer(peer)
    if not u then return end
    local fam = M.Family(u)
    if not fam then
        Log.Write("Bows: release REFUSED (" .. name(u) .. " has no ranged weapon equipped)")
        return
    end
    local t = now()
    local draw = 1
    if fam.kind == "crossbow" then
        if empty[u] then
            local r = reloadAt[u]
            if not r or (t - r) / 1000 < fam.reloadS - (cfg.release_tolerance_s or 0) then
                Log.Write(string.format("Bows: %s's crossbow isn't loaded (%s)", name(u),
                    r and string.format("reloading, %.1f of %.1f s", (t - r) / 1000, fam.reloadS) or "R to reload"))
                return
            end
        end
        empty[u], reloadAt[u] = true, nil
    else
        local d = draws[u]
        draws[u] = nil
        if not d then
            Log.Write("Bows: release REFUSED (" .. name(u) .. ": no draw started)")
            return
        end
        local drawS = M.DrawTime(u)
        local fServer = drawS > 1e-3 and math.min(1, ((t - d.at) / 1000 + (cfg.release_tolerance_s or 0)) / drawS) or 1
        draw = math.min(tonumber(p.draw) or fServer, fServer)
        if draw < (cfg.min_draw or 0) then
            Log.Write(string.format("Bows: %s let go at %.0f %% (< %.0f %%): no shot", name(u), draw * 100, (cfg.min_draw or 0) * 100))
            M.Anim(u, "cancel", 0, u)
            return
        end
    end
    local shot = M.Shot(u, draw)
    local claim = { eye = p.eye, dir = p.dir, hitPoint = p.hitPoint, targetUuid = p.targetUuid,
        speed = shot.speed, gravity = shot.gravity, dmgMult = shot.dmgMult, draw = draw }
    local ok, why = Projectiles.Launch(u, ARROW, claim, function(c, id, pos) return SpellCast.CastAtPosition(c, id, pos) end)
    lastShot[u] = t
    M.Anim(u, "release", 0, u)
    Log.Write(string.format("Bows: %s shoots (%s %s, draw %.0f %%): %.0f m/s, damage x%.2f, drop %.2f m/s2%s", name(u), fam.family, fam.kind,
        draw * 100, shot.speed, shot.dmgMult, shot.gravity, ok and "" or (" -- NOT launched: " .. tostring(why))))
end

-- ---------------------------------------------------------------------
-- Register
-- ---------------------------------------------------------------------
local function tick() pushStates(false) end

function M.Register()
    Ext.RegisterNetListener(Net.Channels.BowDraw, function(_, payload, peer)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" then return end
        Ext.OnNextTick(function()
            local u = Party.CharacterOfPeer(peer)
            if not u then return end
            if p.reload then
                reloadAt[u] = now()
                Log.Write(string.format("Bows: %s reloads the crossbow", name(u)))
                return
            end
            if p.on then
                local fam = M.Family(u)
                if not fam or fam.kind ~= "bow" then
                    Log.Write("Bows: draw REFUSED (" .. name(u) .. " has no bow in the ranged slot)")
                    return
                end
                draws[u] = { at = now() }
                -- The bow off the back, without its draw-from-back clip (ours plays).
                pcall(function() if tonumber(Osi.IsWeaponUnsheathed(u)) ~= 1 then Osi.SetWeaponUnsheathed(u, 1, 1) end end)
                M.Anim(u, "draw", M.DrawTime(u), u)
                Log.Write(string.format("Bows: %s draws (%s, %.1f s to full draw; set %s, stance %s)", name(u), fam.family, M.DrawTime(u),
                    tostring(weaponSet(u)), unsheath(u)))
            elseif draws[u] then
                draws[u] = nil
                M.Anim(u, "cancel", 0, u)
                Log.Write(string.format("Bows: %s's draw cancelled (%s)", name(u), tostring(p.why)))
            end
        end)
    end)
    Ext.RegisterNetListener(Net.Channels.BowRelease, function(_, payload, peer)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" then return end
        Ext.OnNextTick(function()
            local okR, err = pcall(release, peer, p)
            if not okR then Log.Write("Bows: release error " .. tostring(err)) end
        end)
    end)
    Ext.RegisterNetListener(Net.Channels.WeaponSetToggle, function(_, payload, peer)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" then p = {} end
        Ext.OnNextTick(function()
            local u = Party.CharacterOfPeer(peer)
            if not u then return end
            Log.Write(string.format("Bows: Q by %s (set %s on the client; BG3's toggle key %s)", name(u), tostring(p.from),
                p.injected and "pressed" or "NOT pressed"))
            Ext.Timer.WaitFor(math.floor((cfg.weapon_set.check_s or 0.8) * 1000), function()
                local okT, err = pcall(toggleSet, u, p.from)
                if not okT then Log.Write("Bows: weapon set switch error " .. tostring(err)) end
            end)
        end)
    end)
    Ext.Events.Tick:Subscribe(TickBudget.Wrap("Bows", tick))
    ConsoleForward.Server("dag_bow_draw", function(_, v)
        if tonumber(v) then cfg.draw_s = math.max(0.2, tonumber(v)) end
        Log.Write(string.format("Bows: draw time %.1f s (players and NPC archers; no shot below %.0f %%)", cfg.draw_s, (cfg.min_draw or 0) * 100))
        pushed = {}
    end)
    Log.Write(string.format("Bows: registered (draw %.1f s, min %.0f %%, drop %.2f m/s2; Q switches melee / ranged)", cfg.draw_s,
        (cfg.min_draw or 0) * 100, cfg.gravity_mps2 or 0))
end

return M
