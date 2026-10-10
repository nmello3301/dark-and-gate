-- SPDX-License-Identifier: GPL-3.0-or-later
-- Finds real melee attack animations for the swing chain.
--
-- The chain used to play 01932f4d-... (Brawl's looping combat-idle id),
-- which only made Gale twitch. BG3's attack clips are reachable through
-- AnimationSet resources: AnimationBank.AnimationSubSets[*].Animation is a
-- map of animation-mapping id -> { ID = Animation resource id }, and each
-- Animation resource has a SourceFile (the .GR2 clip path). We scan that
-- once, in the background (a slice per tick), score clip names that look
-- like one-handed melee attacks, and use the best three for swings 1..3.
-- Results are cached in DarkAndGate/anim-cache.txt so later sessions skip
-- the scan.
--
-- Commands (client console):
--   !dag_anim_scan              rescan (ignores the cache)
--   !dag_anim_list [text]       log the top 25 candidates (optionally filtered)
--   !dag_anim_try <n> [res]     play candidate n now (res = use the resource id)
--   !dag_anim_set <swing> <n> [res]   use candidate n for swing 1, 2 or 3

local Log       = Ext.Require("Shared/Log.lua")
local Net       = Ext.Require("Shared/Net.lua")
local ClientNet = Ext.Require("Client/Net.lua")

local M = {}

local CACHE_PATH = "DarkAndGate/anim-cache-v3.txt"   -- fix5: v3 scoring
local STEP = 50                   -- inner iterations per tick (fix4: was 80)

local cands = {}                  -- { key, res, file, score }
local picks = {}                  -- swing index -> { id = string }
local state = "idle"              -- idle | scanning | done | failed
local co = nil
local stats = { sets = 0, maps = 0, t0 = 0 }

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

-- fix4: scoring v2, from the clip names the v1 scan found
-- (HUM_M_Rig_<weapon>_CMBT_Melee_RHand_NN_Attack...). Only real melee
-- combat clips qualify; the player's own rig (hum_m_rig) and one-handed
-- slashing (1HS) win; skills, dashes and other phases are pushed down.
-- fix5 (v3): BG3 splits a melee attack into _Antic / _Attack / _Recover
-- (+ _Cancel); only the _Attack part is a swing. v2 picked a _Cancel clip
-- and a zombie-rig clip. Now: basename must start with the player's rig
-- (HUM_M_Rig_), must contain "_attack", and "_hit" is no longer excluded
-- (it hid "..._Attack_Hit"-style names).
local EXCLUDE = { "hitreact", "react", "dodge", "block", "parry", "loop", "idle", "death", "knock",
                  "downed", "prepare", "_end", "_start", "offhand", "lhand", "unarmed", "shield",
                  "_add", "additive", "face", "_ik", "pose", "cine", "cancel", "antic", "recover",
                  "dash", "jump" }
local RIG_PREFIX = "hum_m_rig_"

local function score(file)
    local f = file:lower()
    local base = f:gsub("^.*/", "")
    if base:sub(1, #RIG_PREFIX) ~= RIG_PREFIX then return nil end
    if not f:find("_cmbt_", 1, true) or not f:find("_attack", 1, true) then return nil end
    if not (f:find("melee", 1, true) or f:find("_1hs_", 1, true) or f:find("_dflt_", 1, true)) then return nil end
    -- 2026-10-09: "_1hs_" also matched CMBT_Range_RHand_01_Attack (a ranged
    -- attack with no clip in melee stances): swing 1 played nothing.
    if f:find("_range_", 1, true) then return nil end
    for _, x in ipairs(EXCLUDE) do
        if f:find(x, 1, true) then return nil end
    end
    local s = 0
    if f:find("hum_m_rig_", 1, true) then s = s + 10 end
    if f:find("_1hs_", 1, true) then s = s + 5
    elseif f:find("_1hp_", 1, true) or f:find("_1hb_", 1, true) then s = s + 3 end
    if f:find("rhand", 1, true) then s = s + 2 end
    if f:find("melee", 1, true) then s = s + 3 end
    if f:find("skill", 1, true) then s = s - 6 end
    return s
end

local function short(f)
    return (f:gsub("^.*/", ""))
end

local function sortCands()
    table.sort(cands, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.file < b.file
    end)
end

local function autoPick()
    picks = {}
    local used = {}
    for _, c in ipairs(cands) do
        if not used[c.file] then
            used[c.file] = true
            picks[#picks + 1] = { id = c.key, file = c.file }
            if #picks >= 3 then break end
        end
    end
    for i, p in ipairs(picks) do
        Log.Write(string.format("Anims: swing %d -> %s (%s)", i, p.id, short(p.file)))
    end
    if #picks == 0 then Log.Write("Anims: no melee attack clip found -- swings will play no animation") end
end

local function saveCache()
    local lines = {}
    for _, c in ipairs(cands) do
        lines[#lines + 1] = string.format("%s|%s|%d|%s", c.key, c.res, c.score, c.file)
    end
    pcall(Ext.IO.SaveFile, CACHE_PATH, table.concat(lines, "\n"))
end

local OLD_CACHE_PATH = "DarkAndGate/anim-cache-v2.txt"
local function loadCache(path)
    local ok, s = pcall(Ext.IO.LoadFile, path or CACHE_PATH)
    if not ok or not s or s == "" then return false end
    cands = {}
    for line in s:gmatch("[^\r\n]+") do
        local key, res, sc, file = line:match("^([^|]*)|([^|]*)|(%-?%d+)|(.*)$")
        local sc2 = key and score(file) or nil
        if sc2 then cands[#cands + 1] = { key = key, res = res, score = sc2, file = file } end
    end
    sortCands()
    return #cands > 0
end

local function scanBody()
    local okA, sets = pcall(Ext.Resource.GetAll, "AnimationSet")
    if not okA or not sets then
        Log.Write("Anims: Ext.Resource.GetAll('AnimationSet') failed: " .. tostring(sets))
        state = "failed"
        return
    end
    local fileOf = {}             -- animation resource id -> SourceFile (or false)
    local found, seen = {}, {}
    local n = 0
    for _, setId in ipairs(sets) do
        stats.sets = stats.sets + 1
        local okS, res = pcall(Ext.Resource.Get, setId, "AnimationSet")
        local subs
        if okS and res then
            pcall(function() subs = res.AnimationBank.AnimationSubSets end)
        end
        if subs then
            local okP = pcall(function()
                for _, sub in pairs(subs) do
                    for key, desc in pairs(sub.Animation) do
                        stats.maps = stats.maps + 1
                        local rid = tostring(desc.ID)
                        local f = fileOf[rid]
                        if f == nil then
                            f = false
                            local okR, ar = pcall(Ext.Resource.Get, rid, "Animation")
                            if okR and ar then
                                local okF, sf = pcall(function() return ar.SourceFile end)
                                if okF and sf then f = tostring(sf) end
                            end
                            fileOf[rid] = f
                        end
                        if f then
                            local sc = score(f)
                            local k = tostring(key)
                            if sc and not seen[k] then
                                seen[k] = true
                                found[#found + 1] = { key = k, res = rid, file = f, score = sc }
                            end
                        end
                        n = n + 1
                        if n % STEP == 0 then coroutine.yield() end
                    end
                end
            end)
            if not okP then
                -- pairs() over a map inside a coroutine yield can fail on some
                -- builds; the set is skipped, the scan continues.
            end
        end
        n = n + 1
        if n % STEP == 0 then coroutine.yield() end
    end
    if #found == 0 and #cands > 0 then
        state = "done"
        Log.Write("Anims: scan found nothing new -- keeping the interim picks")
        return
    end
    cands = found
    sortCands()
    saveCache()
    state = "done"
    Log.Write(string.format("Anims: scan done in %.1f s -- %d sets, %d mappings, %d attack-like clips",
        (now() - stats.t0) / 1000, stats.sets, stats.maps, #cands))
    autoPick()
end

function M.StartScan(force)
    if state == "scanning" then return end
    if not force and loadCache() then
        state = "done"
        Log.Write(string.format("Anims: %d cached candidates (%s); !dag_anim_scan to rescan", #cands, CACHE_PATH))
        autoPick()
        return
    end
    -- fix5: while the v3 scan runs, use whatever the v2 cache still
    -- qualifies under v3 scoring so swings animate right away.
    if not force and loadCache(OLD_CACHE_PATH) then
        Log.Write(string.format("Anims: %d interim candidates from the v2 cache", #cands))
        autoPick()
    end
    stats = { sets = 0, maps = 0, t0 = now() }
    state = "scanning"
    co = coroutine.create(scanBody)
    Log.Write("Anims: scanning animation sets in the background...")
end

local function tick()
    if state ~= "scanning" or not co then return end
    local ok, err = coroutine.resume(co)
    if not ok then
        state = "failed"
        Log.Write("Anims: scan error: " .. tostring(err))
    elseif coroutine.status(co) == "dead" and state == "scanning" then
        state = "done"
    end
end

-- Animation id for swing `i` (1..3), or nil while unknown.
local enabled = true
function M.ForSwing(i)
    if not enabled then return nil end
    local p = picks[i] or picks[1]
    return p and p.id or nil
end

function M.State() return state end

local function candById(n)
    n = tonumber(n)
    return n and cands[n] or nil
end

function M.Register()
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
    Ext.Events.SessionLoaded:Subscribe(function() pcall(M.StartScan, false) end)

    Ext.RegisterConsoleCommand("dag_anim_scan", function() M.StartScan(true) end)
    Ext.RegisterConsoleCommand("dag_anim", function(_, a)
        enabled = not (a == "off" or a == "0")
        Log.Write("Anims: swing animations " .. (enabled and "ON" or "OFF"))
    end)
    Ext.RegisterConsoleCommand("dag_anim_list", function(_, filter)
        local f = filter and filter:lower() or nil
        local shown = 0
        Log.Write(string.format("Anims: %d candidates (state=%s)%s", #cands, state,
            f and (" filter=" .. f) or ""))
        for i, c in ipairs(cands) do
            if not f or c.file:lower():find(f, 1, true) then
                Log.Write(string.format("  [%d] score=%d key=%s %s", i, c.score, c.key, short(c.file)))
                shown = shown + 1
                if shown >= 25 then break end
            end
        end
    end)
    Ext.RegisterConsoleCommand("dag_anim_try", function(_, n, mode)
        local c = candById(n)
        if not c then Log.Write("Anims: usage !dag_anim_try <n> [res]  (see !dag_anim_list)"); return end
        local id = (mode == "res") and c.res or c.key
        ClientNet.PlayAnim(id)
        Log.Write(string.format("Anims: try [%s] %s id=%s (%s)", tostring(n), mode == "res" and "res" or "key", id, c.file))
    end)
    Ext.RegisterConsoleCommand("dag_anim_set", function(_, sw, n, mode)
        local i, c = tonumber(sw), candById(n)
        if not i or i < 1 or i > 3 or not c then
            Log.Write("Anims: usage !dag_anim_set <1-3> <n> [res]"); return
        end
        picks[i] = { id = (mode == "res") and c.res or c.key, file = c.file }
        Log.Write(string.format("Anims: swing %d -> %s (%s)", i, picks[i].id, c.file))
    end)
    Log.Write("Anims: registered (!dag_anim_scan / _list / _try / _set)")
end

return M
