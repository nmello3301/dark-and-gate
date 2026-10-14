-- SPDX-License-Identifier: GPL-3.0-or-later
-- Client-side spell cast flow for M1b.
--
-- On key press (via Hotbar.PressSlot):
--   1. Resolve the spell id for the slot.
--   2. Fire crosshair aim ray to find a target or hit point.
--   3. Send CastSpellRequest with withMana=true + spell + aim.
-- Server validates mana and routes to Osi.UseSpell / UseSpellAtPosition.
-- Returns true when the request was sent.
--
-- The cast is an action (Client/Combat/Actions.lua) for air_action.cast_s,
-- extended while the player still has SpellCastIsCasting: the jump clips
-- wait for it. The spell prepare loop (Prepare.lua) hands over here.

local Log       = Ext.Require("Shared/Log.lua")
local Net       = Ext.Require("Shared/Net.lua")
local State     = Ext.Require("Client/Combat/State.lua")
local Aim       = Ext.Require("Client/Combat/Aim.lua")
local ClientNet = Ext.Require("Client/Net.lua")
local spells    = Ext.Require("data/spells.lua")
local SpellDefs = Ext.Require("Shared/SpellDefs.lua")
local Actions   = Ext.Require("Client/Combat/Actions.lua")
local Prepare   = Ext.Require("Client/Combat/Prepare.lua")
local airAction = Ext.Require("data/movement.lua").air_action
local Movement  = Ext.Require("Client/Movement/Movement.lua")
local Targeting = Ext.Require("Client/Combat/Targeting.lua")
local Me = Ext.Require("Client/Me.lua")   -- the local player's character (multiplayer)

local M = {}

local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) end

function M.Cast(spellId)
    local def = SpellDefs.Get(spellId)
    if not def then
        Log.Write("Spells: unknown id " .. tostring(spellId)); return
    end
    local cd = State.cooldownUntil[spellId] or 0
    if nowMs() < cd then return end

    local kind = def.kind or "target"
    local far = def.unlimited_range
    -- The spell's first-person range (data/spells.lua: 70 m shots, 30 m
    -- areas and multi-target spells; Shared/SpellRange.lua).
    local range = def.range_m or 30.0

    -- Shooting spells: straight down the crosshair line, nothing else
    -- (Aim.SpellAim). A character on the line is the target; otherwise the
    -- world point or the far point along the line, at most `range` away.
    local straight = far and kind ~= "self" and Aim.SpellAim(range) or nil

    local payload = {
        withMana = true,
        spell    = spellId,
    }

    -- fix3: a "target" spell (Fire Bolt) prefers the character under the
    -- crosshair (6 degree aim assist) and otherwise flies at the ground /
    -- object point under the crosshair, like vanilla BG3 lets you do.
    -- "point" / "teleport" spells (Fireball, Misty Step) always use the
    -- ground point. GroundPoint never fails while the camera is readable.
    if kind == "self" then
        payload.targetUuid = "__self__"
    elseif far then
        if not straight then
            Log.Write("Spells: camera not readable -- aborting " .. spellId)
            return
        end
        local p = straight.pos
        -- An area spell (Fireball) with nothing on the line within its range
        -- lands where its ring shows: pulled back to the range, on the ground.
        if straight.via == "far" then
            local ap = Targeting.AreaAim(spellId)
            if ap then p = ap; straight.via = "far -> ring" end
        end
        if straight.target and kind == "target" then payload.targetUuid = straight.target end
        payload.hitPoint = { x = p[1], y = p[2], z = p[3] }
        -- The aim line itself (projectile system: the server flies the
        -- projectile from the eye along it; also right in mid-air).
        payload.eye = { x = straight.eye[1], y = straight.eye[2], z = straight.eye[3] }
        payload.dir = { x = straight.fwd[1], y = straight.fwd[2], z = straight.fwd[3] }
        Log.Write(string.format("Spells: %s aim %s %.1f m at (%.2f,%.2f,%.2f) from eye (%.2f,%.2f,%.2f) dir (%.3f,%.3f,%.3f)%s",
            spellId, straight.via, straight.distance, p[1], p[2], p[3],
            straight.eye[1], straight.eye[2], straight.eye[3], straight.fwd[1], straight.fwd[2], straight.fwd[3],
            straight.target and (" target " .. straight.target) or ""))
    else
        local t = (kind == "target") and Aim.TargetAtCrosshair(range) or nil
        if t then
            payload.targetUuid = t.target
            payload.hitPoint   = { x = t.pos[1], y = t.pos[2], z = t.pos[3] }
            Log.Write(string.format("Spells: %s -> character %s at %.1f m", spellId, t.target, t.distance or 0))
        else
            local pos, dist, via
            -- An area spell lands where its ring shows (Targeting.AreaAim).
            local ap, eye = Targeting.AreaAim(spellId)
            if ap then
                pos, via = ap, "ring"
                dist = eye and math.sqrt((ap[1] - eye[1]) ^ 2 + (ap[2] - eye[2]) ^ 2 + (ap[3] - eye[3]) ^ 2) or nil
            elseif far then pos, dist, via = Aim.AimPoint(range) else pos, dist, via = Aim.GroundPoint(range) end
            if not pos then
                Log.Write("Spells: camera not readable -- aborting " .. spellId)
                return
            end
            payload.hitPoint = { x = pos[1], y = pos[2], z = pos[3] }
            Log.Write(string.format("Spells: %s -> ground (%.2f,%.2f,%.2f) %.1f m via %s",
                spellId, pos[1], pos[2], pos[3], dist or 0, tostring(via)))
        end
    end

    -- Only after we're committed to firing: eat the cooldown.
    State.cooldownUntil[spellId] = nowMs() + (def.cooldown_ms or 400)
    State.lastCastAt = nowMs()   -- the HUD cast bar: released, not cancelled
    Actions.Begin("cast", airAction.cast_s)
    Prepare.Stop("cast")
    ClientNet.Send(Net.Channels.CastSpellRequest, payload)
    Log.Write(string.format("Spells: request %s (%s) target=%s point=%s",
        spellId, def.label or kind,
        tostring(payload.targetUuid),
        payload.hitPoint and string.format("(%.2f,%.2f,%.2f)", payload.hitPoint.x, payload.hitPoint.y, payload.hitPoint.z) or "nil"))
    return true
