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
    local aim  = Aim.CrosshairRay(60.0, kind == "target")

    local payload = {
        withMana = true,
        spell    = spellId,
    }

    if kind == "self" then
        payload.targetUuid = "__self__"
    elseif kind == "target" then
        if not aim or not aim.hit or not aim.hit.target then
            Log.Write("Spells: NO TARGET IN SIGHT for " .. spellId .. " -- aborting cast")
            return
        end
        payload.targetUuid = aim.hit.target
        payload.hitPoint   = { x = aim.hit.pos[1], y = aim.hit.pos[2], z = aim.hit.pos[3] }
    elseif kind == "point" or kind == "teleport" then
        if not aim or not aim.hit then
            Log.Write("Spells: NO GROUND HIT for " .. spellId .. " -- aborting cast")
            return
        end
        payload.hitPoint = { x = aim.hit.pos[1], y = aim.hit.pos[2], z = aim.hit.pos[3] }
    else
        Log.Write("Spells: unknown kind " .. tostring(kind) .. " for " .. spellId)
        return
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
