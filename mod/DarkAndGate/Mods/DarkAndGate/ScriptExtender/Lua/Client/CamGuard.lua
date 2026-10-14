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

-- Diagnostics (playtest 2026-10-14, brains fight): BG3's camera still left
-- you for seconds at a time (it followed nobody, or someone else), which the
-- DLL logs as "POV: camera ... BG3 camera targets N". These lines name the
-- request types it saw then and kept, so a later round can tell which one
-- does it. A request stays in the list for several ticks: each type is
-- logged at most once per KEPT_GAP_MS, KEPT_MAX times per session.
local KEPT_MAX, KEPT_GAP_MS = 8, 2000
local kept = {}          -- request type -> { n = lines written, at = last line ms }
local function noteKept(req, ty)
    local k = kept[ty]
    if not k then k = { n = 0, at = -1e9 }; kept[ty] = k end
    local now = Ext.Utils.MonotonicTime()
    if k.n >= KEPT_MAX or now - k.at < KEPT_GAP_MS then return end
    k.n, k.at = k.n + 1, now
    local nT, active, restore = "?", "?", "?"
    pcall(function() nT = tostring(#req.Targets) end)
    pcall(function() active = tostring(req.Active) end)
    pcall(function() restore = tostring(req.RestorePosition) end)
    Log.Write(string.format("CamGuard: kept BG3's '%s' combat camera request (%s extra targets, active=%s, restore=%s; diagnostics %d/%d)",
        ty, nT, active, restore, k.n, KEPT_MAX))
end

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
                elseif okT then
                    noteKept(reqs[i], ty)
                end
            end
        end
    end
end

function M.SetOn(v) on = v and true or false end   -- !dag_play

function M.Register()
    Ext.Events.Tick:Subscribe(function()
        local ok, err = pcall(tick)
        if not ok and not errLogged then errLogged = true; Log.Write("CamGuard: tick error " .. tostring(err)) end
    end)
    Ext.RegisterConsoleCommand("dag_cam_guard", function(_, a)
        if a == "on" or a == "off" then on = (a == "on") end
        local parts, keptParts = {}, {}
        for k, n in pairs(dropped) do parts[#parts + 1] = k .. " " .. n end
        for k in pairs(kept) do keptParts[#keptParts + 1] = k end
        table.sort(keptParts)
        Log.Write(string.format("CamGuard: %s (dropped: %s; kept types seen: %s)", on and "ON" or "OFF",
            #parts > 0 and table.concat(parts, ", ") or "none", #keptParts > 0 and table.concat(keptParts, ", ") or "none"))
    end)
    Log.Write("CamGuard: registered (BG3's Projectile / Spell combat camera requests dropped in first person; !dag_cam_guard)")
end

return M
