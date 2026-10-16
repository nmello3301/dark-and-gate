-- SPDX-License-Identifier: GPL-3.0-or-later
-- !dag_play's remembered on / off (Client/PlayMode.lua), on this PC:
-- DarkAndGate/play-mode.json. Its own small module so the hotbar can ask
-- On() without requiring the command's modules (no require cycle).

local Log = Ext.Require("Shared/Log.lua")

local M = {}

local FILE = "DarkAndGate/play-mode.json"
local on = false
local chosen = false   -- the file says on or off (false: never set on this PC)
local listeners = {}

function M.Load()
    local ok, txt = pcall(Ext.IO.LoadFile, FILE)
    if ok and txt and txt ~= "" then
        local okJ, t = pcall(Ext.Json.Parse, txt)
        on = okJ and type(t) == "table" and t.on == true or false
        chosen = okJ and type(t) == "table" and t.on ~= nil
    end
    return on
end

function M.On() return on end
-- Turned on or off on this PC at some point (!dag_play, the on / off key).
function M.Chosen() return chosen end

function M.Set(v)
    v = v and true or false
    local changed = v ~= on
    on, chosen = v, true
    pcall(Ext.IO.SaveFile, FILE, Ext.Json.Stringify({ on = on }))
    if changed then
        for _, fn in ipairs(listeners) do
            local ok, err = pcall(fn, on)
            if not ok then Log.Write("PlayMode: listener error " .. tostring(err)) end
        end
    end
end

-- The level the server last named (PlayReady, every level start): cc = character
-- creation, where our client systems stay idle (the hotbar's spell reads).
local level = { name = nil, cc = false }
function M.SetLevel(name, cc) level.name, level.cc = name, cc and true or false end
function M.InCC() return level.cc end

-- fn(on) whenever play mode changes.
function M.OnChange(fn) listeners[#listeners + 1] = fn end

M.Load()

return M
