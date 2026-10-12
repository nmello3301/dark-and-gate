-- SPDX-License-Identifier: GPL-3.0-or-later
-- V cycles the companion mode (DECISIONS 2026-10-12): Follow -> Wait -> Go
-- to camp -> Follow, for every party companion the pressing player owns
-- (reserved for that user, not the one they control). Vanilla calls only:
--   follow  AttachToPartyGroup(c, leader); from camp first PROC_Camp_Leave(c)
--           (vanilla's own return logic), then a TeleportTo the leader if
--           that left it far away
--   wait    DetachFromPartyGroup(c) + PurgeOsirisQueue / FlushOsirisQueue:
--           it stays where it is (in a fight Brawl's AI still fights)
--   camp    QRY_Camp_GetCamperPos(c) -> DB_QRYRTN_Camp_GetCamperPos ->
--           PROC_Camp_TeleportToCamp(c, spot): the game's own safe teleport
-- Reviving downed players stays their top priority except in camp
-- (Server/Combat/Downed.lua asks Mode()). A toast tells the player.

local Log   = Ext.Require("Shared/Log.lua")
local Net   = Ext.Require("Shared/Net.lua")
local Party = Ext.Require("Server/Party.lua")

local M = {}

local ORDER = { follow = "wait", wait = "camp", camp = "follow" }
local LABEL = { follow = "Follow", wait = "Wait", camp = "Go to camp" }
local modes = {}   -- Osiris user id -> mode

local function name(u)
    local ok, n = pcall(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(u)) end)
    return (ok and n and n ~= "") and n or tostring(u)
end

local function try(what, fn)
    local ok, err = pcall(fn)
    return ok and what or (what .. " ERROR " .. tostring(err))
end

local function toCamp(c)
    local spot = nil
    pcall(function() Osi.QRY_Camp_GetCamperPos(c) end)
    pcall(function()
        for _, row in pairs(Osi.DB_QRYRTN_Camp_GetCamperPos:Get(c, nil) or {}) do spot = row[2] end
    end)
    if not spot then
        pcall(function()
            for _, row in pairs(Osi.DB_QRYRTN_Camp_GetCamperPos:Get(nil, nil) or {}) do
                if Party.Norm(row[1]) == c then spot = row[2] end
            end
        end)
    end
    if not spot then return "no camp spot (DB_QRYRTN_Camp_GetCamperPos empty)" end
    return try("PROC_Camp_TeleportToCamp -> " .. tostring(spot), function() Osi.PROC_Camp_TeleportToCamp(c, spot) end)
end

local function apply(c, mode, prev, leader)
    if mode == "wait" then
        local a = try("DetachFromPartyGroup", function() Osi.DetachFromPartyGroup(c) end)
        pcall(function() Osi.PurgeOsirisQueue(c, 1) end)
        pcall(function() Osi.FlushOsirisQueue(c) end)
        return a
    elseif mode == "camp" then
        return toCamp(c)
    end
    local parts = {}
    if prev == "camp" then
        parts[#parts + 1] = try("PROC_Camp_Leave", function() Osi.PROC_Camp_Leave(c) end)
        Ext.Timer.WaitFor(1500, function()
            local ok, d = pcall(function() return Osi.GetDistanceTo(c, leader) end)
            if not ok or not tonumber(d) or tonumber(d) > 30 then
                local r = try("TeleportTo the leader", function() Osi.TeleportTo(c, leader, "", 0, 0, 0, 0, 1) end)
                Log.Write(string.format("Companions: %s still %s m away after leaving camp -> %s", name(c), tostring(d), r))
            end
            pcall(function() Osi.AttachToPartyGroup(c, leader) end)
        end)
    end
    parts[#parts + 1] = try("AttachToPartyGroup", function() Osi.AttachToPartyGroup(c, leader) end)
    return table.concat(parts, ", ")
end

function M.Mode(companion)
    return modes[Party.UserOf(companion) or -1] or "follow"
end

function M.Register()
    Ext.RegisterNetListener(Net.Channels.CompanionMode, function(_, _, peer)
        Ext.OnNextTick(function()
            local user = Party.UserFromPeer(peer)
            local leader = Party.Controlled(user)
            local prev = modes[user] or "follow"
            local mode = ORDER[prev]
            local comps = Party.CompanionsOf(user)
            local names, text = {}, nil
            if #comps == 0 then
                text = "No companions to command"
            else
                modes[user] = mode
                for _, c in ipairs(comps) do
                    local how = apply(c, mode, prev, leader)
                    names[#names + 1] = name(c)
                    Log.Write(string.format("Companions: %s -> %s (%s)", name(c), LABEL[mode], how))
                end
                text = "Companions: " .. LABEL[mode] .. " (" .. table.concat(names, ", ") .. ")"
            end
            Log.Write("Companions: V by " .. name(leader) .. " -> " .. text)
            pcall(function() Ext.Net.PostMessageToUser(peer, Net.Channels.Toast, Ext.Json.Stringify({ text = text, secs = 2.5 })) end)
        end)
    end)
    Log.Write("Companions: registered (V: Follow -> Wait -> Go to camp)")
end

return M
