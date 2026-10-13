-- SPDX-License-Identifier: GPL-3.0-or-later
-- Damage on our hit paths (DECISIONS 2026-10-12): NPC and companion swings,
-- arrows, anything we resolve ourselves.
--
--   Damage.Apply(target, amount, damageType, source, why) -> dealt, how
--
-- A character a player controls takes it WITHOUT BG3's hit reaction (it jerks
-- the head-anchored camera): a non-lethal hit comes off TemporaryHp, then Hp,
-- straight on the Health component (Replicate). The hit that would bring it
-- to 0 goes through Osi.ApplyDamage, so BG3's real downed flow runs (our
-- bleed-out status, Server/Combat/Downed.lua). Everyone else (enemies,
-- companions on AI) takes Osi.ApplyDamage and keeps BG3's hit reaction.
-- A downed character takes nothing ("hits on a downed player do nothing").
-- On the direct path non-magical resistance / immunity / vulnerability is
-- applied here (Osi.ApplyDamage runs BG3's own pipeline).
-- The direct write skips concentration checks, on-damage passives and the
-- combat log line (docs/rework-list.md).
-- God mode (!dag_god, Server/Combat/TestKit.lua): a character with the
-- DAG_GODMODE status takes nothing here (BG3's own damage is stopped by the
-- status's Invulnerable() boost); the hit still plays its impact sound.

local Log   = Ext.Require("Shared/Log.lua")
local Party = Ext.Require("Server/Party.lua")

local M = {}

M.GOD_STATUS = "DAG_GODMODE"

local DAMAGE_INDEX = {
    None = 0, Slashing = 1, Piercing = 2, Bludgeoning = 3, Acid = 4, Thunder = 5, Necrotic = 6, Fire = 7,
    Lightning = 8, Cold = 9, Psychic = 10, Poison = 11, Radiant = 12, Force = 13,
}

local function name(uuid)
    local ok, n = pcall(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(uuid)) end)
    return (ok and n and n ~= "") and n or tostring(uuid)
end
M.Name = name

local function health(uuid)
    local ok, e = pcall(Ext.Entity.Get, uuid)
    if not ok or not e then return nil end
    local okH, h = pcall(function() return e.Health end)
    return okH and h or nil, e
end

function M.Hp(uuid)
    local h = health(uuid)
    if h then
        local ok, hp = pcall(function() return h.Hp end)
        if ok and tonumber(hp) then return tonumber(hp) end
    end
    local okO, hp2 = pcall(function() return Osi.GetHitpoints(uuid) end)
    return okO and tonumber(hp2) or nil
end

-- !dag_god: true while the character has the god mode status.
function M.Invincible(uuid)
    local ok, v = pcall(function() return Osi.HasActiveStatus(uuid, M.GOD_STATUS) end)
    return ok and tonumber(v) == 1
end

local function impactSound(target, damageType)
    pcall(function() Osi.PlaySound(target, "Action_Impact_" .. (damageType == "Piercing" and "PiercingThrust" or damageType == "Slashing" and "Slash" or "Smash")) end)
end

function M.IsDowned(uuid)
    local okD, dead = pcall(function() return Osi.IsDead(uuid) end)
    if okD and tonumber(dead) == 1 then return false end
    local okS, v = pcall(function() return Osi.HasAppliedStatusOfType(uuid, "DOWNED") end)
    if okS and tonumber(v) == 1 then return true end
    local hp = M.Hp(uuid)
    return hp ~= nil and hp <= 0
end

-- Non-magical weapon damage vs the target's resistances (x0 / x0.5 / x2).
local function resistMult(uuid, damageType)
    local idx = DAMAGE_INDEX[damageType]
    if not idx then return 1, nil end
    local mult, why = 1, nil
    pcall(function()
        local flags = Ext.Entity.Get(uuid).Resistances.Resistances[idx + 1]
        for _, f in ipairs(flags or {}) do
            f = tostring(f)
            if f == "ImmuneToNonMagical" then mult, why = 0, "immune"
            elseif f == "ResistantToNonMagical" and mult > 0 then mult, why = 0.5, "resistant"
            elseif f == "VulnerableToNonMagical" and mult == 1 then mult, why = 2, "vulnerable" end
        end
    end)
    return mult, why
end

function M.Apply(target, amount, damageType, source, why)
    target = Party.Norm(target)
    damageType = damageType or "Slashing"
    amount = math.floor((tonumber(amount) or 0) + 0.5)
    if not target or amount <= 0 then return 0, "nothing" end
    if M.IsDowned(target) then
        Log.Write(string.format("Damage: %s is downed -> %d %s from %s ignored (%s)", name(target), amount, damageType,
            source and name(source) or "?", why or "hit"))
        return 0, "downed"
    end
    if M.Invincible(target) then
        impactSound(target, damageType)
        Log.Write(string.format("Damage: %s is in god mode (!dag_god) -> %d %s from %s ignored (%s)", name(target), amount, damageType,
            source and name(source) or "?", why or "hit"))
        return 0, "god mode"
    end
    local h, ent = health(target)
    local hp0 = M.Hp(target)
    local rwhy = nil
    if Party.IsControlled(target) and h and hp0 then
        -- Our direct write skips BG3's damage pipeline: resistances by hand.
        local mult
        mult, rwhy = resistMult(target, damageType)
        if mult ~= 1 then amount = math.floor(amount * mult + 0.5) end
        if amount <= 0 then
            Log.Write(string.format("Damage: %s is immune to %s from %s (%s)", name(target), damageType, source and name(source) or "?", why or "hit"))
            return 0, "immune"
        end
        local temp = 0
        pcall(function() temp = tonumber(h.TemporaryHp) or 0 end)
        if amount < hp0 + temp then
            local fromTemp = math.min(temp, amount)
            local ok, err = pcall(function()
                h.TemporaryHp = temp - fromTemp
                h.Hp = hp0 - (amount - fromTemp)
                ent:Replicate("Health")
            end)
            if ok then
                impactSound(target, damageType)
                Log.Write(string.format("Damage: %s took %d %s from %s (%s, no hit reaction%s): HP %d -> %d%s",
                    name(target), amount, damageType, source and name(source) or "?", why or "hit", rwhy and (", " .. rwhy) or "",
                    hp0, hp0 - (amount - fromTemp), fromTemp > 0 and string.format(" (temp HP -%d)", fromTemp) or ""))
                return amount, "direct"
            end
            Log.Write("Damage: direct Health write failed (" .. tostring(err) .. "), using Osi.ApplyDamage")
        end
    end
    local ok, err = pcall(function() Osi.ApplyDamage(target, amount, damageType, source or "NULL_00000000-0000-0000-0000-000000000000") end)
    if not ok then
        ok, err = pcall(function() Osi.ApplyDamage(target, amount, damageType) end)
    end
    Log.Write(string.format("Damage: %s took %d %s from %s (%s%s) via Osi.ApplyDamage%s: HP %s -> ...%s", name(target), amount, damageType,
        source and name(source) or "?", why or "hit", rwhy and (", " .. rwhy) or "",
        Party.IsControlled(target) and " (lethal: BG3's downed flow)" or "", tostring(hp0), ok and "" or (" ERROR " .. tostring(err))))
    return ok and amount or 0, "osiris"
end

-- Give back `amount` HP (a shield's share of a spell impact we can't scale
-- before it lands). Never revives: only while the target is above 0.
function M.HealBack(target, amount, why)
    amount = math.floor((tonumber(amount) or 0) + 0.5)
    if amount <= 0 then return end
    local h, ent = health(target)
    local hp = M.Hp(target)
    if not h or not hp or hp <= 0 then return end
    local ok = pcall(function()
        h.Hp = math.min(tonumber(h.MaxHp) or (hp + amount), hp + amount)
        ent:Replicate("Health")
    end)
    Log.Write(string.format("Damage: %s gets %d HP back (%s): HP %d -> %s%s", name(target), amount, why or "heal back", hp,
        ok and tostring(M.Hp(target)) or "?", ok and "" or " (write FAILED)"))
end

-- "XdY+Z" -> rolled total (min 1).
function M.Roll(dice, bonus)
    local total = 0
    local n, sides, add = tostring(dice or ""):match("^%s*(%d*)[dD](%d+)%s*([%+%-]?%s*%d*)")
    if sides then
        n = tonumber(n) or 1
        for _ = 1, n do total = total + math.random(1, tonumber(sides)) end
        if add and add:gsub("%s", "") ~= "" then total = total + (tonumber((add:gsub("%s", ""))) or 0) end
    else
        total = tonumber(dice) or 1
    end
    return math.max(1, total + (bonus or 0))
end

return M
