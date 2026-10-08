-- SPDX-License-Identifier: GPL-3.0-or-later
-- Minimal shim that proves the native plugin loaded.
--
-- The DLL (tools/native/) writes a single-line version file on load:
--   DarkAndGate <version> <build-kind> pid=<N> t=<ms>
-- Path (relative to SE output root): DarkAndGate/native-version.txt
--
-- At SessionLoaded we read it via Ext.IO.LoadFile and log the version.
-- Console command: !dag_native_version re-reads on demand.
--
-- No per-call bridging yet — that's a separate design decision pending
-- in docs/native-bridge-design.md. This module exists only so the dev
-- can confirm "DLL loaded" without running Ghidra each time.

local Log = Ext.Require("Shared/Log.lua")

local M = {}

local VERSION_PATH = "DarkAndGate/native-version.txt"

-- Returns the trimmed first line of the version file, or nil if the file
-- isn't present (common case: DLL not deployed yet).
local function readVersion()
    local ok, contents = pcall(Ext.IO.LoadFile, VERSION_PATH)
    if not ok or not contents or contents == "" then return nil end
    -- Trim trailing newline and anything after the first line.
    local first = contents:match("[^\r\n]+")
    return first
end
M.ReadVersion = readVersion

-- Write a camera eye_height into native-config.toml. Minimal re-emit:
-- preserves other keys/sections by reading the file first (if present)
-- and only updating the eye_height line. Falls back to a full rewrite
-- if no existing file is readable.
local CONFIG_PATH = "DarkAndGate/native-config.toml"

local function writeEyeHeight(h)
    local existing = ""
    local ok, c = pcall(Ext.IO.LoadFile, CONFIG_PATH)
    if ok and c and c ~= "" then existing = c end

    local replaced = false
    local lines = {}
    for line in (existing .. "\n"):gmatch("([^\n]*)\n") do
        if not replaced and line:match("^%s*eye_height%s*=") then
            table.insert(lines, string.format("eye_height        = %.3f", h))
            replaced = true
        else
            table.insert(lines, line)
        end
    end
    if not replaced then
        -- No file (or no key) — write a minimal file. The dev's full
        -- defaults ship in tools/native/config/native-config.toml and
        -- are copied once at setup; we only need to make eye_height
        -- authoritative here.
        lines = {
            "[dag.camera]",
            string.format("eye_height        = %.3f", h),
        }
    end
    Ext.IO.SaveFile(CONFIG_PATH, table.concat(lines, "\n"))
end
M.WriteEyeHeight = writeEyeHeight

-- Look up eye_height for a race tag; falls back to Default.
local eyeTable = nil
local function getEyeHeightForRace(raceTag)
    if not eyeTable then eyeTable = Ext.Require("data/camera.lua") end
    return eyeTable[raceTag] or eyeTable.Default or 1.65
end
M.GetEyeHeightForRace = getEyeHeightForRace

function M.Register(side)
    -- Read once at register time so the client-side bootstrap log carries
    -- the version if the DLL is there.
    local v = readVersion()
    if v then
        Log.Write("Native: " .. v)
    else
        Log.Write("Native: no DLL detected (file " .. VERSION_PATH .. " missing or empty)")
    end

    Ext.RegisterConsoleCommand("dag_native_version", function()
        local v2 = readVersion()
        if v2 then Log.Write("Native: " .. v2) else Log.Write("Native: no DLL detected") end
    end)

    -- Client only: push a sensible eye_height on SessionLoaded so the
    -- DLL has a current value. Race-aware lookup comes once we wire a
    -- controlled-character-changed event; for now default fallback.
    if side == "Client" then
        Ext.Events.SessionLoaded:Subscribe(function()
            local h = getEyeHeightForRace("Default")
            writeEyeHeight(h)
            Log.Write(string.format("Native: wrote eye_height=%.3f", h))
        end)

        Ext.RegisterConsoleCommand("dag_set_eye", function(_, arg)
            local h = tonumber(arg) or 1.65
            writeEyeHeight(h)
            Log.Write(string.format("Native: wrote eye_height=%.3f (requires BG3 restart)", h))
        end)
    end
end

return M