end

-- Targeted spells (Client/Combat/Targeting.lua): the picked characters, all
-- at once. The server casts with IgnoreTargetChecks, so a picked target
-- that took cover since is still hit.
function M.CastTargets(spellId, targets)
    local def = SpellDefs.Get(spellId)
    if not def or not targets or #targets == 0 then return false end
    State.cooldownUntil[spellId] = nowMs() + (def.cooldown_ms or 400)
    State.lastCastAt = nowMs()
    Actions.Begin("cast", airAction.cast_s)
    Prepare.Stop("cast")
    ClientNet.Send(Net.Channels.CastSpellRequest, { withMana = true, spell = spellId, targets = targets, targetUuid = targets[1] })
    Log.Write(string.format("Spells: request %s on %d picked target(s): %s", spellId, #targets, table.concat(targets, ", ")))
    return true
end

-- Channelled casting. Cast time = base (data/spells.lua base_cast_s, per
-- spell override, or !dag_cast_time) x the product of the modifiers.
local castMods = {}
local baseOverride = nil
function M.AddCastTimeModifier(id, fn) castMods[id] = fn; Log.Write("Spells: cast-time modifier added " .. tostring(id)) end
function M.RemoveCastTimeModifier(id) castMods[id] = nil end
function M.CastTime(spellId)
    local def = SpellDefs.Get(spellId)
    local t = baseOverride or (def and (def.base_cast_s or def.cast_time_s)) or spells.base_cast_s or spells.cast_time_s or 0
    for id, fn in pairs(castMods) do
        local ok, f = pcall(fn, spellId)
        if ok and type(f) == "number" and f > 0 then t = t * f end
    end
    return t
end
-- Seconds until the armed spell may be released (0 = ready). armedAt
-- comes from Hotbar.PressSlot; the cast time is fixed at arm time.
function M.ReadyIn(spellId)
    if not State.armedAt then return 0 end
    local left = (State.armedCastTime or M.CastTime(spellId)) - (nowMs() - State.armedAt) / 1000
    return left > 0 and left or 0
end

-- Keep the "cast" action alive while the engine still casts. Whether the
-- client sees SpellCastIsCasting on the player is logged once.
local castProbeLogged = false
local function tick()
    if not Actions.Running("cast") then return end
    local okE, ents = pcall(Me.All)
    local me = okE and ents and ents[1] or nil
    if not me then return end
    local okC, c = pcall(function() return me.SpellCastIsCasting end)
    local casting = okC and c ~= nil
    if not castProbeLogged and casting then
        castProbeLogged = true
        Log.Write("Spells: SpellCastIsCasting is visible on the client -> the cast action lasts as long as the cast")
    end
    if casting then Actions.Extend("cast", nowMs() + 100) end
end

function M.Register()
    Targeting.SetCaster(M.CastTargets, M.ReadyIn)
    Targeting.Register()
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
    Ext.RegisterConsoleCommand("dag_cast_time", function(_, s)
        local v = tonumber(s)
        baseOverride = (v and v > 0) and v or nil
        Log.Write(string.format("Spells: base cast time = %s (Fire Bolt now %.2fs)",
            baseOverride and string.format("%.2fs (override)", baseOverride) or "data", M.CastTime("Projectile_FireBolt")))
    end)
    -- Casting slows the caster on the ground (data/spells.lua
    -- casting_speed_mult); ready-to-release and airborne are full speed.
    local wasSlowed = false
    Movement.AddModifier("casting", function()
        local slowed = State.armedSpell ~= nil and M.ReadyIn(State.armedSpell) > 0 and not State.jumping
        if slowed ~= wasSlowed then
            wasSlowed = slowed
            Log.Write(string.format("Spells: casting slow %s (x%.2f)", slowed and "ON" or "off", spells.casting_speed_mult or 1))
        end
        return slowed and (spells.casting_speed_mult or 1.0) or 1.0
    end)
end

return M
