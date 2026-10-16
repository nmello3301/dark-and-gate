-- SPDX-License-Identifier: GPL-3.0-or-later
-- No fall damage in Dark and Gate (developer 2026-10-15: "We don't want to
-- have fall damage in this mod"). Every party member (and each player's
-- avatar) carries the hidden status DAG_NO_FALL_DAMAGE, which has BG3's own
-- IgnoreFallDamage() boost, the one vanilla's Feather Fall uses
-- (Public/DarkAndGate/Stats/Generated/Data/DAG_Combat.txt). Checked every
-- 2 s and at each level start, like the max HP bonus (HpBonus.lua), so a
-- status lost to death, a respec or a story script comes back.
--
--   data/combat.lua fall_damage = false   (true = BG3's fall damage back:
--                                          the status comes off)

local Log    = Ext.Require("Shared/Log.lua")
local Party  = Ext.Require("Server/Party.lua")
local combat = Ext.Require("data/combat.lua")

local M = {}

local STATUS = "DAG_NO_FALL_DAMAGE"
local checkAt = -1e9
local logged = 0

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local function name(u)
    local ok, n = pcall(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(u)) end)
    return (ok and n and n ~= "") and n or tostring(u)
end

local function has(u)
    local ok, v = pcall(Osi.HasActiveStatus, u, STATUS)
    return ok and tonumber(v) == 1
end

local function dead(u)
    local ok, v = pcall(Osi.IsDead, u)
    return ok and tonumber(v) == 1
end

local function targets()
    local out, seen = {}, {}
    for _, u in ipairs(Party.Members()) do
        if not seen[u] then seen[u] = true; out[#out + 1] = u end
    end
    pcall(function()
        for _, row in pairs(Osi.DB_Avatars:Get(nil) or {}) do
            local u = Party.Norm(row[1])
            if u and not seen[u] then seen[u] = true; out[#out + 1] = u end
        end
    end)
    return out
end

local function sync(why)
    if Party.InCharacterCreation() then return end
    local want = combat.fall_damage ~= true
    for _, u in ipairs(targets()) do
        if not dead(u) then
            local on = has(u)
            if want and not on then
                local ok, err = pcall(Osi.ApplyStatus, u, STATUS, -1, 1, u)
                if logged < 30 then
                    logged = logged + 1
                    Log.Write(string.format("NoFallDamage: %s -> %s (%s)%s", name(u), STATUS, why, ok and "" or (" FAILED " .. tostring(err))))
                end
            elseif not want and on then
                pcall(Osi.RemoveStatus, u, STATUS, u)
                Log.Write(string.format("NoFallDamage: %s -> %s removed (fall_damage = true)", name(u), STATUS))
            end
        end
    end
end

function M.Register()
    Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function() pcall(sync, "level start") end)
    Ext.Osiris.RegisterListener("CharacterCreationFinished", 0, "after", function() pcall(sync, "character creation done") end)
    Ext.Osiris.RegisterListener("CharacterJoinedParty", 1, "after", function() checkAt = -1e9 end)
    Ext.Events.Tick:Subscribe(function()
        local t = now()
        if t - checkAt < 2000 then return end
        checkAt = t
        pcall(sync, "check")
    end)
    Log.Write("NoFallDamage: registered (" .. (combat.fall_damage == true and "BG3's fall damage ON (data)" or "no fall damage for the party") .. ")")
end

return M
