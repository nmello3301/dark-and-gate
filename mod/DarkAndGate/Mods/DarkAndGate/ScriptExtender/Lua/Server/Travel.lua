-- SPDX-License-Identifier: GPL-3.0-or-later
-- M opens BG3's own map (we never touch the key) and fast travel works as in
-- vanilla; the map is a BG3 panel, so first person frees the cursor and our
-- input pauses while it is open (Client/HUD/Hud.lua). After a teleport the
-- owning client re-settles first person (FullPov.Settle: inactive for a
-- moment, level_seq bumped so the DLL drops stale pointers, then Camera
-- Rotate is pressed again). Level changes are caught on the client too
-- (GameStateChanged); this covers same-level waypoints, portals and camp.

local Log   = Ext.Require("Shared/Log.lua")
local Net   = Ext.Require("Shared/Net.lua")
local Party = Ext.Require("Server/Party.lua")

local M = {}

local function settle(char, why)
    local u = Party.Norm(char)
    if not Party.IsMember(u) then return end
    pcall(function() Ext.Net.BroadcastMessage(Net.Channels.PovSettle, Ext.Json.Stringify({ uuid = u, why = why })) end)
    Log.Write("Travel: " .. tostring(u) .. " " .. why .. " -> first person re-settles on its client")
end

function M.Register()
    Ext.Osiris.RegisterListener("Teleported", 9, "after", function(target, _, ox, oy, oz, nx, ny, nz, spell)
        local d = math.sqrt(((nx or 0) - (ox or 0)) ^ 2 + ((ny or 0) - (oy or 0)) ^ 2 + ((nz or 0) - (oz or 0)) ^ 2)
        if d > 4 then settle(target, string.format("teleported %.0f m (%s)", d, tostring(spell))) end
    end)
    Ext.Osiris.RegisterListener("TeleportedToCamp", 1, "after", function(c) settle(c, "went to camp") end)
    Ext.Osiris.RegisterListener("TeleportedFromCamp", 1, "after", function(c) settle(c, "left camp") end)
    Ext.Osiris.RegisterListener("TeleportToWaypoint", 2, "after", function(c, wp)
        Log.Write("Travel: " .. tostring(Party.Norm(c)) .. " fast travels to " .. tostring(wp))
    end)
    Log.Write("Travel: registered (first person re-settles after teleports / camp / fast travel)")
end

return M
