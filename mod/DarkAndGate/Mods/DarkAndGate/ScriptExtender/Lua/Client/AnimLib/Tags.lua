-- SPDX-License-Identifier: GPL-3.0-or-later
-- Animation tags: "use this animation as swing1 / jump_start / ..."
--
-- Sources, later wins:
--   data/anim_tags.lua                 (committed; paste !dag_animlib_export)
--   DarkAndGate/anim-tags.txt          (runtime picks from the browser)
-- Line format of the runtime file:
--   tag|rig|mappingId|resId|duration|file
-- rig "*" = the default for every rig; a real rig (HUM_F, DWR_M, ...) =
-- a per-rig override.
--
-- Resolve(tag, rig): the override for `rig`, else the default. If the
-- global animation index is built and says `rig` has no clip for that
-- mapping id, falls back to the rig's DFLT clip with the same category and
-- phase ("no <tag> clip for rig <rig>, using fallback").

local Log     = Ext.Require("Shared/Log.lua")
local Library = Ext.Require("Client/AnimLib/Library.lua")
local data    = Ext.Require("data/anim_tags.lua")

local M = {}

local RUNTIME_PATH = "DarkAndGate/anim-tags.txt"

M.KNOWN = { "swing1", "swing2", "swing3", "jump_start", "jump_loop", "jump_land", "block", "parry", "hit_react" }

local tags = {}   -- tag -> { ["*"] = entry, [rig] = entry }; entry = { key, res, dur, file, rig }
local memo = {}   -- "tag@rig" -> resolved (cleared whenever tags change)

local function put(tag, rig, e)
    memo = {}
    tags[tag] = tags[tag] or {}
    tags[tag][rig] = e
end

local function loadAll()
    tags, memo = {}, {}
    for tag, e in pairs((data and data.tags) or {}) do
        put(tag, "*", { key = e.key, res = e.res, dur = tonumber(e.dur) or 0, file = e.file, rig = e.rig })
        for rig, o in pairs(e.overrides or {}) do
            put(tag, rig, { key = o.key, res = o.res, dur = tonumber(o.dur) or 0, file = o.file, rig = rig })
        end
    end
    local ok, s = pcall(Ext.IO.LoadFile, RUNTIME_PATH)
    local n = 0
    if ok and s then
        for line in s:gmatch("[^\r\n]+") do
            local tag, rig, key, res, dur, file = line:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([%d%.]*)|(.*)$")
            if tag and key ~= "" then
                put(tag, rig, { key = key, res = res, dur = tonumber(dur) or 0, file = file, rig = rig })
                n = n + 1
            end
        end
    end
    return n
end

