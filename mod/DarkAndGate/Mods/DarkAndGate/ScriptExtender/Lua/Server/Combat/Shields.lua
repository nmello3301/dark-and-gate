-- SPDX-License-Identifier: GPL-3.0-or-later
-- Passive shields, server side (DECISIONS 2026-10-12, data/combat.lua).
-- Who holds a shield (Osi.GetEquippedShield, cached, refreshed on Equipped /
-- Unequipped) and whether a hit's line crosses the shield disc
-- (Shared/Shield.lua) before the body. Used by every hit path: the player's
-- swing claims (HitValidator), NPC / companion swings (NpcCombat) and every
-- projectile (Projectiles), so a shield takes data/combat.lua
-- shield.reduction (40 %) off a hit that lands on it.
--
--   Shields.Has(uuid)                         -> item uuid or nil
--   Shields.Disc(uuid)                        -> disc or nil (no shield / no transform)
--   Shields.Blocks(uuid, from, to, pad)       -> distance along from->to if the
--                                                disc is hit first, else nil
--   Shields.Reduce(amount, defender)          -> reduced amount, share taken
--   Shields.ReductionFor(defender)            -> the share a shield takes: a party
--                                                member's CON curve (Meta-Points
--                                                "block", replaces the fixed 40 %),
--                                                the data value for everyone else
--   !dag_shield_pct <0-1>   !dag_shield_debug   (also from the client console)

local Log    = Ext.Require("Shared/Log.lua")
local Shield = Ext.Require("Shared/Shield.lua")
local Hitbox = Ext.Require("Shared/Hitbox.lua")
local Party  = Ext.Require("Server/Party.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")
local MetaPoints = Ext.Require("Shared/MetaPoints.lua")

local M = {}

local cache = {}   -- uuid -> { item = uuid|false, at = ms }
local REFRESH_MS = 10000

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function len(a) return math.sqrt(a[1] * a[1] + a[2] * a[2] + a[3] * a[3]) end

local function isShieldItem(item)
    local yes = false
    pcall(function() yes = Ext.Entity.Get(item).Armor.Shield == true end)
    if yes then return true end
    pcall(function()
        local st = Ext.Stats.Get(Ext.Entity.Get(item).Data.StatsId)
        yes = tostring(st.Shield) == "Yes"
    end)
    return yes
end

function M.Has(uuid)
    uuid = Party.Norm(uuid)
    if not uuid then return nil end
    local c = cache[uuid]
    if c and now() - c.at < REFRESH_MS then return c.item or nil end
    local item = false
    local ok, it = pcall(function() return Osi.GetEquippedShield(uuid) end)
    if ok and it and it ~= "" then item = Party.Norm(it) end
    if not item then
        local okO, off = pcall(function() return Osi.GetEquippedItem(uuid, "Melee Offhand Weapon") end)
        if okO and off and off ~= "" and isShieldItem(off) then item = Party.Norm(off) end
    end
    cache[uuid] = { item = item, at = now() }
    return item or nil
end

local function feetAndEntity(uuid)
    local ok, e = pcall(Ext.Entity.Get, uuid)
    if not ok or not e then return nil end
    local okT, t = pcall(function() return e.Transform.Transform.Translate end)
    if not okT or not t then return nil end
    return { t[1], t[2] + Hitbox.Lift(uuid), t[3] }, e
end

function M.Disc(uuid)
    if not M.Has(uuid) then return nil end
    local feet, e = feetAndEntity(uuid)
    if not feet then return nil end
    return Shield.Disc(feet, Shield.Forward(e))
end

-- The segment from -> to crosses the shield disc of `uuid`? pad grows the
-- disc (a projectile's radius).
function M.Blocks(uuid, from, to, pad)
    local disc = M.Disc(uuid)
    if not disc then return nil end
    local d = sub(to, from)
    local L = len(d)
    if L < 1e-4 then return nil end
    return Shield.RayHit(disc, from, { d[1] / L, d[2] / L, d[3] / L }, L, pad)
end

function M.ReductionFor(defender)
    local u = defender and Party.Norm(defender)
    if u and Party.IsMember(u) then
        local v = MetaPoints.Value(u, "block")
        if v then return math.max(0, math.min(1, v)) end
    end
    return Shield.Reduction()
end

function M.Reduce(amount, defender)
    local r = M.ReductionFor(defender)
    local kept = math.floor((tonumber(amount) or 0) * (1 - r) + 0.5)
    return kept, r
end

function M.Register()
    Ext.Osiris.RegisterListener("Equipped", 2, "after", function(_, char) cache[Party.Norm(char) or ""] = nil end)
    Ext.Osiris.RegisterListener("Unequipped", 2, "after", function(_, char) cache[Party.Norm(char) or ""] = nil end)
    ConsoleForward.Server("dag_shield_pct", function(_, v)
        if v then Shield.SetReduction(v) end
        Log.Write(string.format("Shields: a hit on a shield loses %.0f %% of its damage (data/combat.lua shield.reduction; party members: their CON block curve)", Shield.Reduction() * 100))
    end)
    ConsoleForward.Server("dag_shield_debug", function()
        local n = 0
        for _, uuid in ipairs(Party.Members()) do
            local item = M.Has(uuid)
            local feet, e = feetAndEntity(uuid)
            local fwd = e and Shield.Forward(e)
            local disc = item and M.Disc(uuid)
            Log.Write(string.format("Shields: %s shield=%s feet=%s fwd=%s disc=%s", Party.Norm(uuid), tostring(item),
                feet and string.format("(%.2f,%.2f,%.2f)", feet[1], feet[2], feet[3]) or "?",
                fwd and string.format("(%.2f,%.2f,%.2f)", fwd[1], fwd[2], fwd[3]) or "?",
                disc and string.format("centre (%.2f,%.2f,%.2f) r %.2f", disc.c[1], disc.c[2], disc.c[3], disc.r) or "-"))
            n = n + 1
        end
        for uuid, c in pairs(cache) do
            if c.item then Log.Write(string.format("Shields: cached shield on %s (%s)", uuid, tostring(c.item))) end
        end
        Log.Write(string.format("Shields: %d party members listed; reduction %.0f %%", n, Shield.Reduction() * 100))
    end)
    Log.Write(string.format("Shields: registered (passive, %.0f %% off hits that land on the disc)", Shield.Reduction() * 100))
end

return M
