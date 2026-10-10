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
local Actions   = Ext.Require("Client/Combat/Actions.lua")
local Prepare   = Ext.Require("Client/Combat/Prepare.lua")
local airAction = Ext.Require("data/movement.lua").air_action

local M = {}

local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) end

function M.Cast(spellId)
    local def = spells.spells[spellId]
    if not def then
        Log.Write("Spells: unknown id " .. tostring(spellId)); return
    end
    local cd = State.cooldownUntil[spellId] or 0
    if nowMs() < cd then return end

    local kind = def.kind or "target"
    local far = def.unlimited_range
    local range = far and (spells.aim_far_m or 100) or (def.range_m or 30.0)

    -- Shooting spells: straight down the crosshair line, nothing else
    -- (Aim.SpellAim). A character on the line is the target; otherwise the
    -- world point or the far point along the line.
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
        if straight.target and kind == "target" then payload.targetUuid = straight.target end
        payload.hitPoint = { x = p[1], y = p[2], z = p[3] }
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
            if far then pos, dist, via = Aim.AimPoint(range) else pos, dist, via = Aim.GroundPoint(range) end
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
    Actions.Begin("cast", airAction.cast_s)
    Prepare.Stop("cast")
    ClientNet.Send(Net.Channels.CastSpellRequest, payload)
    Log.Write(string.format("Spells: request %s (%s) target=%s point=%s",
        spellId, def.label or kind,
        tostring(payload.targetUuid),
        payload.hitPoint and string.format("(%.2f,%.2f,%.2f)", payload.hitPoint.x, payload.hitPoint.y, payload.hitPoint.z) or "nil"))
    return true
end

-- Channelled casting: seconds until the armed spell may be released
-- (0 = ready). armedAt comes from Hotbar.PressSlot.
function M.CastTime(spellId)
    local def = spells.spells[spellId]
    return (def and def.cast_time_s) or spells.cast_time_s or 0
end
function M.ReadyIn(spellId)
    if not State.armedAt then return 0 end
    local left = M.CastTime(spellId) - (nowMs() - State.armedAt) / 1000
    return left > 0 and left or 0
end

-- Keep the "cast" action alive while the engine still casts. Whether the
-- client sees SpellCastIsCasting on the player is logged once.
local castProbeLogged = false
local function tick()
    if not Actions.Running("cast") then return end
    local okE, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
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
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
end

return M
