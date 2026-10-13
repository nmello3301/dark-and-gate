-- SPDX-License-Identifier: GPL-3.0-or-later
-- Ground surfaces don't touch you in the air (DECISIONS 2026-10-12;
-- developer: "Make sure adverse terrain doesn't impact the player if the
-- player is in the air").
--
-- While a first-person jump is in the air (Shared/Hitbox.lua jump window,
-- from JumpStart), a surface status landing on the jumper (data/movement.lua
-- air_surfaces.statuses: grease / ice prone, burning, wet, acid, web ...) is
-- removed at once. Landing in a surface still counts. Every other status that
-- lands mid-air is logged once by name, so missing surface statuses show up.

local Log    = Ext.Require("Shared/Log.lua")
local Party  = Ext.Require("Server/Party.lua")
local Hitbox = Ext.Require("Shared/Hitbox.lua")
local D      = Ext.Require("data/movement.lua").air_surfaces or {}

local M = {}

local block = {}
for _, s in ipairs(D.statuses or {}) do block[s] = true end
local seenOther = {}

local function name(u)
    local ok, n = pcall(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(u)) end)
    return (ok and n and n ~= "") and n or tostring(u)
end

function M.Register()
    Ext.Osiris.RegisterListener("StatusApplied", 4, "after", function(obj, status, causee, _)
        local u = Party.Norm(obj)
        if not u or not Hitbox.Airborne(u) then return end
        status = tostring(status)
        if block[status] then
            pcall(function() Osi.RemoveStatus(obj, status) end)
            Log.Write(string.format("AirSurfaces: %s is in the air -> %s removed (from %s)", name(u), status, tostring(causee)))
        elseif not seenOther[status] and D.log_others ~= false then
            seenOther[status] = true
            Log.Write(string.format("AirSurfaces: %s got %s in the air (kept; add it to air_surfaces.statuses if a surface gave it)", name(u), status))
        end
    end)
    Log.Write(string.format("AirSurfaces: registered (%d surface statuses ignored while a jump is in the air)", #(D.statuses or {})))
end

return M
