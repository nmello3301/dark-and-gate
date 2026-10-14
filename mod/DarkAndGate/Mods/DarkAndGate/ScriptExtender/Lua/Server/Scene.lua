-- SPDX-License-Identifier: GPL-3.0-or-later
-- Dialogues and cutscenes: every client is told when one runs, and our HUD,
-- input and first person stand aside (Client/Combat/State.lua sceneOn,
-- FullPov). Playtest 2026-10-13: in the nautiloid's opening scene our HUD
-- stayed up and the dialogue couldn't be clicked; the client's own check
-- (Dialog / Cinematic / Cutscene components) didn't see that scene. These are
-- BG3's DialogStarted / DialogEnded (not the automated barks), per instance;
-- the list is cleared at each level start.
-- Co-op (multiplayer MP-3): each player is told only about dialogues their
-- own characters are in (Osi.DialogGetInvolvedPlayer), so the other player
-- keeps playing. A dialogue whose players can't be read counts for everyone
-- (the old behaviour; single player always gets it as before).
--   !dag_scene [off]    the current state / clear it (if one ever sticks)

local Log            = Ext.Require("Shared/Log.lua")
local Net            = Ext.Require("Shared/Net.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")
local Party          = Ext.Require("Server/Party.lua")

local M = {}

local open = {}   -- dialog instance -> { name, users = { [osiUser] = true } or nil (= everyone) }

local function count()
    local n = 0
    for _ in pairs(open) do n = n + 1 end
    return n
end

-- The Osiris users whose characters are in this dialogue; nil = unknown.
local function involvedUsers(inst)
    local users, any = {}, false
    pcall(function()
        local n = tonumber(Osi.DialogGetNumberOfInvolvedPlayers(inst)) or 0
        for i = 0, n do
            local okP, p = pcall(function() return Osi.DialogGetInvolvedPlayer(inst, i) end)
            if okP and p and p ~= "" then
                local u = Party.UserOf(p)
                if u then users[u] = true; any = true end
            end
        end
    end)
    return any and users or nil
end

local function onFor(user)
    for _, d in pairs(open) do
        if d.users == nil or d.users[user] then return true end
    end
    return false
end

local last = {}   -- Osiris user -> last state sent
local function send(why)
    local states = {}
    for _, user in ipairs(Party.Users()) do
        local on = onFor(user)
        states[#states + 1] = string.format("%d=%s", user, on and "on" or "off")
        if last[user] ~= on or why ~= nil then
            last[user] = on
            pcall(function() Ext.Net.PostMessageToUser(user, Net.Channels.Scene, Ext.Json.Stringify({ on = on })) end)
        end
    end
    Log.Write(string.format("Scene: %s (%s; %d open; per player %s)", count() > 0 and "dialogue / cutscene -> our HUD and input stand aside for the players in it" or "none",
        tostring(why), count(), table.concat(states, " ")))
end

function M.Register()
    Ext.Osiris.RegisterListener("DialogStarted", 2, "after", function(dialog, inst)
        open[tostring(inst)] = { name = tostring(dialog), users = involvedUsers(inst) }
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
