-- SPDX-License-Identifier: GPL-3.0-or-later
-- C = crouch = BG3's sneaking (DECISIONS 2026-10-12). The server toggles the
-- SNEAKING status (Server/Combat/Stealth.lua) and tells every client
-- (CrouchState); for our own character this client then:
--   * slows walking / running to data/movement.lua crouch.speed_mult
--     (Movement modifier "crouch"; SNEAKING itself also caps to walk);
--   * tells the DLL (crouch=1): the eye follows the lowering head bone and
--     the eye-height calibration waits until we stand;
--   * hides BG3's vision cones while in first person (the player's
--     Darkness.SneakingConesVisibility, restored outside first person).
--   !dag_crouch_speed <x>

local Log       = Ext.Require("Shared/Log.lua")
local Net       = Ext.Require("Shared/Net.lua")
local ClientNet = Ext.Require("Client/Net.lua")
local State     = Ext.Require("Client/Combat/State.lua")
local Aim       = Ext.Require("Client/Combat/Aim.lua")
local FullPov   = Ext.Require("FullPov.lua")
local Movement  = Ext.Require("Client/Movement/Movement.lua")
local Input     = Ext.Require("Client/Combat/Input.lua")
local TickBudget = Ext.Require("Shared/TickBudget.lua")
local movement  = Ext.Require("data/movement.lua")

local M = {}

local C = movement.crouch
local cones = { saved = nil, logged = false }

local function player()
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    return ok and ents and ents[1] or nil
end

local function tick()
    local me = player()
    if not me or C.hide_cones == false then return end
    local hide = State.povOn and State.crouched
    local okR, cur = pcall(function() return me.Darkness.SneakingConesVisibility end)
    if not okR then
        if not cones.logged then cones.logged = true; Log.Write("Crouch: the player has no Darkness.SneakingConesVisibility (" .. tostring(cur) .. ")") end
        return
    end
    if hide then
        if cones.saved == nil then cones.saved = cur end
        if cur ~= false then
            local okW, err = pcall(function() me.Darkness.SneakingConesVisibility = false end)
            if not cones.logged then
                cones.logged = true
                Log.Write("Crouch: vision cones hidden in first person (SneakingConesVisibility " .. tostring(cur) .. " -> false: "
                    .. (okW and "written" or ("write FAILED " .. tostring(err))) .. ")")
            end
        end
    elseif cones.saved ~= nil then
        pcall(function() me.Darkness.SneakingConesVisibility = cones.saved end)
        cones.saved = nil
    end
end

function M.Register()
    Input.AddKey("C", function()
        ClientNet.Send(Net.Channels.CrouchToggle, {})
        Log.Write("Crouch: C -> toggle")
    end)
    Ext.RegisterNetListener(Net.Channels.CrouchState, function(_, payload)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" or p.uuid ~= Aim.SelfUuid() then return end
        local on = p.on == true
        if State.crouched ~= on then
            State.crouched = on
            FullPov.SetCrouch(on)
            Log.Write("Crouch: " .. (on and string.format("crouched (sneaking), speed x%.2f, eye follows the head down", C.speed_mult) or "standing"))
        end
    end)
    Movement.AddModifier("crouch", function() return State.crouched and C.speed_mult or 1.0 end)
    Ext.Events.Tick:Subscribe(TickBudget.Wrap("Crouch", tick))
    Ext.RegisterConsoleCommand("dag_crouch_speed", function(_, v)
        if tonumber(v) then C.speed_mult = math.max(0.1, math.min(1.5, tonumber(v))) end
        Log.Write(string.format("Crouch: crouched speed x%.2f", C.speed_mult))
    end)
    Log.Write("Crouch: registered (C = sneak, !dag_crouch_speed)")
end

return M
