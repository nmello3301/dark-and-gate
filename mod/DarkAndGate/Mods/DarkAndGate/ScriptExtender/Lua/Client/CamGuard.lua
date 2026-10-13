-- SPDX-License-Identifier: GPL-3.0-or-later
-- BG3's combat camera requests in first person (DECISIONS 2026-10-12).
--
-- In a fight BG3 asks its combat camera to follow your projectile (request
-- type "Projectile": Fireball's camera rode the fireball 70 m out and under
-- the ground -> black screen) and to show your spell's target ("Spell": Ray
-- of Frost zoomed in). While first person is on, those requests are dropped
-- every frame from ecl::camera::CombatTargetRequestsComponent, so the camera
-- never leaves your head; the DLL's foreign-camera hold (Pov.cpp) stays as
-- the safety net.
--
--   !dag_cam_guard on|off

local Log     = Ext.Require("Shared/Log.lua")
local FullPov = Ext.Require("FullPov.lua")

local M = {}

local DROP = { Projectile = true, Spell = true }
local on = true
local dropped = {}       -- request type -> count
local logged, errLogged = 0, false

local function tick()
    if not on or not FullPov.IsOn() then return end
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "CameraCombatTargetRequests")
    if not ok or not ents then return end
    for _, e in ipairs(ents) do
        local okR, reqs = pcall(function() return e.CameraCombatTargetRequests.Requests end)
        if okR and reqs then
            for i = #reqs, 1, -1 do
                local okT, ty = pcall(function() return tostring(reqs[i].Type) end)
                if okT and DROP[ty] then
                    local okD, err = pcall(function() reqs[i] = nil end)
                    if okD then
                        dropped[ty] = (dropped[ty] or 0) + 1
                        if logged < 30 then
                            logged = logged + 1
                            Log.Write(string.format("CamGuard: dropped BG3's '%s' combat camera request (first person; %d so far)", ty, dropped[ty]))
                        end
                    elseif not errLogged then
                        errLogged = true
                        Log.Write("CamGuard: could not drop a '" .. ty .. "' camera request: " .. tostring(err))
                    end
                end
            end
        end
    end
end

function M.Register()
    Ext.Events.Tick:Subscribe(function()
        local ok, err = pcall(tick)
        if not ok and not errLogged then errLogged = true; Log.Write("CamGuard: tick error " .. tostring(err)) end
    end)
    Ext.RegisterConsoleCommand("dag_cam_guard", function(_, a)
        if a == "on" or a == "off" then on = (a == "on") end
        local parts = {}
        for k, n in pairs(dropped) do parts[#parts + 1] = k .. " " .. n end
        Log.Write(string.format("CamGuard: %s (dropped: %s)", on and "ON" or "OFF", #parts > 0 and table.concat(parts, ", ") or "none"))
    end)
    Log.Write("CamGuard: registered (BG3's Projectile / Spell combat camera requests dropped in first person; !dag_cam_guard)")
end

return M
