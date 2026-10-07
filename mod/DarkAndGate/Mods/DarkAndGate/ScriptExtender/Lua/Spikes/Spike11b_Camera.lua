-- SPDX-License-Identifier: GPL-3.0-or-later
-- Spike 11 (camera half).
--
-- Answered: first-person camera position is achieved via Native Camera Tweaks
-- (zoom=0, FOV=90, VerticalOffsetMult=0.95). Head/hair/beard hiding is covered
-- by Spike11_HeadHiding.lua. See docs/spikes/11-head-hiding.md for details.
--
-- Unresolved from Lua: the chase-cam spring, which makes the character body
-- drift ahead of the camera during fast movement. All our attempts failed:
--   * writing CameraController.WorldTransform throws "lifetime expired" per tick.
--   * writing GameCameraBehavior.TargetDestination/Current â€” SE returns (0,0,0)
--     from readback, so snapping Current = Dest teleports camera to origin.
--   * setting GameCameraBehavior.IsSnapping = true â€” writes succeed, no effect.
--   * tuning GlobalSwitches.CameraSwitches[i] spring values (SnapDistance,
--     FollowSpeed, FollowSpringForce) â€” writes take effect but produce
--     overshoot/oscillation; too tight causes catastrophic engine instability.
-- Confirmed NCT itself does not hook the follow spring (only pitch/zoom/FOV/
-- offset): https://github.com/ersh1/BG3_NativeCameraTweaks/tree/main/src.
--
-- Decision: tight camera follow needs a native plugin or a direct engine hook,
-- which is M1 scope. This file is kept for the dump + parameterised tuning
-- commands so M1 work can iterate on the spring values without rebuilding
-- the Lua state.
--
-- Console commands (all invoked as !dag_cam_... from the C >> client prompt):
--   !dag_cam_dump                                   -- log camera / char entities
--   !dag_cam_snap [followSpeed] [springForce] [snapDist]
--                                                    -- tune the spring; keep
--                                                    --   values small, e.g. 5 20 2
--   !dag_cam_restore                                -- restore the engine defaults

local Log = Ext.Require("Shared/Log.lua")

local M = {}

local function fmt(x)
    if x == nil then return "nil" end
    local ok, s = pcall(function() return tostring(x) end)
    return ok and s or "unprintable"
end

local function fmtVec(v)
    if v == nil then return "nil" end
    local ok = pcall(function() return v.x end)
    if ok then
        return string.format("(%.2f,%.2f,%.2f)", v.x or 0, v.y or 0, v.z or 0)
    end
    return fmt(v)
end

local function dumpOne()
    Log.Write("Spike11b: dump start")

    local cams = Ext.Entity.GetAllEntitiesWithComponent("Camera") or {}
    Log.Write(string.format("Spike11b: %d camera entities", #cams))
    for i, eh in ipairs(cams) do
        local ent = Ext.Entity.Get(eh)
        if ent then
            local _, cam = pcall(function() return ent.Camera end)
            if cam then
                local _, active = pcall(function() return cam.Active end)
                local _, ctl = pcall(function() return cam.Controller end)
                local tr, la, fov = "nil", "nil", "nil"
                if ctl then
                    local _, wt = pcall(function() return ctl.WorldTransform end)
                    if wt then tr = fmtVec(wt.Translate) end
                    local _, l = pcall(function() return ctl.LookAt end)
                    if l then la = fmtVec(l) end
                    local _, f = pcall(function() return ctl.FOV end)
                    if f then fov = string.format("%.2f", f) end
                end
                Log.Write(string.format("Spike11b:   cam[%d] active=%s pos=%s look=%s fov=%s",
                    i, tostring(active), tr, la, fov))
            end
        end
    end

    local gs = Ext.Utils.GetGlobalSwitches()
    if gs and gs.CameraSwitches then
        for i, sw in ipairs(gs.CameraSwitches) do
            Log.Write(string.format(
                "Spike11b: switch[%d] followSpeed=%s springForce=%s snapDist=%s terrainSpeed=%s terrainSpring=%s",
                i, tostring(sw.TargetFollowSpeed), tostring(sw.TargetFollowSpringForce),
                tostring(sw.TargetSnapDistance),  tostring(sw.MoveOnTerrainSpeed),
                tostring(sw.MoveOnTerrainSpringForce)))
        end
    end

    Log.Write("Spike11b: dump end")
end

local savedSwitches = nil
local function applySnapSettings(cmd, followSpeedArg, springForceArg, snapDistArg)
    local followSpeed = tonumber(followSpeedArg) or 5.0
    local springForce = tonumber(springForceArg) or 20.0
    local snapDist    = tonumber(snapDistArg)    or 2.0

    local gs = Ext.Utils.GetGlobalSwitches()
    if not gs or not gs.CameraSwitches then
        Log.Write("Spike11b: GlobalSwitches.CameraSwitches not available")
        return
    end
    if savedSwitches == nil then
        savedSwitches = {}
        for i, sw in ipairs(gs.CameraSwitches) do
            savedSwitches[i] = {
                TargetSnapDistance       = sw.TargetSnapDistance,
                TargetFollowSpeed        = sw.TargetFollowSpeed,
                TargetFollowSpringForce  = sw.TargetFollowSpringForce,
                MoveOnTerrainSpeed       = sw.MoveOnTerrainSpeed,
                MoveOnTerrainSpringForce = sw.MoveOnTerrainSpringForce,
            }
        end
    end
    for _, sw in ipairs(gs.CameraSwitches) do
        pcall(function() sw.TargetFollowSpeed        = followSpeed end)
        pcall(function() sw.TargetFollowSpringForce  = springForce end)
        pcall(function() sw.TargetSnapDistance       = snapDist end)
        pcall(function() sw.MoveOnTerrainSpeed       = followSpeed end)
        pcall(function() sw.MoveOnTerrainSpringForce = springForce end)
    end
    Log.Write(string.format(
        "Spike11b: applied followSpeed=%.2f springForce=%.2f snapDist=%.2f",
        followSpeed, springForce, snapDist))
end

local function restoreSnapSettings()
    if savedSwitches == nil then
        Log.Write("Spike11b: no saved switches to restore (nothing to do)")
        return
    end
    local gs = Ext.Utils.GetGlobalSwitches()
    if not gs or not gs.CameraSwitches then return end
    for i, sw in ipairs(gs.CameraSwitches) do
        local s = savedSwitches[i]
        if s then
            pcall(function() sw.TargetSnapDistance       = s.TargetSnapDistance end)
            pcall(function() sw.TargetFollowSpeed        = s.TargetFollowSpeed end)
            pcall(function() sw.TargetFollowSpringForce  = s.TargetFollowSpringForce end)
            pcall(function() sw.MoveOnTerrainSpeed       = s.MoveOnTerrainSpeed end)
            pcall(function() sw.MoveOnTerrainSpringForce = s.MoveOnTerrainSpringForce end)
        end
    end
    Log.Write("Spike11b: restored original camera switches")
end

function M.Register()
    Ext.RegisterConsoleCommand("dag_cam_dump",    function() dumpOne() end)
    Ext.RegisterConsoleCommand("dag_cam_snap",    applySnapSettings)
    Ext.RegisterConsoleCommand("dag_cam_restore", function() restoreSnapSettings() end)
    Log.Write("Spike11b: registered dag_cam_dump / _snap / _restore (M1 tuning helpers)")
end

return M
