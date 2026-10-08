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

local function targetFromAim(caster, claim)
    -- Preference order: explicit target UUID, nearest hostile from eye ray.
    if claim.targetUuid and claim.targetUuid ~= "" then
        return claim.targetUuid
    end
    -- Fall back to the shared "nearest hostile" helper via Osi (poor but works).
    local best, bestDist = nil, 1e9
    local ents = Ext.Entity.GetAllEntitiesWithComponent("ServerCharacter") or {}
    for _, ent in ipairs(ents) do
        local uuid = ent.Uuid and ent.Uuid.EntityUuid
        if uuid and uuid ~= caster then
            local okE, enemy = pcall(function() return Osi.CharacterIsEnemy(uuid, caster) end)
            if okE and tonumber(enemy) == 1 then
                local okD, d = pcall(function() return Osi.GetDistanceTo(caster, uuid) end)
                local dist = tonumber(d) or 1e9
                if okD and dist < bestDist and dist < 30 then
                    best, bestDist = uuid, dist
                end
            end
        end
    end
    return best
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

            if def and def.kind == "point" and parsed.hitPoint then
                tryUseSpellAtPosition(caster, spellId, parsed.hitPoint)
            elseif def and def.kind == "teleport" and parsed.hitPoint then
                tryUseSpellAtPosition(caster, spellId, parsed.hitPoint)
            else
                local target = targetFromAim(caster, parsed) or caster
                pcall(function() Osi.UseSpell(caster, spellId, target) end)
                Log.Write(string.format("SpellCast: UseSpell caster=%s spell=%s target=%s cost=%d",
                    caster, tostring(spellId), tostring(target), cost))
            end
        end)
    end)
    Log.Write("SpellCast: registered")
end

return M
