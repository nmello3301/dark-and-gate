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
local Projectiles = Ext.Require("Server/Combat/Projectiles.lua")
local SpellDefs = Ext.Require("Shared/SpellDefs.lua")
local CastRequest = Ext.Require("Server/Combat/CastRequest.lua")
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

-- fix3: Osiris call arity differs between patches and SE throws "No
-- function named X exists that can be called with N parameters" on a
-- mismatch. Try the known shapes in order and remember the one that
-- worked. WithoutMove = 1 so the caster casts from where they stand.
local arity = {}
local function callFirst(name, variants)
    local order = {}
    if arity[name] then order[1] = arity[name] end
    for i = 1, #variants do if i ~= arity[name] then order[#order + 1] = i end end
    local errs = {}
    for _, i in ipairs(order) do
        local args = variants[i]
        local ok, err = pcall(function() return Osi[name](table.unpack(args)) end)
        if ok then
            if arity[name] ~= i then
                arity[name] = i
                Log.Write(string.format("SpellCast: Osi.%s works with %d args", name, #args))
            end
            return true
        end
        errs[#errs + 1] = string.format("%d args: %s", #args, tostring(err))
    end
    Log.Write("SpellCast: Osi." .. name .. " failed: " .. table.concat(errs, " | "))
    return false
end

local function castAtPosition(caster, spellId, p)
    local x, y, z = p.x or p[1] or 0, p.y or p[2] or 0, p.z or p[3] or 0
    return callFirst("UseSpellAtPosition", {
        { caster, spellId, x, y, z, 1 },
        { caster, spellId, x, y, z },
        { caster, spellId, x, y, z, 1, 0 },
    })
end

local function castAtTarget(caster, spellId, target)
    return callFirst("UseSpell", {
        { caster, spellId, target },
        { caster, spellId, target, 1 },
        { caster, spellId, target, 1, 0 },
    })
end

-- The player's arrows cast their visual clone the same way (Server/Combat/Bows.lua).
M.CastAtPosition = castAtPosition

-- Does the caster have this spell (its spell container = what BG3 offers on
-- its own hotbar, or its spellbook)? Checked for spells bound from the menu.
local function knows(caster, spellId)
    local found, checked = false, false
    pcall(function()
        local e = Ext.Entity.Get(caster)
        pcall(function()
            for _, m in ipairs(e.SpellContainer.Spells) do
                checked = true
                if tostring(m.SpellId.OriginatorPrototype) == spellId then found = true end
            end
        end)
        if not found then
            pcall(function()
                for _, sd in ipairs(e.SpellBook.Spells) do
                    checked = true
                    if tostring(sd.Id.OriginatorPrototype) == spellId or tostring(sd.Id.Prototype) == spellId then found = true end
                end
            end)
        end
    end)
    if not checked then return true end   -- can't read the components: don't block (logged by the caller's success)
    return found
end

-- Channelled casting: when each user armed which spell (SpellArm).
local armed = {}   -- userId -> { spell, at = ms }
local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

function M.Register()
    Ext.RegisterNetListener(Net.Channels.SpellArm, function(_, payload, userId)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok then return end
        if p.spell and p.spell ~= "" then
            -- The client's effective cast time (modifiers), floored at min_cast_s.
            local ct = tonumber(p.castTime)
            if ct then ct = math.max(ct, spells.min_cast_s or 0.3) end
            armed[userId] = { spell = p.spell, at = nowMs(), castTime = ct }
            -- Weapon stance like vanilla targeting: the prepare clip resolves
            -- in the active animation set, which follows the drawn weapon
            -- (vanilla Fire Bolt draws Gale's staff on select). Osiris
            -- SetWeaponUnsheathed(char, enable, immediate), as the game's own
            -- story uses it (_CRIME_CrimeTriggers, GLO_Camp).
            local spell = p.spell
            ServerNet.EnqueueOsi(function()
                local caster = ServerNet.UserToCharacter(userId)
                if not caster then return end
                local okS, st = pcall(Ext.Stats.Get, spell)
                local sheathing = okS and st and tostring(st.Sheathing or "") or ""
                local U = spells.spell_anims and spells.spell_anims.unsheath or {}
                local action = U[sheathing ~= "" and sheathing or "default"] or U.default or "none"
                if U.enabled == false then return end
                local res = "skipped"
                if action == "unsheath" or action == "sheath" then
                    local okO, err = pcall(Osi.SetWeaponUnsheathed, caster, action == "unsheath" and 1 or 0, U.immediate and 1 or 0)
                    res = okO and "ok" or ("ERROR " .. tostring(err))
                end
                Log.Write(string.format("SpellCast: arm %s Sheathing=%s -> %s (%s)", spell, sheathing ~= "" and sheathing or "(default)", action, res))
            end)
        else
            armed[userId] = nil
        end
    end)
    -- Replace the Spike 5 handler at the same channel. Last subscriber wins
    -- for a given channel? SE's RegisterNetListener stacks subscribers. Guard
    -- by only letting ours accept well-formed payloads with the "withMana"
    -- marker; legacy spike-5 payloads keep working through Server/Net.lua.
    Ext.RegisterNetListener(Net.Channels.CastSpellRequest, function(_, payload, userId)
        local ok, parsed = pcall(Ext.Json.Parse, payload)
        if not ok or not parsed.withMana then return end  -- not for us

        -- Cast time: the release must come cast_time_s after the arm.
        do
            local def0 = SpellDefs.Get(parsed.spell)
            local a = armed[userId]
            local base = (a and a.castTime) or (def0 and (def0.base_cast_s or def0.cast_time_s)) or spells.base_cast_s or spells.cast_time_s or 0
            local need = base - (spells.cast_time_tolerance_s or 0)
            local held = a and a.spell == parsed.spell and (nowMs() - a.at) / 1000 or nil
            if need > 0 and (not held or held < need) then
                Log.Write(string.format("SpellCast: REJECTED %s released after %s s (cast time %.2f s)",
                    tostring(parsed.spell), held and string.format("%.2f", held) or "no arm", need + (spells.cast_time_tolerance_s or 0)))
                return
            end
            armed[userId] = nil
        end

        ServerNet.EnqueueOsi(function()
            local caster = ServerNet.UserToCharacter(userId)
            if not caster then return end
            local spellId = parsed.spell
            local def = SpellDefs.Get(spellId)
            if not def then
                Log.Write("SpellCast: REJECTED " .. tostring(spellId) .. " (no such spell)")
                return
            end
            -- A spell bound from the Prepare Hotbar menu must be one the caster
            -- has (data/spells.lua's M1b test spells are allowed for the slice).
            if def.derived and not knows(caster, spellId) then
                Log.Write(string.format("SpellCast: REJECTED %s (%s doesn't have it)", tostring(spellId), tostring(caster)))
                return
            end
            local cost = SpellDefs.Cost(spellId)
            local okSpend, state = Mana.TrySpend(userId, caster, cost)
            if not okSpend then
                Log.Write(string.format("SpellCast: INSUFFICIENT MANA spell=%s cost=%d have=%.1f",
                    tostring(spellId), cost, state.current))
                return
            end

            -- A spell prepare loop (or jump clip) still playing would queue
            -- the cast behind it (Osi.PlayAnimation is an Osiris task).
            ServerNet.StopScriptedAnim(caster, "before cast")

            -- Projectile spells (data/projectiles.lua): our own flight and
            -- hits; BG3 shows its projectile and applies the impact clone.
            local target = resolveTarget(caster, parsed)
            local okCast, how
            -- Targeted spells (client Targeting.lua): every picked character
            -- at once through the cast request queue; IgnoreTargetChecks so a
            -- target that took cover after being picked is still hit.
            if type(parsed.targets) == "table" and #parsed.targets > 0 then
                local list, names = {}, {}
                local okS, st = pcall(Ext.Stats.Get, spellId)
                local range = (okS and st and tonumber(tostring(st.TargetRadius))) or 18
                for _, u in ipairs(parsed.targets) do
                    local okD, d = pcall(function() return Osi.GetDistanceTo(caster, u) end)
                    if okD and tonumber(d) and tonumber(d) <= range + 3 then list[#list + 1] = { uuid = u }; names[#names + 1] = u
                    else Log.Write(string.format("SpellCast: picked target %s dropped (%s m, range %.0f)", tostring(u), tostring(d), range)) end
                end
                if #list > 0 then
                    local r, err = CastRequest.Submit(caster, spellId, list, { options = { "IgnoreHasSpell", "NoMovement", "IgnoreTargetChecks" } })
                    okCast, how = r ~= nil, string.format("cast request on %d picked target(s) %s%s", #list, table.concat(names, ","),
                        r and "" or (" FAILED " .. tostring(err)))
                else
                    okCast, how = false, "no picked target in range"
                end
                target = nil
            end
            local launched, why = false, "not a projectile spell"
            if not okCast and how == nil then
                launched, why = Projectiles.Launch(caster, spellId, parsed, function(c, id, p) return castAtPosition(c, id, p) end)
            end
            if okCast then
                -- picked targets cast above
            elseif how then
                -- picked targets failed (logged below)
            elseif launched then
                okCast, how = true, "projectile flight"
            elseif why ~= "not a projectile spell" then
                Log.Write("SpellCast: projectile launch failed (" .. tostring(why) .. "), casting the spell the old way")
            end
            if okCast then
                -- launched
            elseif how then
                -- picked targets failed: keep the reason
            elseif target then
                okCast, how = castAtTarget(caster, spellId, target), "UseSpell target=" .. tostring(target)
            elseif parsed.hitPoint then
                okCast = castAtPosition(caster, spellId, parsed.hitPoint)
                how = string.format("UseSpellAtPosition (%.2f,%.2f,%.2f)",
                    parsed.hitPoint.x or 0, parsed.hitPoint.y or 0, parsed.hitPoint.z or 0)
            else
                okCast, how = false, "no target and no point"
            end
            if not okCast then
                -- Refund: nothing was cast.
                local st = Mana.StateFor(userId)
                st.current = math.min(st.max, st.current + cost)
            end
            Log.Write(string.format("SpellCast: %s %s spell=%s cost=%d",
                okCast and "CAST" or "FAILED", how, tostring(spellId), okCast and cost or 0))
        end)
    end)
    Log.Write("SpellCast: registered")
end

return M
