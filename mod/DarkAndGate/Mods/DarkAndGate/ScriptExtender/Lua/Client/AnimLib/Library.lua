-- SPDX-License-Identifier: GPL-3.0-or-later
-- Animation library for the animation browser (Client/AnimLib/Browser.lua).
--
-- For one target character it lists the animations that character can
-- actually play:
--   1. Its own AnimationSet resources, from the entity:
--        ent.AnimationSet.Entries[i].Resource          (path "AnimationSet")
--        ent.AnimationWaterfall.Waterfall[i].Resource  (path "Waterfall")
--      Each set: AnimationBank.AnimationSubSets[subset].Animation =
--      map mappingId -> { ID = Animation resource id }; the Animation
--      resource has SourceFile and Duration.
--   2. If neither component yields a set: the global index (every
--      AnimationSet in the game) filtered by the target's rig prefix,
--      flagged "fallback list".
-- Duplicates are collapsed: one entry per clip file, carrying every
-- mapping id (and subset) that resolves to it.
--
-- Rig = the majority "<RACE>_<BODY>" prefix of the clip names (HUM_M,
-- HUM_F, HUM_MS, DWR_M, ...).
--
-- Work is spread across ticks with a time budget (Ext.Timer.MicrosecTime),
-- and cached per rig + set signature in DarkAndGate/animlib-<rig>-<sig>.txt,
-- so reopening for the same character is instant.
--
-- The global index (coverage: which rigs/sets contain a mapping id) is
-- built only on request and cached in DarkAndGate/animlib-global.txt.

local Log = Ext.Require("Shared/Log.lua")

local M = {}

local BUDGET_US = 700        -- per tick
local CACHE_VER = "v1"

local function us() return Ext.Timer.MicrosecTime() end

-- Animation resource id -> { file = path, dur = seconds } (or false).
local resCache = {}
local function resolve(rid)
    local r = resCache[rid]
    if r ~= nil then return r end
    r = false
    local ok, ar = pcall(Ext.Resource.Get, rid, "Animation")
    if ok and ar then
        local okF, sf = pcall(function() return ar.SourceFile end)
        local okD, d = pcall(function() return ar.Duration end)
        if okF and sf then r = { file = tostring(sf), dur = (okD and tonumber(d)) or 0 } end
    end
    resCache[rid] = r
    return r
end

local function baseName(path) return (tostring(path):gsub("^.*[/\\]", ""):gsub("%.[Gg][Rr]2$", "")) end

function M.RigOf(base)
    return base:match("^(%a+_%a+)_[Rr]ig_")
end

