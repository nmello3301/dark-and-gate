-- SPDX-License-Identifier: GPL-3.0-or-later
-- Finds BG3's own jump clips for the first-person jump.
--
-- BG3's Jump is a five-part clip set on every rig/stance, e.g.
--   HUM_M_Rig_DFLT_CMBT_Skill_JumpFlight_01_Cast            takeoff
--   HUM_M_Rig_DFLT_CMBT_Skill_JumpFlight_01_Ascend          rising
--   HUM_M_Rig_DFLT_CMBT_Skill_JumpFlight_01_Falling         hang / falling
--   HUM_M_Rig_DFLT_CMBT_Skill_JumpFlight_01_Descend         coming down
--   HUM_M_Rig_DFLT_CMBT_Skill_JumpFlight_Peace_01_Recover   landing
-- (names from the game's Models.pak listing, 2026-10-09). v1 excluded
-- "skill" and so only found cutscene clips.
--
-- Same resource walk as Client/Combat/Anims.lua (AnimationSet ->
-- AnimationBank.AnimationSubSets[*].Animation[key].ID -> Animation
-- resource SourceFile). Every clip on the player's rig whose name contains
-- "jump" is cached (DarkAndGate/anim-cache-jump-v2.txt) with its Duration;
-- phases are assigned from the file name at load, so changing the phase
-- rules doesn't need a rescan.
--
-- Commands (client console):
--   !dag_jump_anims [text]          list candidates (optionally filtered)
--   !dag_jump_anim <phase> <n>      use candidate n for cast|ascend|hang|descend|land
--   !dag_jump_anim <phase> none     play nothing for that phase
--   !dag_jump_anim_scan             rescan (ignores the cache)
--   !dag_anim_vars [text]           dump the anim blueprint variables (play-rate probe)

local Log = Ext.Require("Shared/Log.lua")
local movement = Ext.Require("data/movement.lua")
local Tags = Ext.Require("Client/AnimLib/Tags.lua")

local M = {}

local CACHE_PATH = "DarkAndGate/anim-cache-jump-v2.txt"
local STEP = 25                 -- inner iterations per tick (v1's 50 cost 2-6 ms ticks)
local RIG_PREFIX = "hum_m_rig_"
local PHASES = { "cast", "ascend", "hang", "descend", "land" }

local cands = {}        -- { key, res, file, phase (or nil), score, dur }
local picks = {}        -- phase -> cand (or false = none)
local state = "idle"    -- idle | scanning | done | failed
local co = nil
local t0 = 0

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local function short(f) return (f:gsub("^.*/", "")) end

local PHASE_WORDS = {
    { "cast",    { "_cast" } },
    { "ascend",  { "_ascend" } },
    { "hang",    { "_falling", "_loop" } },
    { "descend", { "_descend" } },
    { "land",    { "_recover" } },
}
local EXCLUDE = { "barbarian", "scene", "cine", "_ik", "additive", "_add", "face", "wing" }

local function baseName(file) return (file:lower():gsub("^.*/", "")) end

-- Worth caching: on the player's rig with "jump" in the name.
local function isJumpFile(file)
    local base = baseName(file)
    return base:sub(1, #RIG_PREFIX) == RIG_PREFIX and base:find("jump", 1, true) ~= nil
end

-- Returns phase, score (or nil when the clip is not part of the jump set).
local function classify(file)
    local base = baseName(file)
    if base:sub(1, #RIG_PREFIX) ~= RIG_PREFIX or not base:find("jumpflight", 1, true) then return nil end
    for _, x in ipairs(EXCLUDE) do
        if base:find(x, 1, true) then return nil end
    end
    local phase
    for _, pw in ipairs(PHASE_WORDS) do
        for _, w in ipairs(pw[2]) do
            if base:find(w, 1, true) then phase = pw[1]; break end
        end
        if phase then break end
    end
    if not phase then return nil end
    local s = 0
    if base:find("_dflt_", 1, true) then s = s + 5 end     -- no-weapon stance
    if base:find("_cmbt_skill_", 1, true) then s = s + 2 end
    if base:find("peace", 1, true) then s = s + 2 end      -- out-of-combat landing
    if base:find("_spl_", 1, true) then s = s - 1 end
    return phase, s
end

local function durationOf(res)
    local ok, ar = pcall(Ext.Resource.Get, res, "Animation")
    if not ok or not ar then return 0 end
    local okD, d = pcall(function() return ar.Duration end)
    return (okD and tonumber(d)) or 0
end

local function sortCands()
    table.sort(cands, function(a, b)
        local pa, pb = a.phase or "~", b.phase or "~"
        if pa ~= pb then return pa < pb end
        if a.score ~= b.score then return a.score > b.score end
        return a.file < b.file
    end)
end

local function autoPick()
    picks = {}
    for _, c in ipairs(cands) do
        if c.phase and picks[c.phase] == nil then picks[c.phase] = c end
    end
    for _, ph in ipairs(PHASES) do
        local c = picks[ph]
        if c then
            if (c.dur or 0) <= 0 then c.dur = durationOf(c.res) end
            Log.Write(string.format("JumpAnims: %s -> %s dur=%.2fs (%s)", ph, c.key, c.dur or 0, short(c.file)))
        else
            Log.Write("JumpAnims: " .. ph .. " -> (none found)")
        end
    end
end

local function saveCache()
    local lines = {}
    for _, c in ipairs(cands) do
        lines[#lines + 1] = string.format("%s|%s|%.3f|%s", c.key, c.res, c.dur or 0, c.file)
    end
    pcall(Ext.IO.SaveFile, CACHE_PATH, table.concat(lines, "\n"))
end

local function loadCache()
    local ok, s = pcall(Ext.IO.LoadFile, CACHE_PATH)
    if not ok or not s or s == "" then return false end
    cands = {}
    for line in s:gmatch("[^\r\n]+") do
        local key, res, dur, file = line:match("^([^|]*)|([^|]*)|([%d%.]+)|(.*)$")
        if key then
            local ph, sc = classify(file)
            cands[#cands + 1] = { key = key, res = res, phase = ph, score = sc or 0,
                                  dur = tonumber(dur) or 0, file = file }
        end
    end
    sortCands()
    return #cands > 0
end

local function scanBody()
    local okA, sets = pcall(Ext.Resource.GetAll, "AnimationSet")
    if not okA or not sets then
        Log.Write("JumpAnims: Ext.Resource.GetAll('AnimationSet') failed: " .. tostring(sets))
        state = "failed"
        return
    end
    local fileOf, found, seen = {}, {}, {}
    local n = 0
    for _, setId in ipairs(sets) do
        local okS, res = pcall(Ext.Resource.Get, setId, "AnimationSet")
        local subs
        if okS and res then pcall(function() subs = res.AnimationBank.AnimationSubSets end) end
        if subs then
            pcall(function()
                for _, sub in pairs(subs) do
                    for key, desc in pairs(sub.Animation) do
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
                        if f and isJumpFile(f) then
                            local k = tostring(key)
                            if not seen[k] then
                                seen[k] = true
                                local ph, sc = classify(f)
                                found[#found + 1] = { key = k, res = rid, file = f, phase = ph, score = sc or 0,
                                                      dur = durationOf(rid) }
                            end
                        end
                        n = n + 1
                        if n % STEP == 0 then coroutine.yield() end
                    end
                end
            end)
        end
        n = n + 1
        if n % STEP == 0 then coroutine.yield() end
    end
    cands = found
    sortCands()
    saveCache()
    state = "done"
    Log.Write(string.format("JumpAnims: scan done in %.1f s -- %d jump clips (cached in %s)",
        (now() - t0) / 1000, #cands, CACHE_PATH))
    autoPick()
end

function M.StartScan(force)
    if state == "scanning" then return end
    if not force and loadCache() then
        state = "done"
        Log.Write(string.format("JumpAnims: %d cached jump clips (%s)", #cands, CACHE_PATH))
        autoPick()
        return
    end
    t0 = now()
    state = "scanning"
    co = coroutine.create(scanBody)
    Log.Write("JumpAnims: scanning animation sets for jump clips in the background (one time, ~2 min)...")
end

local function tick()
    if state ~= "scanning" or not co then return end
    local ok, err = coroutine.resume(co)
    if not ok then
        state = "failed"
        Log.Write("JumpAnims: scan error: " .. tostring(err))
    elseif coroutine.status(co) == "dead" and state == "scanning" then
        state = "done"
    end
end

-- { key = <anim mapping id>, dur = seconds } for a phase, or nil.
-- 2026-10-09: the ids live in data/movement.lua (jump.anims); the scan
-- took ~4 min and jumps before it finished had no animation. A pick made
-- with !dag_jump_anim (or a finished rescan) overrides the data.
-- Browser tags for the jump phases win over everything below.
local TAG_FOR_PHASE = { ascend = "jump_start", hang = "jump_loop", land = "jump_land" }

function M.Pick(phase)
    local tag = TAG_FOR_PHASE[phase]
    local tagged = tag and Tags.ForPlayer(tag)
    if tagged then return { key = tagged.key, dur = tagged.dur or 0, file = tagged.file } end
    local c = picks[phase]
    if c == false then return nil end
    if c then return { key = c.key, dur = c.dur or 0, file = c.file } end
    local d = movement.jump.anims and movement.jump.anims[phase]
    if d then return { key = d.key, dur = d.dur or 0, file = "data" } end
    return nil
end

function M.State() return state == "idle" and "data" or state end

function M.Register()
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
    -- No scan at load: the clip ids come from data/movement.lua.
    -- !dag_jump_anim_scan rescans (and then overrides the data picks).

    Ext.RegisterConsoleCommand("dag_jump_anim_scan", function() M.StartScan(true) end)
    Ext.RegisterConsoleCommand("dag_jump_anims", function(_, filter)
        if #cands == 0 then loadCache() end
        local f = filter and filter:lower() or nil
        Log.Write(string.format("JumpAnims: %d candidates (state=%s)", #cands, state))
        local shown = 0
        for i, c in ipairs(cands) do
            if not f or c.file:lower():find(f, 1, true) then
                Log.Write(string.format("  [%d] %-7s score=%d dur=%.2fs key=%s %s",
                    i, c.phase or "-", c.score, c.dur or 0, c.key, short(c.file)))
                shown = shown + 1
                if shown >= 60 then break end
            end
        end
    end)
    Ext.RegisterConsoleCommand("dag_jump_anim", function(_, phase, n)
        local valid = false
        for _, ph in ipairs(PHASES) do if ph == phase then valid = true end end
        if not valid then
            Log.Write("JumpAnims: usage !dag_jump_anim <cast|ascend|hang|descend|land> <n|none>"); return
        end
        if n == "none" then
            picks[phase] = false
            Log.Write("JumpAnims: " .. phase .. " -> none")
            return
        end
        if #cands == 0 then loadCache() end
        local c = cands[tonumber(n) or -1]
        if not c then Log.Write("JumpAnims: no candidate " .. tostring(n) .. " (see !dag_jump_anims)"); return end
        if (c.dur or 0) <= 0 then c.dur = durationOf(c.res) end
        picks[phase] = c
        Log.Write(string.format("JumpAnims: %s -> %s dur=%.2fs (%s)", phase, c.key, c.dur or 0, short(c.file)))
    end)
    -- Probe for a per-character anim play-rate lever (docs/spikes/m1b-anim-speed.md):
    -- dumps the animation blueprint's variables (name, type, index) and the
    -- live value of each one on the controlled character. Read-only.
    Ext.RegisterConsoleCommand("dag_anim_vars", function(_, filter)
        local f = filter and filter:lower() or nil
        local ents = Ext.Entity.GetAllEntitiesWithComponent("ClientControl")
        local e = ents and ents[1]
        if not e then Log.Write("AnimVars: no controlled entity"); return end
        local ok, err = pcall(function()
            local inst = e.AnimationBlueprint.Instance
            -- Names: the blueprint resource (the path QSAT uses), else the
            -- instance's parent template. Values: Instance.Variables[i] is
            -- a { Type, Value } table.
            local names, src = {}, "Resource.Blueprints[1]"
            pcall(function()
                for i, v in ipairs(e.AnimationBlueprint.Resource.Blueprints[1].Variables) do names[i] = tostring(v.Name) end
            end)
            if #names == 0 then
                src = "Instance.Parent"
                pcall(function()
                    for _, v in ipairs(inst.Parent.Variables) do names[v.Index + 1] = tostring(v.Name) end
                end)
            end
            Log.Write(string.format("AnimVars: %d variable names (%s), %d instance values", #names, src, #inst.Variables))
            local shown = 0
            for i, name in ipairs(names) do
                if not f or name:lower():find(f, 1, true) then
                    local okV, val = pcall(function() return inst.Variables[i] end)
                    local vs
                    local okT, typ = pcall(function() return val.Type end)
                    local okW, v2 = pcall(function() return val.Value end)
                    if okV and okT and okW then
                        vs = string.format("type=%s value=%s", tostring(typ), tostring(v2))
                    else
                        vs = okV and tostring(val) or ("<" .. tostring(val) .. ">")
                    end
                    Log.Write(string.format("  [%d] %-40s %s", i, name, vs))
                    shown = shown + 1
                    if shown >= 200 then break end
                end
            end
        end)
        if not ok then Log.Write("AnimVars: ERROR " .. tostring(err)) end
    end)

    Log.Write("JumpAnims: registered (!dag_jump_anims / !dag_jump_anim / !dag_jump_anim_scan / !dag_anim_vars)")
end

return M
