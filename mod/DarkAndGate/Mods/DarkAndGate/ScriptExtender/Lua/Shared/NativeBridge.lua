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
        if v2 then
            Log.Write("Native: " .. v2)
        else
            Log.Write("Native: no DLL detected")
        end
    end)
end

return M
