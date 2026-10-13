-- SPDX-License-Identifier: GPL-3.0-or-later
-- The AI pace per side (developer 2026-10-13: "have the difficulty scale with
-- the enemies combat pace"). Enemies start an action every
-- data/realtime.lua enemy_pace_s[difficulty] seconds (Explorer 10, Balanced 6,
-- Tactician 5, Honour 4); your side (companions and NPC allies) every
-- action_interval_s (4 s). Initiative still spreads each fighter's pace a
-- little (initiative_spread).
--
-- The difficulty is read the way BG3's story (and Brawl's Utils.getDifficulty)
-- reads it, from the ruleset modifiers (Osiris GetRulesetModifier*, bare
-- GUIDs as Brawl passes them; values from Public/Shared/Ruleset/
-- RulesetValues.lsx, docs/se-api-notes.md):
--   HONOUR_STATS on, or SCRIPTED_COMBAT_MECHANICS HARD with IRONMAN_MODE on
--                                                    -> Honour (the second is Brawl's test)
--   AI_LETHALITY FORGIVING / BALANCED / BRUTAL       -> Explorer / Balanced / Tactician
--   SCRIPTED_COMBAT_MECHANICS EASY / MEDIUM / HARD   (when AI_LETHALITY can't be read)
--   the game's ruleset list (Ruleset component)      (when neither can)
-- A custom difficulty counts as its AI lethality ("Enemy AI" on BG3's custom
-- screen). A fighter's pace is set when
-- it joins a fight (Brawl's Roster.addBrawler, DAG patch), so a difficulty
-- change applies from the next fight.
--   !dag_enemy_pace [<s>|auto]   the enemies' pace: fixed, or by difficulty again
--   !dag_ai_interval <s>         your side's pace (Server/BrawlAdapter.lua)
-- (server console, or the client console: Shared/ConsoleForward.lua)

local Log            = Ext.Require("Shared/Log.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")
local Party          = Ext.Require("Server/Party.lua")
local cfg            = Ext.Require("data/realtime.lua")

local M = {}

local HONOUR    = "ef0506df-da9f-40e2-903a-1349523c1ae4"   -- HONOUR_STATS (bool)
local IRONMAN   = "338450d9-d77d-4950-9e1e-0e7f12210bb3"   -- IRONMAN_MODE (bool)
local LETHALITY = "968ce114-d656-407c-88c2-0c071fe2181b"   -- AI_LETHALITY
local SCRIPTED  = "cac2d8bd-c197-4a84-9df1-f86f54ad4521"   -- SCRIPTED_COMBAT_MECHANICS
local BY_LETHALITY = { AILETHALITY_FORGIVING = "explorer", AILETHALITY_BALANCED = "balanced", AILETHALITY_BRUTAL = "tactician" }
local BY_SCRIPTED  = { EASY = "explorer", MEDIUM = "balanced", HARD = "tactician" }
-- Rulesets.lsx: DIFFICULTY_EASY / _MEDIUM / _HARD, RULESET_HONOUR (Honour = HARD + HONOUR).
local BY_RULESET = {
    ["993bc2a5-ab96-4cfe-a240-4e991696af6c"] = "explorer", ["d6522dc4-1d76-462e-9959-e8a0fd76f4ed"] = "balanced",
    ["3f777143-d1de-4035-b9e5-23763148b1fd"] = "tactician", ["5d595a7a-6182-4559-b404-ed7cc7ad8ada"] = "honour",
}
local RANK  = { explorer = 1, balanced = 2, tactician = 3, honour = 4 }
local NAMES = { explorer = "Explorer", balanced = "Balanced", tactician = "Tactician", honour = "Honour" }

local override = nil              -- !dag_enemy_pace <s>
local cache = { at = -1e9 }

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

-- BG3's difficulty: "explorer" | "balanced" | "tactician" | "honour", and how it was read.
function M.Difficulty()
    local t = now()
    if cache.key and t - cache.at < 5000 then return cache.key, cache.how end
    local key, how = nil, nil
    local okS, scripted = pcall(function() return Osi.GetRulesetModifierString(SCRIPTED) end)
    scripted = okS and scripted ~= nil and tostring(scripted) or nil
    local okH, h = pcall(function() return Osi.GetRulesetModifierBool(HONOUR) end)
    if okH and tonumber(h) == 1 then key, how = "honour", "HONOUR_STATS on" end
    if not key and scripted == "HARD" then
        local okI, i = pcall(function() return Osi.GetRulesetModifierBool(IRONMAN) end)
        if okI and tonumber(i) == 1 then key, how = "honour", "SCRIPTED_COMBAT_MECHANICS HARD + IRONMAN_MODE" end
    end
    if not key then
        local okL, l = pcall(function() return Osi.GetRulesetModifierString(LETHALITY) end)
        if okL and l ~= nil and BY_LETHALITY[tostring(l)] then key, how = BY_LETHALITY[tostring(l)], "AI_LETHALITY " .. tostring(l) end
    end
    if not key and scripted and BY_SCRIPTED[scripted] then
        key, how = BY_SCRIPTED[scripted], "SCRIPTED_COMBAT_MECHANICS " .. scripted
    end
    if not key then
        pcall(function()
            local e = Ext.Entity.GetAllEntitiesWithComponent("Ruleset")[1]
            for _, g in pairs(e.Ruleset.Rulesets) do
                local k = BY_RULESET[tostring(g)]
                if k and (not key or RANK[k] > RANK[key]) then key, how = k, "the game's rulesets" end
            end
        end)
    end
    if not key then key, how = "balanced", "difficulty unreadable" end
    cache.at, cache.key, cache.how = t, key, how
    return key, how
end

-- The enemies' pace in seconds, and where it comes from.
function M.EnemySeconds()
    if override then return override, "fixed by !dag_enemy_pace" end
    local key, how = M.Difficulty()
    local s = tonumber((cfg.enemy_pace_s or {})[key]) or tonumber(cfg.action_interval_s) or 4
    return s, NAMES[key] .. ", " .. how
end

function M.YourSideSeconds() return tonumber(cfg.action_interval_s) or 4 end

-- Your side: party members and NPCs allied to the host. Everyone else in a
-- fight (enemies, and neutrals that joined it) takes the enemies' pace.
function M.OnYourSide(uuid)
    if Party.IsMember(uuid) then return true end
    local ok, v = pcall(function() return Osi.IsAlly(Osi.GetHostCharacter(), uuid) end)
    return ok and tonumber(v) == 1
end

function M.SecondsFor(uuid)
    if M.OnYourSide(uuid) then return M.YourSideSeconds() end
    return (M.EnemySeconds())
end

function M.Summary()
    local s, why = M.EnemySeconds()
    return string.format("enemies act every %.1f s (%s), your side every %.1f s", s, why, M.YourSideSeconds())
end

function M.Register()
    -- Brawl's Roster.addBrawler (DAG patch): the fighter's interval in ms,
    -- Brawl's own initiative scaling around its side's pace.
    DAG_ActionInterval = function(uuid, initiative)
        local ok, ms = pcall(function()
            local S = BrawlState.Settings
            local saved = S.ActionInterval
            S.ActionInterval = M.SecondsFor(Party.Norm(uuid))
            local okC, v = pcall(TurnOrder.calculateActionInterval, initiative)
            S.ActionInterval = saved
            return okC and v or nil
        end)
        return ok and ms or nil
    end
    Ext.Osiris.RegisterListener("CombatStarted", 1, "after", function()
        cache.at = -1e9
        Log.Write("Pace: " .. M.Summary())
    end)
    ConsoleForward.Server("dag_enemy_pace", function(_, v)
        if v == "auto" then override = nil
        elseif tonumber(v) then override = math.max(1.0, tonumber(v)) end
        cache.at = -1e9
        Log.Write("Pace: " .. M.Summary() .. " (from the next fight)")
    end)
    local p = cfg.enemy_pace_s or {}
    Log.Write(string.format("Pace: registered (enemies by BG3's difficulty: Explorer %s / Balanced %s / Tactician %s / Honour %s s; your side %.1f s; !dag_enemy_pace [<s>|auto])",
        tostring(p.explorer), tostring(p.balanced), tostring(p.tactician), tostring(p.honour), M.YourSideSeconds()))
end

return M