local function save()
    local lines = {}
    for tag, byRig in pairs(tags) do
        for rig, e in pairs(byRig) do
            lines[#lines + 1] = string.format("%s|%s|%s|%s|%.3f|%s", tag, rig, e.key or "", e.res or "", e.dur or 0, e.file or "")
        end
    end
    table.sort(lines)
    pcall(Ext.IO.SaveFile, RUNTIME_PATH, table.concat(lines, "\n"))
end

-- Tag a clip. overrideRig = nil -> the default for every rig.
function M.Set(tag, clip, key, overrideRig)
    if not tag or tag == "" or not clip then return end
    local rig = overrideRig or "*"
    put(tag, rig, { key = key or clip.keys[1], res = clip.res, dur = clip.dur, file = clip.base, rig = clip.rig })
    save()
    Log.Write(string.format("AnimLib: tagged %s%s -> %s (mapping %s, %.2fs, rig %s)",
        tag, overrideRig and ("@" .. overrideRig) or "", clip.base, key or clip.keys[1], clip.dur or 0, clip.rig))
end

function M.Entry(tag, rig)
    local byRig = tags[tag]
    if not byRig then return nil end
    return (rig and byRig[rig]) or byRig["*"]
end

-- Where a tag's clip shows up as a one-line summary for the browser.
function M.Summary()
    local parts = {}
    for _, t in ipairs(M.KNOWN) do
        local e = M.Entry(t)
        if e then parts[#parts + 1] = t .. "=" .. (e.file or e.key) end
    end
    for t in pairs(tags) do
        local known = false
        for _, k in ipairs(M.KNOWN) do if k == t then known = true end end
        if not known then local e = M.Entry(t); parts[#parts + 1] = t .. "=" .. ((e and e.file) or "?") end
    end
    return #parts > 0 and table.concat(parts, "  ") or "(no tags yet)"
end

-- Runtime lookup: { key, dur, file } for `tag` on `rig`, or nil.
local fallbackLogged = {}
local resolveUncached
function M.Resolve(tag, rig)
    local mk = tag .. "@" .. tostring(rig)
    local r = memo[mk]
    if r == nil then
        r = resolveUncached(tag, rig) or false
        -- Only memoize once the coverage index could be consulted.
        if Library.G.state == "ready" or not r then memo[mk] = r end
    end
    return r or nil
end

resolveUncached = function(tag, rig)
    local e = M.Entry(tag, rig)
    if not e then return nil end
    if rig and rig ~= "?" and Library.G.state == "ready" then
        local cov = Library.Coverage(e.key)
        if cov and not cov[rig] then
            local p = Library.Parse(e.file or "")
            local fb = Library.FindInGlobal(rig, function(base)
                local q = Library.Parse(base)
                return q.family == "DFLT" and q.phase == p.phase and (p.cats[1] == nil or q.cats[1] == p.cats[1])
            end)
            local key = tag .. "@" .. rig
            if not fallbackLogged[key] then
                fallbackLogged[key] = true
                Log.Write(string.format("AnimLib: no %s clip for rig %s, using fallback %s", tag, rig,
                    fb and fb.file or "(none -- keeping the tagged mapping id)"))
            end
            if fb then return { key = fb.key, dur = fb.dur, file = fb.file } end
        end
    end
    return { key = e.key, dur = e.dur, file = e.file }
end

-- Lua table for data/anim_tags.lua.
function M.Export()
    local out = { "return {", "    tags = {" }
    local names = {}
    for t in pairs(tags) do names[#names + 1] = t end
    table.sort(names)
    for _, t in ipairs(names) do
        local byRig = tags[t]
        local d = byRig["*"]
        if d then
            out[#out + 1] = string.format('        %s = { key = "%s", res = "%s", file = "%s", rig = "%s", dur = %.3f,',
                t, d.key or "", d.res or "", d.file or "", d.rig or "", d.dur or 0)
            local ov = {}
            for rig, e in pairs(byRig) do
                if rig ~= "*" then
                    ov[#ov + 1] = string.format('                %s = { key = "%s", res = "%s", file = "%s", dur = %.3f },',
                        rig, e.key or "", e.res or "", e.file or "", e.dur or 0)
                end
            end
            if #ov > 0 then
                out[#out + 1] = "            overrides = {"
                for _, l in ipairs(ov) do out[#out + 1] = l end
                out[#out + 1] = "            },"
            end
            out[#out + 1] = "        },"
        end
    end
    out[#out + 1] = "    },"
    out[#out + 1] = "}"
    return table.concat(out, "\n")
end

function M.Reload() return loadAll() end

-- The controlled character's rig, cached per character for 10 s.
local rigCache = { key = nil, rig = "?", at = -1e9 }
function M.PlayerRig()
    local t = tonumber(Ext.Timer.MonotonicTime()) or 0
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    local e = ok and ents and ents[1] or nil
    if not e then return "?" end
    local key = tostring(e)
    if key ~= rigCache.key or t - rigCache.at > 10000 then
        rigCache.key, rigCache.at = key, t
        local okR, r = pcall(Library.RigForEntity, e)
        rigCache.rig = (okR and r) or "?"
    end
    return rigCache.rig
end

-- Tag lookup for the controlled character: { key, dur, file } or nil.
function M.ForPlayer(tag)
    if not tags[tag] then return nil end
    return M.Resolve(tag, M.PlayerRig())
end

local n = loadAll()
if n > 0 then Log.Write(string.format("AnimLib: %d runtime animation tags loaded (%s)", n, RUNTIME_PATH)) end

return M
