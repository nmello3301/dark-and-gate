-- SPDX-License-Identifier: GPL-3.0-or-later
-- Dialogues and cutscenes: every client is told when one runs, and our HUD,
-- input and first person stand aside (Client/Combat/State.lua sceneOn,
-- FullPov). Playtest 2026-10-13: in the nautiloid's opening scene our HUD
-- stayed up and the dialogue couldn't be clicked; the client's own check
-- (Dialog / Cinematic / Cutscene components) didn't see that scene. These are
-- BG3's DialogStarted / DialogEnded (not the automated barks), per instance;
-- the list is cleared at each level start.
--   !dag_scene [off]    the current state / clear it (if one ever sticks)

local Log            = Ext.Require("Shared/Log.lua")
local Net            = Ext.Require("Shared/Net.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")

local M = {}

local open = {}   -- dialog instance -> dialog name

local function count()
    local n = 0
    for _ in pairs(open) do n = n + 1 end
    return n
end

local function send(why)
    local on = count() > 0
    pcall(function() Ext.Net.BroadcastMessage(Net.Channels.Scene, Ext.Json.Stringify({ on = on })) end)
    Log.Write(string.format("Scene: %s (%s; %d open)", on and "dialogue / cutscene -> our HUD and input stand aside" or "none",
        why, count()))
end

function M.Register()
    Ext.Osiris.RegisterListener("DialogStarted", 2, "after", function(dialog, inst)
        open[tostring(inst)] = tostring(dialog)
        send("started " .. tostring(dialog))
    end)
    Ext.Osiris.RegisterListener("DialogEnded", 2, "after", function(dialog, inst)
        open[tostring(inst)] = nil
        send("ended " .. tostring(dialog))
    end)
    Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function()
        if next(open) then open = {}; send("level start") end
    end)
    ConsoleForward.Server("dag_scene", function(_, a)
        if a == "off" then open = {} end
        send("!dag_scene" .. (a == "off" and " off" or ""))
    end)
    Log.Write("Scene: registered (dialogues / cutscenes: our HUD, input and first person stand aside; !dag_scene [off])")
end

return M
