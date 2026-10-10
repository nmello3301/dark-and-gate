-- SPDX-License-Identifier: GPL-3.0-or-later
-- Animation notes from the browser ("Log this animation").
--
-- One line per note in DarkAndGate/anim-notes.txt (SE output folder):
--   time | clip | mapping id | resource id | duration | rig | family | phase | target | note
-- The file is rewritten in full on every note (Ext.IO.SaveFile has no
-- append), so it survives restarts and can be read in any editor.
-- !dag_animlib_notes prints every note to the console and client.log.

local Log = Ext.Require("Shared/Log.lua")

local M = {}

local PATH = "DarkAndGate/anim-notes.txt"
local HEADER = "# time | clip | mapping id | resource id | duration s | rig | family | phase | target | note"

local lines = {}     -- raw lines (without header)
local byClip = {}    -- clip base name -> latest note text

local function clean(s) return (tostring(s or ""):gsub("[|\r\n]", " ")) end

local function load()
    lines, byClip = {}, {}
    local ok, s = pcall(Ext.IO.LoadFile, PATH)
    if not ok or not s then return end
    for line in s:gmatch("[^\r\n]+") do
        if line:sub(1, 1) ~= "#" then
            lines[#lines + 1] = line
            local parts = {}
            for f in (line .. "|"):gmatch("(.-)|") do parts[#parts + 1] = f:match("^%s*(.-)%s*$") end
            if parts[2] then byClip[parts[2]] = parts[10] or "" end
        end
    end
end

local function now()
    local ok, t = pcall(Ext.Timer.ClockTime)
    return ok and t and tostring(t) or tostring(Ext.Timer.MonotonicTime())
end

function M.Add(clip, target, rig, text)
    if not clip then return end
    local line = table.concat({
        clean(now()), clean(clip.base), clean(clip.keys and clip.keys[1]), clean(clip.res),
        string.format("%.2f", clip.dur or 0), clean(rig), clean(clip.family), clean(clip.phase),
        clean(target and target.name), clean(text),
    }, " | ")
    lines[#lines + 1] = line
    byClip[clip.base] = clean(text)
    pcall(Ext.IO.SaveFile, PATH, HEADER .. "\n" .. table.concat(lines, "\n") .. "\n")
    Log.Write("AnimLib: note logged -> " .. line .. "  (" .. PATH .. ")")
end

function M.For(base) return byClip[base] end

function M.Summary()
    if #lines == 0 then return "none yet (Script Extender\\" .. PATH:gsub("/", "\\") .. ")" end
    return string.format("%d logged in Script Extender\\%s", #lines, PATH:gsub("/", "\\"))
end

function M.Print()
    Log.Write(string.format("AnimLib: %d animation notes (%s)", #lines, PATH))
    for _, l in ipairs(lines) do Log.Write("  " .. l) end
end

load()

return M
