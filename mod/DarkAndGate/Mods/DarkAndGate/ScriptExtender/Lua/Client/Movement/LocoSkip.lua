-- SPDX-License-Identifier: GPL-3.0-or-later
-- Locomotion transition skip for the direct controller (DECISIONS 2026-10-13,
-- docs/spikes/move-feel.md).
--
-- BG3's locomotion plays a Start clip when a walk or run begins
-- (HUM_M_Rig_1HSSH_LOCO_Run_F_Peace_01_Start, 1.0 s) and an End*Foot clip
-- when it ends (..._EndRFoot, 2.6 s; docs/anim-record-2026-10-10.txt). The
-- position never waits for them (it is code-driven), but with instant starts
-- and stops they would hold a start or stop pose. This finds them by clip
-- name in the player's own animation sets (names with "_LOCO_" and "_Start",
-- "_End" or "Turn"), and while direct mode is on the DLL plays them at
-- move.loco_transition_rate (AnimRate SetLocoSkip, its own table: the bow and
-- spell clip rates are untouched).
--
-- The scan resolves every mapping of the sets, a little per tick, the first
-- time a set combination is seen; the result is cached in
-- DarkAndGate/locoskip-<signature>.txt.

local Log     = Ext.Require("Shared/Log.lua")
local FullPov = Ext.Require("FullPov.lua")
local D       = Ext.Require("data/movement.lua").move
local Me = Ext.Require("Client/Me.lua")   -- the local player's character (multiplayer)

local M = {}

local BUDGET_US, MAX_IDS, CHECK_MS = 600, 48, 2000
local CACHE_VER = "v2"   -- v2: fall landings left out

local function us() return Ext.Timer.MicrosecTime() end
local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function player()
    local ok, ents = pcall(Me.All)
    return ok and ents and ents[1] or nil
end

local function instAddr(ent)
    local ok, inst = pcall(function() return ent.AnimationBlueprint.Instance end)
    return ok and inst and FullPov.AddrOf(inst) or nil
end

