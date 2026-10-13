-- SPDX-License-Identifier: GPL-3.0-or-later
-- !dag_hp: more max HP for your character (developer 2026-10-12: "add a way
-- I can increase my character's health in 50%, the overall tests seemed a
-- bit hard"). A hidden status carrying BG3's own percentage boost,
-- IncreaseMaxHP(N%) -- the boost vanilla's easy-mode ally health status
-- uses -- so it follows level-ups and Constitution by itself and survives
-- saves and long rests: DAG_HP_BONUS_25 / _50 / _75 / _100, one stack
-- (Public/DarkAndGate/Stats/Generated/Data/DAG_Combat.txt).
--
--   !dag_hp 50          +50 % max HP for your own character (each player's
--                       avatar, DB_Avatars: the character you created)
--   !dag_hp 50 party    +50 % for every party member, companions too, and
--                       whoever joins later
--   !dag_hp off         back to BG3's max HP
--   !dag_hp             what is on
-- The choice is kept on the host (DarkAndGate/hp-bonus.json), for every save
-- and new game, and checked every 2 s, so a status lost to death or a story
-- script comes back. A character that gets the bonus keeps its share of HP
-- (full stays full).

local Log            = Ext.Require("Shared/Log.lua")
local Net            = Ext.Require("Shared/Net.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")
local Party          = Ext.Require("Server/Party.lua")
local Damage         = Ext.Require("Server/Combat/Damage.lua")

local M = {}

local FILE = "DarkAndGate/hp-bonus.json"
local LEVELS = { 25, 50, 75, 100 }
local STATUS = {}
for _, p in ipairs(LEVELS) do STATUS[p] = "DAG_HP_BONUS_" .. p end

local cfg = { pct = 0, who = "me" }   -- who: "me" = each player's avatar, "party" = every party member
local checkAt = -1e9
local heals = {}                       -- uuid -> { at, hp, max }

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local function name(u)
    local ok, n = pcall(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(u)) end)
    return (ok and n and n ~= "") and n or tostring(u)
end

local function load()
    local ok, txt = pcall(Ext.IO.LoadFile, FILE)
    if not ok or not txt or txt == "" then return end
    local okJ, t = pcall(Ext.Json.Parse, txt)
    if okJ and type(t) == "table" then
        cfg.pct = STATUS[tonumber(t.pct)] and tonumber(t.pct) or 0
        cfg.who = t.who == "party" and "party" or "me"
    end
end

local function save()
    pcall(Ext.IO.SaveFile, FILE, Ext.Json.Stringify({ pct = cfg.pct, who = cfg.who }))
end

local function avatars()
    local out, seen = {}, {}
    pcall(function()
        for _, row in pairs(Osi.DB_Avatars:Get(nil) or {}) do
            local u = Party.Norm(row[1])
            if u and not seen[u] then seen[u] = true; out[#out + 1] = u end
        end
    end)
    return out
end

local function has(u, s)
    local ok, v = pcall(Osi.HasActiveStatus, u, s)
    return ok and tonumber(v) == 1
end

local function dead(u)
    local ok, v = pcall(Osi.IsDead, u)
    return ok and tonumber(v) == 1
end

local function hp(u)
    local h, m = nil, nil
    pcall(function()
        local e = Ext.Entity.Get(u)
        h, m = tonumber(e.Health.Hp), tonumber(e.Health.MaxHp)
    end)
    return h, m
end

local function describe()
    if (cfg.pct or 0) <= 0 then return "Max HP bonus OFF" end
    return string.format("Max HP +%d %% (%s)", cfg.pct, cfg.who == "party" and "every party member" or "your character")
end

-- Bring every character in line with cfg: the wanted status on the targets,
-- no bonus status on anyone else.
local function sync(why)
    if Party.InCharacterCreation() then return end
    local want = {}
    if (cfg.pct or 0) > 0 then
        for _, u in ipairs(cfg.who == "party" and Party.Members() or avatars()) do want[u] = true end
    end
    local everyone = {}
    for _, u in ipairs(Party.Members()) do everyone[u] = true end
    for _, u in ipairs(avatars()) do everyone[u] = true end
    local s = STATUS[cfg.pct]
    for u in pairs(everyone) do
        if not dead(u) then
            if want[u] and s then
                if not has(u, s) then
                    local h0, m0 = hp(u)
                    local ok, err = pcall(Osi.ApplyStatus, u, s, -1, 1, u)
                    if ok and h0 and m0 and m0 > 0 then heals[u] = { at = now() + 600, hp = h0, max = m0 } end
                    Log.Write(string.format("HpBonus: %s -> %s (max HP %s before; %s)%s", name(u), s, tostring(m0), why,
                        ok and "" or (" FAILED " .. tostring(err))))
                end
            end
            for _, p in ipairs(LEVELS) do
                local other = STATUS[p]
                if (not want[u] or other ~= s) and has(u, other) then
                    pcall(Osi.RemoveStatus, u, other, u)
                    Log.Write(string.format("HpBonus: %s -> %s removed (%s)", name(u), other, why))
                end
            end
        end
    end
end

-- A character that just got the bonus keeps its share of HP (full stays full).
local function healTick(t)
    for u, h in pairs(heals) do
        if t >= h.at then
            heals[u] = nil
            local cur, max = hp(u)
            if cur and max and max > h.max then
                local wantHp = math.floor(h.hp / h.max * max + 0.5)
                Damage.HealBack(u, wantHp - cur, string.format("max HP %d -> %d with the bonus", h.max, max))
            elseif cur and max then
                Log.Write(string.format("HpBonus: %s max HP still %d after the bonus (BG3 hasn't applied it yet?)", name(u), max))
            end
        end
    end
end

local function tick()
    local t = now()
    if next(heals) then healTick(t) end
    if t - checkAt < 2000 then return end
    checkAt = t
    pcall(sync, "check")
end

local function toastTo(peer, text)
    if not peer then return end
    pcall(function() Ext.Net.PostMessageToUser(peer, Net.Channels.Toast, Ext.Json.Stringify({ text = text, secs = 3 })) end)
end

function M.Describe() return describe() end

function M.Register()
    load()
    ConsoleForward.Server("dag_hp", function(_, a, b)
        local c = ConsoleForward.Caller()
        a = a and tostring(a):lower() or ""
        if a == "off" or a == "0" then
            cfg.pct = 0
        elseif tonumber(a) then
            local v, best = tonumber(a), nil
            for _, p in ipairs(LEVELS) do
                if not best or math.abs(p - v) < math.abs(best - v) then best = p end
            end
            if best ~= v then Log.Write(string.format("HpBonus: +%s %% isn't offered, using +%d %% (25 / 50 / 75 / 100)", a, best)) end
            cfg.pct = best
            cfg.who = (tostring(b or ""):lower() == "party") and "party" or "me"
        elseif a ~= "" and a ~= "status" then
            Log.Write("HpBonus: usage !dag_hp 25|50|75|100 [party] | off | status")
        end
        if a ~= "" and a ~= "status" then
            save()
            pcall(sync, "!dag_hp")
        end
        Log.Write("HpBonus: " .. describe() .. " (kept for every save on this PC)")
        toastTo(c and c.peer, describe())
    end)
    Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function() pcall(sync, "level start") end)
    Ext.Osiris.RegisterListener("CharacterCreationFinished", 0, "after", function() pcall(sync, "character creation done") end)
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
    Log.Write("HpBonus: registered (" .. describe() .. "; !dag_hp 25|50|75|100 [party] | off)")
end

return M
