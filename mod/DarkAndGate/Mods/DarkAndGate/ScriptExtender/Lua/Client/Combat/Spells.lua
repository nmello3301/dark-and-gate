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
    State.cooldownUntil[spellId] = nowMs() + (def.cooldown_ms or 400)

    local aim = Aim.CrosshairRay(60.0, def.kind == "target")
    local payload = {
        withMana = true,
        spell    = spellId,
    }
    if aim and aim.hit then
        payload.hitPoint = { x = aim.hit.pos[1], y = aim.hit.pos[2], z = aim.hit.pos[3] }
        if def.kind == "target" and aim.hit.target then
            payload.targetUuid = aim.hit.target
        elseif def.kind == "target" then
            payload.targetUuid = "__nearest_enemy__"  -- server will pick
        end
    else
        -- No ray hit: still try. Server falls back to self.
        payload.targetUuid = "__nearest_enemy__"
    end
    ClientNet.Send(Net.Channels.CastSpellRequest, payload)
    Log.Write(string.format("Spells: request %s (%s)", spellId, def.label or def.kind))
end

return M