-- Parse "<RIG>_Rig_<family>_<cat>_..._<phase>" into family / categories / phase.
function M.Parse(base)
    local toks = {}
    for t in base:gmatch("[^_]+") do toks[#toks + 1] = t end
    local ri
    for i, t in ipairs(toks) do if t:lower() == "rig" then ri = i; break end end
    local info = { family = "?", cats = {}, phase = "?" }
    if not ri then return info end
    info.family = toks[ri + 1] or "?"
    local last
    for i = #toks, ri + 2, -1 do
        if not toks[i]:match("^%d+$") then last = i; break end
    end
    if last then info.phase = toks[last] end
    for i = ri + 2, (last or #toks + 1) - 1 do
        local t = toks[i]
        if not t:match("^%d+$") then info.cats[#info.cats + 1] = t end
    end
    return info
end

-- ---------------------------------------------------------------------
-- Building a target's list
-- ---------------------------------------------------------------------
local B = {
    state = "idle",       -- idle | building | ready | failed
    status = "",
    target = nil,         -- { uuid, name }
    rig = "?",
    sets = {},
    source = "",
    fallback = false,
    clips = {},           -- sorted list
    byKey = {},           -- mappingId -> clip
    co = nil,
    mappings = 0,
    t0 = 0,
}
M.B = B

local function setIdsOf(ent)
    local ids, seen, source = {}, {}, nil
    local function add(r)
        r = r and tostring(r) or ""
        if r ~= "" and not seen[r] then seen[r] = true; ids[#ids + 1] = r end
    end
    pcall(function()
        for _, e in ipairs(ent.AnimationSet.Entries) do add(e.Resource) end
    end)
    if #ids > 0 then source = "AnimationSet component" end
    if #ids == 0 then
        pcall(function()
            for _, e in ipairs(ent.AnimationWaterfall.Waterfall) do add(e.Resource) end
        end)
        if #ids > 0 then source = "AnimationWaterfall component" end
    end
    table.sort(ids)
    return ids, source
end

local function signature(ids)
    local h = 5381
    for _, id in ipairs(ids) do
        for i = 1, #id do h = (h * 33 + id:byte(i)) % 4294967296 end
    end
    return string.format("%08x", h)
end

local function cachePath(rig, sig) return string.format("DarkAndGate/animlib-%s-%s.txt", rig, sig) end

-- Rows: { key, subset, res, dur, file }
local function finish(rows)
    local byFile, rigCount = {}, {}
    B.byKey = {}
    for _, r in ipairs(rows) do
        local base = baseName(r.file)
        local c = byFile[base]
        if not c then
            local p = M.Parse(base)
            c = { base = base, file = r.file, res = r.res, dur = r.dur, keys = {}, subsets = {},
                  family = p.family, cats = p.cats, phase = p.phase, rig = M.RigOf(base) or "?",
                  lower = base:lower() }
            byFile[base] = c
            if c.rig ~= "?" then rigCount[c.rig] = (rigCount[c.rig] or 0) + 1 end
        end
        c.keys[#c.keys + 1] = r.key
        c.subsets[r.subset or "?"] = true
        B.byKey[r.key] = c
    end
    local clips = {}
    for _, c in pairs(byFile) do clips[#clips + 1] = c end
    table.sort(clips, function(a, b) return a.base < b.base end)
    B.clips = clips
    if B.rig == "?" then
        local best, n = "?", 0
        for r, k in pairs(rigCount) do if k > n then best, n = r, k end end
        B.rig = best
    end
end

local function saveCache(rows, sig)
    local lines = { string.format("#%s rig=%s source=%s sets=%s", CACHE_VER, B.rig, B.source, table.concat(B.sets, ",")) }
    for _, r in ipairs(rows) do
        lines[#lines + 1] = string.format("%s|%s|%s|%.3f|%s", r.key, r.subset or "", r.res, r.dur or 0, r.file)
    end
    pcall(Ext.IO.SaveFile, cachePath(B.rig, sig), table.concat(lines, "\n"))
end

local function loadCache(rig, sig)
    local ok, s = pcall(Ext.IO.LoadFile, cachePath(rig, sig))
    if not ok or not s or s == "" then return nil end
    local rows = {}
    for line in s:gmatch("[^\r\n]+") do
        if line:sub(1, 1) ~= "#" then
            local key, sub, res, dur, file = line:match("^([^|]*)|([^|]*)|([^|]*)|([%d%.]+)|(.*)$")
            if key then rows[#rows + 1] = { key = key, subset = sub, res = res, dur = tonumber(dur) or 0, file = file } end
        end
    end
    return #rows > 0 and rows or nil
end

-- Pre-pass: the rig from a handful of clips, so the cache name is known
-- before the full walk. Returns rig or "?".
local function quickRig(ids)
    local counts, n = {}, 0
    for _, id in ipairs(ids) do
        local ok, res = pcall(Ext.Resource.Get, id, "AnimationSet")
        if ok and res then
            pcall(function()
                for _, sub in pairs(res.AnimationBank.AnimationSubSets) do
                    for _, desc in pairs(sub.Animation) do
                        local r = resolve(tostring(desc.ID))
                        local rig = r and M.RigOf(baseName(r.file))
                        if rig then counts[rig] = (counts[rig] or 0) + 1 end
                        n = n + 1
                        if n >= 60 then error("enough") end
                    end
                end
            end)
        end
        if n >= 60 then break end
    end
    local best, c = "?", 0
    for r, k in pairs(counts) do if k > c then best, c = r, k end end
    return best
end

local function buildBody(ids, sig)
    local rows = {}
    local budgetStart = us()
    local function spend()
        if us() - budgetStart > BUDGET_US then
            coroutine.yield()
            budgetStart = us()
        end
    end
    for si, id in ipairs(ids) do
        local ok, res = pcall(Ext.Resource.Get, id, "AnimationSet")
        if ok and res then
            local subs
            pcall(function() subs = res.AnimationBank.AnimationSubSets end)
            if subs then
                -- Collect the pairs first (iterating a userdata map across a
                -- coroutine yield is not safe), then resolve with a budget.
                local pending = {}
                pcall(function()
                    for subName, sub in pairs(subs) do
                        for key, desc in pairs(sub.Animation) do
                            pending[#pending + 1] = { tostring(key), tostring(subName), tostring(desc.ID) }
                        end
                    end
                end)
                for _, p in ipairs(pending) do
                    local r = resolve(p[3])
                    if r then
                        rows[#rows + 1] = { key = p[1], subset = p[2], res = p[3], dur = r.dur, file = r.file }
                    end
                    B.mappings = B.mappings + 1
                    if B.mappings % 100 == 0 then
                        B.status = string.format("building: set %d/%d, %d mappings", si, #ids, B.mappings)
                    end
                    spend()
                end
            end
        end
        spend()
    end
    finish(rows)
    saveCache(rows, sig)
    B.state = "ready"
    B.status = string.format("%d clips (%d mappings) in %.1f s", #B.clips, #rows, (us() - B.t0) / 1e6)
    Log.Write(string.format("AnimLib: %s rig=%s source=%s sets=%d -> %s (cached %s)",
        B.target and B.target.name or "?", B.rig, B.source, #B.sets, B.status, cachePath(B.rig, sig)))
end

-- Global index (coverage + fallback list): setId -> rig, key -> { setId -> file }.
local G = { state = "idle", status = "", byKey = {}, setRig = {}, rows = 0, co = nil }
M.G = G
local GLOBAL_PATH = "DarkAndGate/animlib-global.txt"

local function globalLoad()
    local ok, s = pcall(Ext.IO.LoadFile, GLOBAL_PATH)
    if not ok or not s or s == "" then return false end
    G.byKey, G.setRig, G.rows = {}, {}, 0
    for line in s:gmatch("[^\r\n]+") do
        local set, rig, key, res, dur, file = line:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([%d%.]+)|(.*)$")
        if set then
            G.setRig[set] = rig
            local k = G.byKey[key]
            if not k then k = {}; G.byKey[key] = k end
            k[set] = { file = file, res = res, dur = tonumber(dur) or 0 }
            G.rows = G.rows + 1
        end
    end
    G.state = "ready"
    G.status = string.format("%d mappings in %d sets (cached)", G.rows, (function() local n = 0 for _ in pairs(G.setRig) do n = n + 1 end return n end)())
    return true
end

local function globalBody()
    local okA, sets = pcall(Ext.Resource.GetAll, "AnimationSet")
    if not okA or not sets then G.state = "failed"; G.status = "GetAll failed"; return end
    local lines = {}
    local budgetStart = us()
    local t0 = us()
    for si, setId in ipairs(sets) do
        local ok, res = pcall(Ext.Resource.Get, setId, "AnimationSet")
        local pending = {}
        if ok and res then
            pcall(function()
                for _, sub in pairs(res.AnimationBank.AnimationSubSets) do
                    for key, desc in pairs(sub.Animation) do
                        pending[#pending + 1] = { tostring(key), tostring(desc.ID) }
                    end
                end
            end)
        end
        local rigCount, setRows = {}, {}
        for _, p in ipairs(pending) do
            local r = resolve(p[2])
            if r then
                local rig = M.RigOf(baseName(r.file))
                if rig then rigCount[rig] = (rigCount[rig] or 0) + 1 end
                setRows[#setRows + 1] = { p[1], p[2], r }
            end
            if us() - budgetStart > BUDGET_US then coroutine.yield(); budgetStart = us() end
        end
        local rig, n = "?", 0
        for r, k in pairs(rigCount) do if k > n then rig, n = r, k end end
        G.setRig[tostring(setId)] = rig
        for _, sr in ipairs(setRows) do
            local k = G.byKey[sr[1]]
            if not k then k = {}; G.byKey[sr[1]] = k end
            k[tostring(setId)] = { file = sr[3].file, res = sr[2], dur = sr[3].dur }
            lines[#lines + 1] = string.format("%s|%s|%s|%s|%.3f|%s", tostring(setId), rig, sr[1], sr[2], sr[3].dur, sr[3].file)
            G.rows = G.rows + 1
        end
        G.status = string.format("indexing: set %d/%d, %d mappings", si, #sets, G.rows)
        if us() - budgetStart > BUDGET_US then coroutine.yield(); budgetStart = us() end
    end
    pcall(Ext.IO.SaveFile, GLOBAL_PATH, table.concat(lines, "\n"))
    G.state = "ready"
    G.status = string.format("%d mappings in %d sets (%.0f s)", G.rows, #sets, (us() - t0) / 1e6)
    Log.Write("AnimLib: global index " .. G.status .. " -> " .. GLOBAL_PATH)
end

function M.BuildGlobal(force)
    if G.state == "building" then return end
    if not force and globalLoad() then return end
    G.state = "building"
    G.byKey, G.setRig, G.rows = {}, {}, 0
    G.co = coroutine.create(globalBody)
    Log.Write("AnimLib: building the global animation index (one time, several minutes)...")
end

-- Coverage for a mapping id: { rig -> { file, set } } plus the rigs with no clip.
function M.Coverage(key)
    if G.state ~= "ready" then return nil end
    local byRig = {}
    for set, e in pairs(G.byKey[key] or {}) do
        local rig = G.setRig[set] or "?"
        local cur = byRig[rig]
        if not cur then byRig[rig] = { file = baseName(e.file), sets = 1 } else cur.sets = cur.sets + 1 end
    end
    local allRigs = {}
    for _, r in pairs(G.setRig) do allRigs[r] = true end
    local gaps = {}
    for r in pairs(allRigs) do if r ~= "?" and not byRig[r] then gaps[#gaps + 1] = r end end
    table.sort(gaps)
    return byRig, gaps
end

-- Fallback list from the global index, filtered by rig.
local function fallbackRows(rig)
    local rows = {}
    for key, sets in pairs(G.byKey) do
        for set, e in pairs(sets) do
            if G.setRig[set] == rig then
                rows[#rows + 1] = { key = key, subset = "global", res = e.res, dur = e.dur, file = e.file }
                break
            end
        end
    end
    return rows
end

-- ---------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------
local function visualRig(ent)
    local ok, t = pcall(function() return tostring(ent.Visual.Visual.VisualResource.Template) end)
    if ok and t then
        local r = t:match("(%u%u%u_%u%u?)_")
        if r then return r end
    end
    return "?"
end

function M.Load(target, ent)
    B.target, B.mappings, B.t0 = target, 0, us()
    B.clips, B.byKey, B.fallback = {}, {}, false
    local ids, source = setIdsOf(ent)
    B.sets = ids
    if #ids == 0 then
        B.source = "fallback list (global index, by rig)"
        B.fallback = true
        B.rig = visualRig(ent)
        Log.Write(string.format("AnimLib: %s has no AnimationSet/Waterfall sets; fallback by rig %s (visual template)",
            target.name, B.rig))
        if G.state ~= "ready" and not globalLoad() then
            M.BuildGlobal(false)
            B.state = "waiting"
            B.status = "fallback: waiting for the global index"
            return
        end
        finish(fallbackRows(B.rig))
        B.state = "ready"
        B.status = string.format("fallback list: %d clips", #B.clips)
        return
    end
    B.source = source
    B.rig = quickRig(ids)
    local sig = signature(ids)
    local rows = loadCache(B.rig, sig)
    if rows then
        finish(rows)
        B.state = "ready"
        B.status = string.format("%d clips (cached)", #B.clips)
        Log.Write(string.format("AnimLib: %s rig=%s source=%s sets=%d -> %d clips from cache %s",
            target.name, B.rig, B.source, #ids, #B.clips, cachePath(B.rig, sig)))
        return
    end
    B.state = "building"
    B.status = "building..."
    B.co = coroutine.create(function() buildBody(ids, sig) end)
    Log.Write(string.format("AnimLib: %s rig=%s source=%s sets=%d -> building list (first time for this set)",
        target.name, B.rig, B.source, #ids))
end

function M.Tick()
    if B.state == "building" and B.co then
        local ok, err = coroutine.resume(B.co)
        if not ok then B.state = "failed"; B.status = "error: " .. tostring(err); Log.Write("AnimLib: " .. B.status) end
    elseif B.state == "waiting" and G.state == "ready" then
        finish(fallbackRows(B.rig))
        B.state = "ready"
        B.status = string.format("fallback list: %d clips", #B.clips)
    end
    if G.state == "building" and G.co and B.state ~= "building" then
        local ok, err = coroutine.resume(G.co)
        if not ok then G.state = "failed"; G.status = "error: " .. tostring(err); Log.Write("AnimLib: global " .. G.status) end
    end
end

-- Lookup for runtime fallbacks (Tags): any clip of `rig` matching a predicate.
function M.FindInGlobal(rig, pred)
    if G.state ~= "ready" then return nil end
    for key, sets in pairs(G.byKey) do
        for set, e in pairs(sets) do
            if G.setRig[set] == rig and pred(baseName(e.file)) then
                return { key = key, res = e.res, dur = e.dur, file = baseName(e.file) }
            end
        end
    end
    return nil
end

-- Rig of a character from its own animation sets (a few clip names), or
-- its visual template; "?" if neither works.
function M.RigForEntity(ent)
    local ids = setIdsOf(ent)
    if #ids > 0 then
        local r = quickRig(ids)
        if r ~= "?" then return r end
    end
    return visualRig(ent)
end

M.BaseName = baseName
M.GlobalLoad = globalLoad

return M