-- The character's animation sets (the AnimationSet component, else the
-- waterfall), sorted: the same walk Client/AnimLib/Library.lua does.
local function setIdsOf(ent)
    local ids, seen = {}, {}
    local function add(r)
        r = r and tostring(r) or ""
        if r ~= "" and not seen[r] then seen[r] = true; ids[#ids + 1] = r end
    end
    pcall(function() for _, e in ipairs(ent.AnimationSet.Entries) do add(e.Resource) end end)
    if #ids == 0 then
        pcall(function() for _, e in ipairs(ent.AnimationWaterfall.Waterfall) do add(e.Resource) end end)
    end
    table.sort(ids)
    return ids
end

local function signature(ids)
    local h = 5381
    for _, id in ipairs(ids) do
        for i = 1, #id do h = (h * 33 + id:byte(i)) % 4294967296 end
    end
    return string.format("%08x", h)
end

local function cachePath(sig) return string.format("DarkAndGate/locoskip-%s-%s.txt", CACHE_VER, sig) end

local function baseName(path) return (tostring(path):gsub("^.*[/\\]", ""):gsub("%.[Gg][Rr]2$", "")) end

-- A locomotion transition: starts, stops, turns. Not the fall landings
-- (_LOCO_Fall_..._End*): those end the real jump, which stays as signed off.
local function isTransition(name)
    if not name:find("_LOCO_", 1, true) then return false end
    if name:find("_LOCO_Fall", 1, true) then return false end
    return name:find("_Start", 1, true) ~= nil or name:find("_End", 1, true) ~= nil or name:find("Turn", 1, true) ~= nil
end

local S = {
    sig = nil,          -- set signature being used / scanned
    ids = nil,          -- mapping ids (strings) for that signature
    co = nil,           -- scan coroutine
    checkAt = -1e9,
    lastInst = nil,
}

local function loadCache(sig)
    local ok, s = pcall(Ext.IO.LoadFile, cachePath(sig))
    if not ok or not s or s == "" then return nil end
    local ids = {}
    for line in s:gmatch("[^\r\n]+") do
        local key = line:match("^([^|#]+)|")
        if key then ids[#ids + 1] = key end
    end
    return ids
end

local function scan(setIds, sig)
    local rows = {}
    local t0 = us()
    local budgetStart = t0
    local mappings = 0
    local function spend()
        if us() - budgetStart > BUDGET_US then
            coroutine.yield()
            budgetStart = us()
        end
    end
    for _, id in ipairs(setIds) do
        local ok, res = pcall(Ext.Resource.Get, id, "AnimationSet")
        if ok and res then
            -- Collect the pairs first (iterating a userdata map across a
            -- coroutine yield is not safe), then resolve with a budget.
            local pending = {}
            pcall(function()
                for _, sub in pairs(res.AnimationBank.AnimationSubSets) do
                    for key, desc in pairs(sub.Animation) do
                        pending[#pending + 1] = { tostring(key), tostring(desc.ID) }
                    end
                end
            end)
            local seen = {}
            for _, p in ipairs(pending) do
                mappings = mappings + 1
                if not seen[p[1]] then
                    local okA, ar = pcall(Ext.Resource.Get, p[2], "Animation")
                    local file = nil
                    if okA and ar then pcall(function() file = tostring(ar.SourceFile) end) end
                    if file then
                        local name = baseName(file)
                        if isTransition(name) then
                            seen[p[1]] = true
                            rows[#rows + 1] = { key = p[1], name = name }
                        end
                    end
                end
                spend()
            end
        end
        spend()
    end
    table.sort(rows, function(a, b) return a.name < b.name end)
    local lines = { string.format("# %d locomotion transition clips of %d mappings, sets %s", #rows, mappings, table.concat(setIds, ",")) }
    local ids = {}
    for _, r in ipairs(rows) do
        lines[#lines + 1] = r.key .. "|" .. r.name
        ids[#ids + 1] = r.key
    end
    pcall(Ext.IO.SaveFile, cachePath(sig), table.concat(lines, "\n"))
    Log.Write(string.format("LocoSkip: %d locomotion Start / End / turn clips found in %d mappings (%.1f s, cached %s)%s",
        #rows, mappings, (us() - t0) / 1e6, cachePath(sig), #rows > MAX_IDS and string.format("; the DLL takes the first %d", MAX_IDS) or ""))
    for i = 1, math.min(#rows, 12) do Log.Write("LocoSkip:   " .. rows[i].name) end
    return ids
end

local function push(ent)
    local rate = tonumber(D.loco_transition_rate) or 1.0
    local inst = instAddr(ent)
    local ids = {}
    if D.skip_loco_transitions ~= false and S.ids and inst then
        for i = 1, math.min(#S.ids, MAX_IDS) do ids[i] = S.ids[i] end
    end
    FullPov.SetLocoSkip(inst, ids, rate)
    if inst ~= S.lastInst then
        S.lastInst = inst
        Log.Write(string.format("LocoSkip: %d clips at x%.1f on instance %s (applied while direct mode is on)", #ids, rate, tostring(inst)))
    end
end

local function tick()
    if S.co then
        local ok, res = coroutine.resume(S.co)
        if not ok then
            Log.Write("LocoSkip: scan failed: " .. tostring(res))
            S.co, S.ids = nil, {}
        elseif coroutine.status(S.co) == "dead" then
            S.co, S.ids = nil, res or {}
            local ent = player()
            if ent then push(ent) end
        end
        return
    end
    local now = nowMs()
    if now - S.checkAt < CHECK_MS then return end
    S.checkAt = now
    local ent = player()
    if not ent then return end
    local setIds = setIdsOf(ent)
    if #setIds == 0 then return end
    local sig = signature(setIds)
    if sig ~= S.sig then
        S.sig = sig
        local cached = loadCache(sig)
        if cached then
            S.ids = cached
            Log.Write(string.format("LocoSkip: %d locomotion transition clips (cached %s)", #cached, cachePath(sig)))
        else
            S.ids = nil
            S.co = coroutine.create(function() return scan(setIds, sig) end)
            Log.Write("LocoSkip: first time for these animation sets -> scanning them for Start / End / turn clips")
            return
        end
    end
    push(ent)
end

function M.Register()
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
end

return M
