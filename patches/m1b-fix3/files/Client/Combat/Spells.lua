-- SPDX-License-Identifier: GPL-3.0-or-later
-- Client-side spell cast flow for M1b.
--
-- On key press (via Hotbar.PressSlot):
--   1. Resolve the spell id for the slot.
--   2. Fire crosshair aim ray to find a target or hit point.
--   3. Send CastSpellRequest with withMana=true + spell + aim.
-- Server validates mana and routes to Osi.UseSpell / UseSpellAtPosition.

local Log       = Ext.Require("Shared/Log.lua")
local Net       = Ext.Require("Shared/Net.lua")
local State     = Ext.Require("Client/Combat/State.lua")
local Aim       = Ext.Require("Client/Combat/Aim.lua")
local ClientNet = Ext.Require("Client/Net.lua")
local spells    = Ext.Require("data/spells.lua")

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
    local range = def.range_m or 30.0

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
    else
        local t = (kind == "target") and Aim.TargetAtCrosshair(range) or nil
        if t then
            payload.targetUuid = t.target
            payload.hitPoint   = { x = t.pos[1], y = t.pos[2], z = t.pos[3] }
            Log.Write(string.format("Spells: %s -> character %s at %.1f m", spellId, t.target, t.distance or 0))
        else
            local pos, dist, via = Aim.GroundPoint(range)
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
    ClientNet.Send(Net.Channels.CastSpellRequest, payload)
    Log.Write(string.format("Spells: request %s (%s) target=%s point=%s",
        spellId, def.label or kind,
        tostring(payload.targetUuid),
        payload.hitPoint and string.format("(%.2f,%.2f,%.2f)", payload.hitPoint.x, payload.hitPoint.y, payload.hitPoint.z) or "nil"))
end

return M
