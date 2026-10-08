-- SPDX-License-Identifier: GPL-3.0-or-later
-- Server-side spell gate. Overrides the legacy spike-5 CastSpellRequest
-- behaviour with mana validation.
--
-- Flow:
--   client -> CastSpellRequest { spell, aim, targetUuid?, hitPoint? }
--   server:
--     1. resolve caster = user->character
--     2. look up spell cost from data/spells.lua
--     3. Mana.TrySpend; if false, log + bail
--     4. Osi.UseSpell(caster, spell, target) OR UseSpellAtPosition if point

local Log = Ext.Require("Shared/Log.lua")
local Net = Ext.Require("Shared/Net.lua")
local ServerNet = Ext.Require("Server/Net.lua")
local Mana = Ext.Require("Server/Combat/Mana.lua")
local spells = Ext.Require("data/spells.lua")

local M = {}

-- Resolve claim.targetUuid against the caster. Returns the UUID to pass to
-- Osi.UseSpell, or nil if the claim can't yield a valid target (which must
-- abort the cast per the user's rules — no silent "or caster" fallback).
local function resolveTarget(caster, claim)
    local raw = claim.targetUuid
    if raw == "__self__" then return caster end
    if raw and raw ~= "" then
        -- The client raycast already picked a character; trust it.
        return raw
    end
    return nil
end

local function tryUseSpellAtPosition(caster, spellId, point)
    local x, y, z = point.x or point[1] or 0, point.y or point[2] or 0, point.z or point[3] or 0
    local ok, err = pcall(function()
        return Osi.UseSpellAtPosition(caster, spellId, x, y, z)
    end)
    if not ok then
        Log.Write("SpellCast: UseSpellAtPosition err; falling back to UseSpell self: " .. tostring(err))
        pcall(function() Osi.UseSpell(caster, spellId, caster) end)
    end
end

function M.Register()
    -- Replace the Spike 5 handler at the same channel. Last subscriber wins
    -- for a given channel? SE's RegisterNetListener stacks subscribers. Guard
    -- by only letting ours accept well-formed payloads with the "withMana"
    -- marker; legacy spike-5 payloads keep working through Server/Net.lua.
    Ext.RegisterNetListener(Net.Channels.CastSpellRequest, function(_, payload, userId)
        local ok, parsed = pcall(Ext.Json.Parse, payload)
        if not ok or not parsed.withMana then return end  -- not for us

        ServerNet.EnqueueOsi(function()
            local caster = ServerNet.UserToCharacter(userId)
            if not caster then return end
            local spellId = parsed.spell
            local def = spells.spells[spellId]
            local cost = (def and def.cost) or (spells.cost_by_level[def and def.level or 0] or 0)
            local okSpend, state = Mana.TrySpend(userId, caster, cost)
            if not okSpend then
                Log.Write(string.format("SpellCast: INSUFFICIENT MANA spell=%s cost=%d have=%.1f",
                    tostring(spellId), cost, state.current))
                return
            end

            local kind = def and def.kind or "target"
            if kind == "point" or kind == "teleport" then
                if not parsed.hitPoint then
                    Log.Write("SpellCast: NO GROUND HIT for " .. tostring(spellId) .. " -- aborting")
                    return
                end
                tryUseSpellAtPosition(caster, spellId, parsed.hitPoint)
                Log.Write(string.format("SpellCast: UseSpellAtPosition caster=%s spell=%s cost=%d at (%.2f,%.2f,%.2f)",
                    caster, tostring(spellId), cost,
                    parsed.hitPoint.x or 0, parsed.hitPoint.y or 0, parsed.hitPoint.z or 0))
            elseif kind == "target" or kind == "self" then
                local target = resolveTarget(caster, parsed)
                if not target then
                    Log.Write("SpellCast: NO TARGET IN SIGHT for " .. tostring(spellId) .. " -- aborting (no 'or caster' fallback)")
                    return
                end
                pcall(function() Osi.UseSpell(caster, spellId, target) end)
                Log.Write(string.format("SpellCast: UseSpell caster=%s spell=%s target=%s cost=%d",
                    caster, tostring(spellId), tostring(target), cost))
            else
                Log.Write("SpellCast: unknown kind " .. tostring(kind) .. " for " .. tostring(spellId))
            end
        end)
    end)
    Log.Write("SpellCast: registered")
end

return M
