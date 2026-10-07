-- SPDX-License-Identifier: GPL-3.0-or-later
-- Thin shim for Mod Configuration Menu. If MCM is loaded we register our
-- toggles with it; if not, we fall back to console commands that flip the
-- same in-memory table. Either way the rest of the mod reads MCM.Get(key).
--
-- MCM's Lua API uses `Ext.Require("MCMAPI")` to pull its own module; the
-- actual API surface varies by MCM version, so we probe for the functions we
-- need and no-op cleanly if MCM is absent.

local Log = Ext.Require("Shared/Log.lua")

local MCM = {}

local values = {}
local defs   = {}

local mcmApi = nil
local function tryMcm()
    if mcmApi ~= nil then return mcmApi end
    local ok, mod = pcall(Ext.Require, "MCMAPI")
    if ok and type(mod) == "table" then mcmApi = mod; return mcmApi end
    local g = _G.MCM or _G.ModConfigMenu
    if type(g) == "table" then mcmApi = g; return mcmApi end
    mcmApi = false
    return nil
end

function MCM.DefineBool(key, default, label)
    defs[key] = { kind = "bool", default = default, label = label }
    values[key] = default
    local api = tryMcm()
    if api and type(api.RegisterSetting) == "function" then
        pcall(api.RegisterSetting, "DarkAndGate", key, "bool", default, label)
    end
end

function MCM.Get(key)
    local api = tryMcm()
    if api and type(api.GetSetting) == "function" then
        local ok, v = pcall(api.GetSetting, "DarkAndGate", key)
        if ok and v ~= nil then return v end
    end
    return values[key]
end

function MCM.Set(key, value)
    values[key] = value
    local api = tryMcm()
    if api and type(api.SetSetting) == "function" then
        pcall(api.SetSetting, "DarkAndGate", key, value)
    end
    Log.Write(string.format("MCM: %s = %s", key, tostring(value)))
end

-- Convenience: wire a console command per bool toggle so the dev can flip
-- it even when MCM isn't up. Called by the spike modules after DefineBool.
function MCM.RegisterToggleCommand(cmd, key)
    Ext.RegisterConsoleCommand(cmd, function(_, arg)
        if arg == "on" or arg == "1" or arg == "true" then
            MCM.Set(key, true)
        elseif arg == "off" or arg == "0" or arg == "false" then
            MCM.Set(key, false)
        else
            MCM.Set(key, not MCM.Get(key))
        end
    end)
end

return MCM
