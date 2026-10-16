-- SPDX-License-Identifier: GPL-3.0-or-later
-- The key that turns the whole mod on / off (developer 2026-10-16: "add a
-- hotkey to enable/disable the mod, let this hotkey be configurable. This
-- will guarantee someone can progress in some spots we might have not
-- foreseen"). It toggles play mode: the same as !dag_play off / on
-- (Client/PlayMode.lua M.Set).
--
-- The key is the "Turn Dark and Gate on / off" keybinding in Mod
-- Configuration Menu (MCM_blueprint.json toggle_mod, default Ctrl+F10):
-- players rebind it on Dark and Gate's General tab, and MCM matches the key
-- and its modifiers itself (MCM.Keybinding.SetKeyDownCallback; BG3MCM 1.41
-- Client/Helpers/Keybindings/InputCallbackManager.lua). Without MCM,
-- data/hud.lua toggle_key is matched here. Either way the key works with
-- first person off, so the mod can always be turned back on.

local Log      = Ext.Require("Shared/Log.lua")
local PlayMode = Ext.Require("Client/PlayMode.lua")
local cfg      = Ext.Require("data/hud.lua")

local M = {}

local SETTING = "toggle_mod"
local viaMcm = false
local running = true   -- a level is running (no toggling in the main menu); true after a Lua reset

-- Our mod table's MCM, injected by BG3MCM (as Shared/MCM.lua MCM.Setting).
local function mcmKeybinding()
    local kb = nil
    pcall(function()
        local mine = Mods and Mods.DarkAndGate and rawget(Mods.DarkAndGate, "MCM")
        if type(mine) == "table" and type(mine.Keybinding) == "table" then kb = mine.Keybinding end
    end)
    return kb
end

local function fallbackLabel()
    local k = cfg.toggle_key or {}
    local parts = {}
    for _, m in ipairs(k.modifiers or {}) do parts[#parts + 1] = "[" .. tostring(m) .. "]" end
    parts[#parts + 1] = "[" .. tostring(k.key or "?") .. "]"
    return table.concat(parts, " + ")
end

-- "[LCtrl] + [F10]": MCM's own text for the binding when MCM has it.
function M.Label()
    if viaMcm then
        local kb = mcmKeybinding()
        local ok, s = pcall(function() return kb.Get(SETTING) end)
        if ok and type(s) == "string" and s ~= "" then return s end
    end
    return fallbackLabel()
end

local function toggle(how)
    PlayMode.Toggle("the on / off key " .. M.Label() .. " (" .. how .. ")")
end

local function hookMcm()
    if viaMcm then return true end
    local kb = mcmKeybinding()
    if not kb or type(kb.SetKeyDownCallback) ~= "function" then return false end
    local ok, err = pcall(kb.SetKeyDownCallback, SETTING, function() toggle("MCM") end)
    if not ok then
        Log.Write("ToggleKey: MCM keybinding not registered (" .. tostring(err) .. "); data/hud.lua toggle_key is used")
        return false
    end
    viaMcm = true
    Log.Write("ToggleKey: on / off key = MCM's \"" .. SETTING .. "\" (Dark and Gate > General)")
    return true
end

-- Without MCM: data/hud.lua toggle_key, exact modifiers as MCM matches them.
local function heldModifiers(e)
    local held = {}
    pcall(function()
        for _, m in ipairs(e.Modifiers) do held[tostring(m):upper()] = true end
    end)
    return held
end

local function matches(e)
    local k = cfg.toggle_key
    if not k or not k.key then return false end
    if tostring(e.Key or ""):upper() ~= tostring(k.key):upper() then return false end
    local held, want = heldModifiers(e), {}
    for _, m in ipairs(k.modifiers or {}) do want[tostring(m):upper()] = true end
    for _, m in ipairs({ "LCTRL", "RCTRL", "LSHIFT", "RSHIFT", "LALT", "RALT" }) do
        if (held[m] or false) ~= (want[m] or false) then return false end
    end
    return true
end

local function onKey(e)
    if viaMcm or not running or not matches(e) then return end
    if tostring(e.Event) == "KeyDown" and not e.Repeat then toggle("data/hud.lua") end
    if e.CanPreventAction then pcall(function() e:PreventAction() end) end
end

function M.Register()
    PlayMode.SetKeyLabel(M.Label)
    hookMcm()
    Ext.Events.KeyInput:Subscribe(function(e)
        local ok, err = pcall(onKey, e)
        if not ok then Log.Write("ToggleKey: ERROR " .. tostring(err)) end
    end)
    pcall(function()
        Ext.Events.GameStateChanged:Subscribe(function(e) running = tostring(e.ToState) == "Running" end)
    end)
    -- MCM injects its table when our mod table is made; once more at session
    -- start in case it came later.
    Ext.Events.SessionLoaded:Subscribe(function()
        if not hookMcm() then Log.Write("ToggleKey: no MCM -> on / off key " .. fallbackLabel() .. " (data/hud.lua toggle_key)") end
    end)
    Log.Write("ToggleKey: registered (" .. (viaMcm and "MCM keybinding" or "data/hud.lua until MCM is found") .. "; now " .. M.Label() .. ")")
end

return M
