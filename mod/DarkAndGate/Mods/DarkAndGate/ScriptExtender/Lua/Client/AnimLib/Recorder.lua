-- SPDX-License-Identifier: GPL-3.0-or-later
-- Animation recorder: which clips does BG3 itself play on the player?
--
--   !dag_anim_record on    start (the DLL logs every animation the
--                          player's PlayAnimation-type Genome nodes start,
--                          AnimRate.cpp -> native-anim-rec.txt)
--   ... play: BG3's own jump (Z, click), a spell cast, anything ...
--   !dag_anim_record off   stop; every recorded id is resolved to a clip
--                          name and written to DarkAndGate/anim-record.txt
--                          (also printed to client.log)
--
-- The recorded value is the node's animation input (16 bytes). It is shown
-- as a GUID and looked up first as an animation MAPPING id in the player's
-- own AnimationSets (what Osi.PlayAnimation and our tags use), then as an
-- Animation RESOURCE id. "?" = neither (the raw bytes are kept for RE).

local Log     = Ext.Require("Shared/Log.lua")
local FullPov = Ext.Require("FullPov.lua")

local M = {}

local REC_PATH = "DarkAndGate/native-anim-rec.txt"
local OUT_PATH = "DarkAndGate/anim-record.txt"

local function player()
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    return ok and ents and ents[1] or nil
end

local function resourceFile(rid)
    local ok, ar = pcall(Ext.Resource.Get, rid, "Animation")
    if not ok or not ar then return nil end
    local okF, sf = pcall(function() return ar.SourceFile end)
    local okD, d = pcall(function() return ar.Duration end)
    if not okF or not sf then return nil end
    return (tostring(sf):gsub("^.*[/\\]", ""):gsub("%.[Gg][Rr]2$", "")), (okD and tonumber(d)) or 0
end

-- mapping id -> resource id, for the ids we need, from the player's sets.
local function mappingIndex(ent, wanted)
    local found, n = {}, 0
    pcall(function()
        for _, e in ipairs(ent.AnimationSet.Entries) do
            local okR, res = pcall(Ext.Resource.Get, tostring(e.Resource), "AnimationSet")
            if okR and res then
                for _, sub in pairs(res.AnimationBank.AnimationSubSets) do
                    for id in pairs(wanted) do
                        if not found[id] then
                            local okD, desc = pcall(function() return sub.Animation[id] end)
                            if okD and desc then found[id] = tostring(desc.ID); n = n + 1 end
                        end
                    end
                end
            end
        end
    end)
    return found, n
end

local function resolveAll()
    local ok, s = pcall(Ext.IO.LoadFile, REC_PATH)
    if not ok or not s then
        Log.Write("AnimRec: no " .. REC_PATH .. " (was the DLL recorder on? see native.log RATE lines)")
        return
    end
    local rows, wanted = {}, {}
    for line in s:gmatch("[^\r\n]+") do
        local t, cls, id, raw, loop, rate = line:match("^t=(%d+) node=%S+ class=(%S+) anim=(%S+) raw=(%S+) loop=(%d+) rate=(%S+)")
        if t then
            rows[#rows + 1] = { t = tonumber(t), cls = cls, id = id, raw = raw, loop = loop, rate = rate }
            wanted[id] = true
        end
    end
    local ent = player()
    local map = ent and mappingIndex(ent, wanted) or {}
    local out = { "# t ms | node class | id | kind | clip | clip s | loop | play rate" }
    local cache, lastKey = {}, nil
    for _, r in ipairs(rows) do
        local c = cache[r.id]
        if not c then
            local res = map[r.id]
            local file, dur
            if res then file, dur = resourceFile(res) end
            if file then
                c = { kind = "mapping", file = file, dur = dur }
            else
                file, dur = resourceFile(r.id)
                c = file and { kind = "resource", file = file, dur = dur } or { kind = "?", file = "raw " .. r.raw, dur = 0 }
            end
            cache[r.id] = c
        end
        local line = string.format("%6d | %-15s | %s | %-8s | %s | %.2f | %s | %s",
            r.t, r.cls, r.id, c.kind, c.file, c.dur or 0, r.loop, r.rate)
        out[#out + 1] = line
        local key = r.id .. r.cls
        if key ~= lastKey then Log.Write("AnimRec: " .. line) end
        lastKey = key
    end
    pcall(Ext.IO.SaveFile, OUT_PATH, table.concat(out, "\n") .. "\n")
    Log.Write(string.format("AnimRec: %d animation starts, %d distinct ids -> Script Extender\\DarkAndGate\\anim-record.txt",
        #rows, (function() local k = 0; for _ in pairs(cache) do k = k + 1 end; return k end)()))
end

local pending = nil   -- resolve a moment after the DLL closed the file

function M.Register()
    Ext.RegisterConsoleCommand("dag_anim_record", function(_, a)
        local on = (a == "on" or a == "1") or (a == nil and not FullPov.RecInst())
        if on then
            local ent = player()
            local okI, inst = pcall(function() return ent.AnimationBlueprint.Instance end)
            local addr = okI and inst and FullPov.AddrOf(inst) or nil
            if not addr then Log.Write("AnimRec: no AnimationBlueprint.Instance on the player"); return end
            FullPov.SetRecInst(addr)
            Log.Write("AnimRec: recording the player's animations (instance " .. addr .. "). !dag_anim_record off to stop.")
        else
            FullPov.SetRecInst(nil)
            pending = (tonumber(Ext.Timer.MonotonicTime()) or 0) + 500
            Log.Write("AnimRec: stopped, resolving clip names...")
        end
    end)
    Ext.Events.Tick:Subscribe(function()
        if pending and (tonumber(Ext.Timer.MonotonicTime()) or 0) >= pending then
            pending = nil
            local ok, err = pcall(resolveAll)
            if not ok then Log.Write("AnimRec: ERROR " .. tostring(err)) end
        end
    end)
end

return M
