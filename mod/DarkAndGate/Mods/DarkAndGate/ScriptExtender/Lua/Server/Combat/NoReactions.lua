-- SPDX-License-Identifier: GPL-3.0-or-later
-- Real-time fights: no reactions and no Sneak Attack (DECISIONS 2026-10-12,
-- docs/rework-list.md has a rework note for each).
--
-- Everyone in a real-time fight gets the hidden status DAG_NO_REACTIONS
-- (Public/DarkAndGate/Stats/Generated/Data/DAG_Combat.txt):
--   ActionResourceBlock(ReactionActionPoint)  BG3's own "can't take
--       reactions" lever (Shocking Grasp uses it). It covers every interrupt
--       that costs a reaction: opportunity attacks, Shield, Counterspell,
--       Hellish Rebuke, Riposte, Uncanny Dodge...
--   ActionResourceBlock(SneakAttack_Charge)   the Sneak Attack interrupt and
--       both Sneak Attack spells cost this charge.
-- Interrupts that cost neither (Divine Smite prompts, Lucky, Portent...)
-- are not blocked; our hits (Osi.ApplyDamage, impact clones) never trigger
-- on-hit interrupts anyway (rework-list.md).
--
-- Applied when a character enters a real-time fight (and to everyone already
-- fighting when real time is switched on), removed when it leaves combat
-- and on !dag_rt off. At level start a sliced sweep removes leftovers from
-- a save made mid-fight.

local Log   = Ext.Require("Shared/Log.lua")
local Brawl = Ext.Require("Server/BrawlAdapter.lua")
local Party = Ext.Require("Server/Party.lua")

local STATUS = "DAG_NO_REACTIONS"

local M = {}

local applied = {}   -- uuid -> combat guid (or true)
local sweep = nil    -- { handles, idx } while the level-start sweep runs

local function has(uuid)
    local ok, v = pcall(function() return Osi.HasActiveStatus(uuid, STATUS) end)
    return ok and tonumber(v) == 1
end

local function inCombat(uuid)
    local ok, v = pcall(function() return Osi.IsInCombat(uuid) end)
    return ok and tonumber(v) == 1
end

local function apply(uuid, combat, why)
    uuid = Party.Norm(uuid)
    if not uuid or applied[uuid] then return end
    local ok, err = pcall(function() Osi.ApplyStatus(uuid, STATUS, -1, 1, uuid) end)
    if ok then applied[uuid] = combat or true end
    Log.Write(string.format("NoReactions: %s -> reactions and Sneak Attack blocked (%s)%s", Brawl.Name(uuid), why,
        ok and "" or (" ERROR " .. tostring(err))))
end

local function remove(uuid, why)
    uuid = Party.Norm(uuid)
    if not uuid then return end
    local was = applied[uuid]
    applied[uuid] = nil
    if not was and not has(uuid) then return end
    local ok, err = pcall(function() Osi.RemoveStatus(uuid, STATUS, uuid) end)
    if not ok then ok, err = pcall(function() Osi.RemoveStatus(uuid, STATUS) end) end
    Log.Write(string.format("NoReactions: %s -> reactions back (%s)%s", Brawl.Name(uuid), why, ok and "" or (" ERROR " .. tostring(err))))
end

function M.Applied() return applied end

local function applyToFight(why)
    local n = 0
    for uuid in pairs(Roster.getBrawlers() or {}) do
        if inCombat(uuid) then apply(uuid, true, why); n = n + 1 end
    end
    return n
end

local function sweepTick()
    if not sweep then return end
    local last = math.min(#sweep.handles, sweep.idx + 59)
    for i = sweep.idx, last do
        local e = sweep.handles[i]
        local okU, u = pcall(function() return tostring(e.Uuid.EntityUuid) end)
        if okU and u and has(u) and not (Brawl.Enabled() and inCombat(u)) then
            sweep.removed = sweep.removed + 1
            remove(u, "left over from a save made mid-fight")
        end
    end
    sweep.idx = last + 1
    if sweep.idx > #sweep.handles then
        Log.Write(string.format("NoReactions: level-start sweep done (%d characters checked, %d leftovers removed)", #sweep.handles, sweep.removed))
        sweep = nil
    end
end

function M.Register()
    Brawl.Hook("EnteredCombat", function(uuid, combat)
        if Brawl.Enabled() then apply(uuid, combat, "joined a real-time fight") end
    end)
    Brawl.Hook("Enabled", function()
        local n = applyToFight("real time switched on mid-fight")
        Log.Write(string.format("NoReactions: real time on, %d fighters blocked", n))
    end)
    Brawl.Hook("Disabling", function()
        local list = {}
        for uuid in pairs(applied) do list[#list + 1] = uuid end
        for _, uuid in ipairs(list) do remove(uuid, "!dag_rt off: vanilla turn-based rules") end
    end)
    Brawl.Hook("CombatEnded", function(combat)
        local list = {}
        for uuid, c in pairs(applied) do
            if c == combat or not inCombat(uuid) then list[#list + 1] = uuid end
        end
        for _, uuid in ipairs(list) do remove(uuid, "fight over") end
    end)
    Ext.Osiris.RegisterListener("LeftCombat", 2, "after", function(obj)
        local uuid = Party.Norm(obj)
        if uuid and applied[uuid] then remove(uuid, "left combat") end
    end)
    Ext.Osiris.RegisterListener("Died", 1, "after", function(obj)
        local uuid = Party.Norm(obj)
        if uuid then applied[uuid] = nil end
    end)
    Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function()
        local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerCharacter")
        sweep = { handles = (ok and ents) or {}, idx = 1, removed = 0 }
    end)
    Ext.Events.Tick:Subscribe(function() if sweep then pcall(sweepTick) end end)
    Log.Write("NoReactions: registered (status " .. STATUS .. " on every real-time fighter)")
end

return M
