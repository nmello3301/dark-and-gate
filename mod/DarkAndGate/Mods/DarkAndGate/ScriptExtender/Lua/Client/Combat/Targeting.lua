-- SPDX-License-Identifier: GPL-3.0-or-later
-- Targeted and area spells while armed (DECISIONS 2026-10-12,
-- docs/design/interaction-and-world.md).
--
-- Targeted (a Target spell on characters, or AmountOfTargets > 1; not
-- teleports, not straight-line projectiles like Fire Bolt):
--   hover a valid character (LookAt: crosshair line + line of sight, within
--   the spell's TargetRadius) -> BG3's highlight circle under it;
--   LMB adds it (BG3's target circle under each pick, "n/3" over it);
--   at the max count the spell fires by itself once READY; the hotbar key
--   again fires early with fewer; RMB cancels. Picked targets that later
--   take cover are still hit (the server casts with IgnoreTargetChecks).
-- Area (AreaRadius > 0, Zone cones, Wall spells): BG3's own area ring at the
--   crosshair's world point, clamped to range, following it while armed;
--   walls as a row of rings along the view, cones as rings on their edges.
--   Hidden on cast / cancel. LMB releases as before, and the spell lands
--   where the ring is (M.AreaAim, Spells.Cast).
-- Ranges are the spell's first-person range (SpellDefs range_m, data/spells.lua:
-- 70 m shots, 30 m areas and multi-target spells like Sleep).

local Log       = Ext.Require("Shared/Log.lua")
local State     = Ext.Require("Client/Combat/State.lua")
local Aim       = Ext.Require("Client/Combat/Aim.lua")
local LookAt    = Ext.Require("Client/LookAt.lua")
local WorldFx   = Ext.Require("Client/WorldFx.lua")
local Overlay   = Ext.Require("Client/HUD/Overlay.lua")
local SpellDefs = Ext.Require("Shared/SpellDefs.lua")
local TickBudget = Ext.Require("Shared/TickBudget.lua")

local M = {}

local cur = nil        -- { spell, mode, max, range, picks = { uuid... }, counts, label, shape... }
local castFn = nil     -- fn(spell, targets) -> Spells.CastTargets (set by Spells to avoid a require cycle)
local readyFn = nil    -- fn(spell) -> seconds left
local lastAt = -1e9

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local function num(v, d) v = tonumber(tostring(v or "")); return v or d end

function M.SetCaster(cast, readyIn) castFn, readyFn = cast, readyIn end

local function classify(spell)
    local ok, st = pcall(Ext.Stats.Get, spell)
    if not ok or not st then return nil end
    local def = SpellDefs.Get(spell) or {}
    local stype = tostring(st.SpellType or "")
    local area = num(st.AreaRadius, 0)
    local amount = num(st.AmountOfTargets, 1)
    local c = { spell = spell, label = def.label or spell, range = def.range_m or num(st.TargetRadius, 18), picks = {}, counts = {} }
    if def.kind == "teleport" or def.kind == "self" then return nil end
    if stype == "Wall" then c.mode, c.shape, c.len, c.r = "area", "wall", num(st.MaxDistance, 9), math.max(0.5, num(st.SurfaceRadius, 1))
    elseif stype == "Zone" or stype == "Cone" then
        c.mode, c.shape, c.len, c.angle = "area", tostring(st.Shape) == "Square" and "square" or "cone", num(st.Range, 5), num(st.Angle, 60)
        c.base = num(st.Base, 5)
    elseif area > 0 and (stype == "Target" or stype == "Projectile" or stype == "ProjectileStrike") then
        c.mode, c.shape, c.r = "area", "circle", area
    elseif amount > 1 or stype == "Target" then
        c.mode, c.max = "targeted", math.max(1, amount)
    else
        return nil
    end
    return c
end

function M.Active() return cur ~= nil and cur.mode == "targeted" end
function M.Current() return cur end

local function clear(why)
    if not cur then return end
    WorldFx.ClearPrefix("tgt_")
    WorldFx.ClearPrefix("area")
    Overlay.Count(nil)
    Overlay.Markers(nil)
    Log.Write(string.format("Targeting: %s done (%s)%s", cur.label, why, cur.mode == "targeted" and string.format(", %d target(s) picked", #cur.picks) or ""))
    cur = nil
end
M.Clear = clear

local function hovered()
    local r = LookAt.Get()
    local c = r and r.character
    if not c or c.dist > cur.range + 0.5 then return nil end
    return c
end

local function fire(why)
    if not cur or #cur.picks == 0 then return false end
    local spell, picks = cur.spell, cur.picks
    Log.Write(string.format("Targeting: %s fires on %d target(s) (%s)", cur.label, #picks, why))
    clear("cast")
    State.armedSpell, State.armedAt = nil, nil
    if castFn then castFn(spell, picks) end
    return true
end

-- LMB while a targeted spell is armed: pick the hovered character.
function M.OnLMB()
    if not M.Active() then return false end
    local h = hovered()
    if not h then
        Log.Write("Targeting: LMB, no valid character under the crosshair (in range and in sight)")
        return true
    end
    if #cur.picks >= cur.max then return true end
    cur.picks[#cur.picks + 1] = h.uuid
    cur.counts[h.uuid] = (cur.counts[h.uuid] or 0) + 1
    local name = (LookAt.Info(h.uuid) or {}).name or h.uuid
    Log.Write(string.format("Targeting: %s picks %s (%d / %d, %.1f m)", cur.label, tostring(name), #cur.picks, cur.max, h.dist))
    return true
end

-- The same hotbar key again: fire early with what is picked (else disarm).
function M.OnSameSlot()
    if not M.Active() or #cur.picks == 0 then return false end
    if readyFn and readyFn(cur.spell) > 0 then
        Log.Write("Targeting: still casting, it fires by itself when READY")
        cur.early = true
        return true
    end
    return fire("hotbar key again: early")
end

-- Where an area spell lands for LookAt result r: the crosshair's world point,
-- pulled back to `range` along the view, dropped onto the ground under it.
local function areaPoint(r, range)
    local eye, fwd = r.eye, r.fwd
    local p = r.point
    if r.dist > range then p = { eye[1] + fwd[1] * range, eye[2] + fwd[2] * range, eye[3] + fwd[3] * range } end
    -- Snap to the ground under the point.
    local down = Aim.WorldRay({ p[1], p[2] + 0.5, p[3] }, { 0, -1, 0 }, 20)
    if down then p = { p[1], p[2] + 0.5 - down, p[3] } end
    return p
end

-- The ring's point for an area spell with a circle (Fireball, Grease, Fog
-- Cloud...) under the crosshair now, or nil for any other spell: the cast
-- goes where the ring shows (Spells.Cast). Also returns the eye it was seen from.
function M.AreaAim(spell)
    local c = (cur and cur.spell == spell and cur.mode) and cur or classify(spell)
    if not c or c.mode ~= "area" or c.shape ~= "circle" then return nil end
    local r = LookAt.Get()
    if not r or not r.point or not r.eye or not r.dist then return nil end
    return areaPoint(r, c.range), r.eye
end

local function drawArea(r)
    if not r then return end
    local fwd = r.fwd
    local p = areaPoint(r, cur.range)
    local fl = math.sqrt(fwd[1] * fwd[1] + fwd[3] * fwd[3])
    local hx, hz = fl > 1e-3 and fwd[1] / fl or 0, fl > 1e-3 and fwd[3] / fl or 1
    if cur.shape == "circle" then
        WorldFx.Ring("area", p, cur.r)
    elseif cur.shape == "wall" then
        local n = math.max(2, math.floor(cur.len / (cur.r * 1.5)))
        for i = 0, n do
            local s = (i / n - 0.5) * cur.len
            WorldFx.Ring("area" .. i, { p[1] - hz * s, p[2], p[3] + hx * s }, cur.r)
        end
    else
        local feet = Aim.SelfFeet() or p
        local half = math.rad((cur.angle or 60) / 2)
        local pts = {}
        for _, a in ipairs({ -half, -half / 2, 0, half / 2, half }) do
            local cx, cz = hx * math.cos(a) - hz * math.sin(a), hz * math.cos(a) + hx * math.sin(a)
            pts[#pts + 1] = { feet[1] + cx * cur.len, feet[2], feet[3] + cz * cur.len }
            pts[#pts + 1] = { feet[1] + cx * cur.len * 0.5, feet[2], feet[3] + cz * cur.len * 0.5 }
        end
        for i, q in ipairs(pts) do WorldFx.Ring("area" .. i, q, 0.6) end
    end
    if not cur.areaLogged then
        cur.areaLogged = true
        Log.Write(string.format("Targeting: %s area indicator (%s%s) at (%.1f,%.1f,%.1f), range %.0f m", cur.label, cur.shape,
            cur.r and string.format(" r %.1f m", cur.r) or string.format(" %.0f m", cur.len or 0), p[1], p[2], p[3], cur.range))
    end
end

local function tick()
    local t = now()
    if t - lastAt < 66 then return end
    lastAt = t
    local armed = State.armedSpell
    if cur and cur.spell ~= armed then clear(armed and "re-armed" or "cast / cancelled") end
    if not armed or not State.IsCombatActive() or State.uiPaused then return end
    if not cur then
        cur = classify(armed)
        if cur then
            Log.Write(string.format("Targeting: %s armed -> %s%s", cur.label, cur.mode,
                cur.mode == "targeted" and string.format(" (up to %d targets, range %.0f m: LMB picks, the key again fires early)", cur.max, cur.range) or ""))
        else
            cur = { spell = armed, mode = "none", picks = {} }
        end
    end
    if cur.mode == "area" then drawArea(LookAt.Get()); return end
    if cur.mode ~= "targeted" then return end
    local h = hovered()
    if h and h.ent then WorldFx.OnEntity("tgt_hover", "hover", h.ent) else WorldFx.Clear("tgt_hover") end
    local marks = {}
    for u, n in pairs(cur.counts) do
        local e = LookAt.Entity(u)
        if e then
            WorldFx.OnEntity("tgt_" .. u, "target", e)
            local ok, tr = pcall(function() return e.Transform.Transform.Translate end)
            if ok and tr then marks[#marks + 1] = { pos = { tr[1], tr[2] + 2.1, tr[3] }, text = n > 1 and (n .. "x") or "[x]" } end
        end
    end
    Overlay.Markers(marks)
    Overlay.Count(string.format("%s  %d / %d   LMB: pick   key again: cast now", cur.label, #cur.picks, cur.max))
    local left = readyFn and readyFn(cur.spell) or 0
    if #cur.picks >= cur.max and left <= 0 then fire("max targets, READY")
    elseif cur.early and #cur.picks > 0 and left <= 0 then fire("hotbar key again: early, now READY") end
end

function M.Register()
    Ext.Events.Tick:Subscribe(TickBudget.Wrap("Targeting", tick))
    Log.Write("Targeting: registered (targeted spells: LMB picks; area spells: BG3's ring at the crosshair)")
end

return M
