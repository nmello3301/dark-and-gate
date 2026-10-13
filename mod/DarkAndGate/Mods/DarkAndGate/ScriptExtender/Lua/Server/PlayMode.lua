-- SPDX-License-Identifier: GPL-3.0-or-later
-- !dag_play, server side (Client/PlayMode.lua; developer 2026-10-12: "one
-- command that can trigger the full mod functionality", for a playthrough
-- from game start). A client in play mode sends PlayMode { on } at every
-- session start and when !dag_play is typed. The server turns on its own
-- parts -- real-time fights (Brawl), our combat rules for the AI, fights
-- ending when the enemies are gone -- and answers PlayReady { level, cc }:
-- cc = character creation, where first person waits. At every level start
-- it tells every client the new level, so after character creation the
-- first level of a new game turns first person on.

local Log        = Ext.Require("Shared/Log.lua")
local Net        = Ext.Require("Shared/Net.lua")
local ServerNet  = Ext.Require("Server/Net.lua")
local Brawl      = Ext.Require("Server/BrawlAdapter.lua")
local FightEnd   = Ext.Require("Server/Combat/FightEnd.lua")
local HpBonus    = Ext.Require("Server/Combat/HpBonus.lua")
local aiCfg      = Ext.Require("data/ai.lua")

local M = {}

local inCC = false
local players = {}   -- userId -> true while that player's client is in play mode

local function level()
    local lvl = nil
    pcall(function() lvl = Osi.GetRegion(Osi.GetHostCharacter()) end)
    local cc = inCC
    if lvl and lvl ~= "" then
        local ok, v = pcall(Osi.IsCharacterCreationLevel, lvl)
        if ok and tonumber(v) == 1 then cc = true end
    end
    return lvl, cc
end

local function ready(lvl, cc)
    return Ext.Json.Stringify({ level = tostring(lvl or "?"), cc = cc and true or false })
end

-- The server's share of "everything on".
local function fullOn(who)
    local parts = {}
    if not Brawl.Enabled() then
        Brawl.Enable("!dag_play by " .. who)
        parts[#parts + 1] = "real-time fights turned ON"
    end
    if aiCfg.enabled == false then
        aiCfg.enabled = true
        parts[#parts + 1] = "our combat rules for the AI turned ON"
    end
    if FightEnd.SetEnabled(true) then parts[#parts + 1] = "fight end turned ON" end
    return #parts > 0 and table.concat(parts, ", ") or "real-time fights, AI rules and fight end were already on"
end

function M.Register()
    Ext.Osiris.RegisterListener("CharacterCreationStarted", 0, "after", function() inCC = true end)
    Ext.Osiris.RegisterListener("CharacterCreationFinished", 0, "after", function() inCC = false end)

    Ext.RegisterNetListener(Net.Channels.PlayMode, function(_, payload, peer)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" then return end
        ServerNet.EnqueueOsi(function()
            players[peer] = p.on and true or nil
            if not p.on then
                Log.Write(string.format("PlayMode: user %s turned play mode OFF", tostring(peer)))
                return
            end
            local how = fullOn("user " .. tostring(peer))
            local lvl, cc = level()
            pcall(function() Ext.Net.PostMessageToUser(peer, Net.Channels.PlayReady, ready(lvl, cc)) end)
            Log.Write(string.format("PlayMode: user %s plays (%s); level %s%s; %s", tostring(peer), how, tostring(lvl),
                cc and " = character creation, first person waits" or "", HpBonus.Describe()))
        end)
    end)

    -- Each level start (a new game's first level after character creation,
    -- region changes): every client in play mode turns first person on.
    Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function(lvl)
        local cc = inCC
        local okC, v = pcall(Osi.IsCharacterCreationLevel, lvl)
        if okC and tonumber(v) == 1 then cc = true end
        if next(players) then fullOn("level start") end
        pcall(function() Ext.Net.BroadcastMessage(Net.Channels.PlayReady, ready(lvl, cc)) end)
        Log.Write(string.format("PlayMode: level %s started%s", tostring(lvl), cc and " (character creation)" or ""))
    end)
    Log.Write("PlayMode: registered (!dag_play from a client turns the whole mod on)")
end

return M
