-- SPDX-License-Identifier: GPL-3.0-or-later
-- What this machine runs, for the multiplayer version handshake
-- (Client/MP.lua, Server/MP.lua; docs/design/multiplayer.md "Version
-- handshake"). Every player must run the same mod build and DLL build.
--
--   mod_version  meta.lsx version (Ext.Mod.GetMod(ModuleUUID).Info.ModVersion)
--   mod_build    pack-time stamp "<git hash>[+dirty]-<UTC time>"
--                (Shared/BuildInfo.lua, written by scripts/deploy.ps1 when
--                it packs the mod; git-ignored)
--   dll_build    the DLL's stamp; exe = vanilla | plb | unknown, exe_sha =
--                the start of the exe file's SHA-256 (native-selfcheck.txt,
--                written by the DLL's startup self-check)
--   se           Script Extender major version; game = Ext.Utils.GameVersion()

local M = {}

-- Ext.Require only works at load time: read the stamp now.
local okB, B = pcall(Ext.Require, "Shared/BuildInfo.lua")
local BUILD = (okB and type(B) == "table" and B.mod_build) or "dev-unstamped"

local SELFCHECK = "DarkAndGate/native-selfcheck.txt"

-- The keys that must match the host's, and the ones that only warn.
M.MUST = { "mod_build", "mod_version", "dll_build" }
M.WARN = { "exe", "se", "game" }

local function modVersion()
    local ok, v = pcall(function()
        local info = Ext.Mod.GetMod(ModuleUUID).Info
        local mv = info.ModVersion
        if type(mv) == "table" then
            return string.format("%s.%s.%s.%s", tostring(mv[1]), tostring(mv[2]), tostring(mv[3]), tostring(mv[4]))
        end
        return tostring(mv)
    end)
    return ok and v or "?"
end

-- key=value pairs of the DLL's self-check line ({} when the DLL isn't
-- loaded or hasn't finished its check yet).
function M.SelfCheck()
    local ok, text = pcall(Ext.IO.LoadFile, SELFCHECK)
    local t = {}
    if ok and type(text) == "string" then
        for k, v in text:gmatch("([%w_]+)=(%S+)") do t[k] = v end
    end
    return t
end

function M.Get()
    local sc = M.SelfCheck()
    local se = "?"
    pcall(function() se = tostring(Ext.Utils.Version()) end)
    local game = "?"
    pcall(function() game = tostring(Ext.Utils.GameVersion()) end)
    return {
        mod_version = modVersion(),
        mod_build = BUILD,
        dll_build = sc.dll_build or "no DLL",
        exe = sc.exe or "?",
        exe_sha = sc.exe_sha or "?",
        se = se,
        game = game,
    }
end

-- Keys where `mine` differs from `host`: { must = {...}, warn = {...} }.
function M.Compare(mine, host)
    local out = { must = {}, warn = {} }
    mine, host = mine or {}, host or {}
    for _, k in ipairs(M.MUST) do
        if tostring(mine[k]) ~= tostring(host[k]) then out.must[#out.must + 1] = k end
    end
    for _, k in ipairs(M.WARN) do
        if tostring(mine[k]) ~= tostring(host[k]) then out.warn[#out.warn + 1] = k end
    end
    return out
end

function M.Line(v)
    v = v or {}
    return string.format("mod %s build %s, DLL %s, exe %s (%s), SE v%s, game %s",
        tostring(v.mod_version), tostring(v.mod_build), tostring(v.dll_build), tostring(v.exe),
        tostring(v.exe_sha), tostring(v.se), tostring(v.game))
end

return M
