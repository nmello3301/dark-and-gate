-- SPDX-License-Identifier: GPL-3.0-or-later
-- Lua side of the Dark and Gate native bridge.
--
-- Responsibilities (client side):
--   1. Log the DLL's native-version.txt at session load.
--   2. Write eye_height into native-config.toml (per controlled char race).
--   3. Every ~500 ms, write the controlled character's live world position
--      and a gameplay-active flag to native-char-pos.txt. The DLL uses this
--      as CALIBRATION ONLY: once the hook latches onto the live memory
--      location of the character's position inside the camera's own data,
--      per-frame reads come from live memory, not this file. The file is
--      also the pause signal — when active=0 (dialog/cutscene/UI), the
--      camera and mouselook hooks revert to vanilla.
--   4. Register the feature-test console commands.
--
-- Files written (relative to SE output root):
--   DarkAndGate/native-config.toml       (eye_height + feature flags)
--   DarkAndGate/native-char-pos.txt      (ground truth: active + x/y/z + t)
--   DarkAndGate/native-cam-yaw.txt       (char-facing hook, DLL writes it;
--                                         we read it + call SetRotation)

local Log       = Ext.Require("Shared/Log.lua")
local eyeTable  = Ext.Require("data/camera.lua")

local M = {}

local VERSION_PATH  = "DarkAndGate/native-version.txt"
local CONFIG_PATH   = "DarkAndGate/native-config.toml"
local CHARPOS_PATH  = "DarkAndGate/native-char-pos.txt"
local CAMYAW_PATH   = "DarkAndGate/native-cam-yaw.txt"

-- --- Native-version readback -------------------------------------------
local function readVersion()
    local ok, contents = pcall(Ext.IO.LoadFile, VERSION_PATH)
    if not ok or not contents or contents == "" then return nil end
    return contents:match("[^\r\n]+")
end
M.ReadVersion = readVersion

-- --- Config writes ------------------------------------------------------
-- Preserve other keys/sections; only update one line at a time.
local function updateConfigLine(keyPattern, newLine)
    local existing = ""
    local ok, c = pcall(Ext.IO.LoadFile, CONFIG_PATH)
    if ok and c and c ~= "" then existing = c end
    local replaced = false
    local lines = {}
    for line in (existing .. "\n"):gmatch("([^\n]*)\n") do
        if not replaced and line:match(keyPattern) then
            table.insert(lines, newLine); replaced = true
        else
            table.insert(lines, line)
        end
    end
    if not replaced then table.insert(lines, newLine) end
    Ext.IO.SaveFile(CONFIG_PATH, table.concat(lines, "\n"))
end

local function writeEyeHeight(h)
    updateConfigLine("^%s*eye_height%s*=",
        string.format("eye_height        = %.3f", h))
end
M.WriteEyeHeight = writeEyeHeight

local function getEyeHeightForRace(raceTag)
    return eyeTable[raceTag] or eyeTable.Default or 1.65
end
M.GetEyeHeightForRace = getEyeHeightForRace

-- --- Controlled character resolution -----------------------------------
-- Returns the local client's controlled entity, or nil. Multiplayer-safe:
-- each client sees its own controlled char. Falls back through SE's
-- several APIs because none are documented as universally present.
local function getControlledEntity()
    -- Preferred: ClientControl component (one per locally-controlled char).
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    if ok and entities and #entities > 0 then
        return entities[1]
    end
    -- Fallback: picking helper (the entity under the player's cursor focus).
    local ok2, pick = pcall(Ext.Client.GetPickingHelper, 1)
    if ok2 and pick and pick.HoverCharacter then
        local e = Ext.Entity.Get(pick.HoverCharacter)
        if e then return e end
    end
    return nil
end
M.GetControlledEntity = getControlledEntity

-- Returns true if any dialog on the controlled character or a party
-- member is active, or any cinematic/cutscene is playing.
local function isGameplayPaused()
    -- Any entity with a Dialog component means a dialog is active somewhere.
    local ok, dlgs = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Dialog")
    if ok and dlgs and #dlgs > 0 then return true end
    -- Cinematic / cutscene components.
    for _, c in ipairs({ "Cinematic", "Cutscene", "ClientMoveToCutscene" }) do
        local ok2, es = pcall(Ext.Entity.GetAllEntitiesWithComponent, c)
        if ok2 and es and #es > 0 then return true end
    end
    return false
end
M.IsGameplayPaused = isGameplayPaused

-- --- Ground-truth writer -----------------------------------------------
local function readTranslate(entity)
    if not entity then return nil end
    local ok, t = pcall(function() return entity.Transform and entity.Transform.Translate end)
    if ok and t then return t[1], t[2], t[3] end
    return nil
end

local lastGroundTruthMs = 0
local function tickWriteGroundTruth()
    local now = Ext.Utils.MonotonicTime()
    if now - lastGroundTruthMs < 500 then return end
    lastGroundTruthMs = now
    local e = getControlledEntity()
    local paused = isGameplayPaused()
    local active = (e ~= nil) and (not paused)
    local x, y, z = 0, 0, 0
    if e then
        local tx, ty, tz = readTranslate(e)
        if tx then x, y, z = tx, ty, tz end
    end
    local line = string.format("active=%d x=%.4f y=%.4f z=%.4f t=%d",
        active and 1 or 0, x, y, z, now)
    pcall(Ext.IO.SaveFile, CHARPOS_PATH, line)
end
M.TickWriteGroundTruth = tickWriteGroundTruth

-- --- Char-facing follow (reads yaw written by DLL) ---------------------
local lastYawApplied = nil
local function tickApplyCamYaw()
    local ok, c = pcall(Ext.IO.LoadFile, CAMYAW_PATH)
    if not ok or not c or c == "" then return end
    local yaw = tonumber(c:match("yaw=([%-%d%.e]+)"))
    if not yaw then return end
    if lastYawApplied and math.abs(yaw - lastYawApplied) < 0.01 then return end
    lastYawApplied = yaw
    local e = getControlledEntity()
    if not e or not e.Transform or not e.Transform.RotationQuat then return end
    -- yaw is in radians, around Y-axis. Quat (w, x, y, z) with Y rotation:
    local half = yaw * 0.5
    local w = math.cos(half)
    local y = math.sin(half)
    pcall(function()
        e.Transform.RotationQuat = { w, 0, y, 0 }
        e:Replicate("Transform")
    end)
end
M.TickApplyCamYaw = tickApplyCamYaw

-- --- Console commands --------------------------------------------------
function M.Register(side)
    local v = readVersion()
    if v then Log.Write("Native: " .. v)
    else      Log.Write("Native: no DLL detected (file " .. VERSION_PATH .. " missing)") end

    Ext.RegisterConsoleCommand("dag_native_version", function()
        local v2 = readVersion()
        if v2 then Log.Write("Native: " .. v2) else Log.Write("Native: no DLL detected") end
    end)

    if side ~= "Client" then return end

    -- Session-load: write eye_height once (DLL reads on tick).
    Ext.Events.SessionLoaded:Subscribe(function()
        local h = getEyeHeightForRace("Default")
        writeEyeHeight(h)
        Log.Write(string.format("Native: wrote eye_height=%.3f", h))
    end)

    -- Per-tick ground-truth + yaw apply. SE's Tick fires per frame; we
    -- throttle inside the writer.
    Ext.Events.Tick:Subscribe(function()
        pcall(tickWriteGroundTruth)
        pcall(tickApplyCamYaw)
    end)

    -- Live config pokes (DLL polls mtime; takes effect ~1 s later).
    Ext.RegisterConsoleCommand("dag_set_eye", function(_, arg)
        local h = tonumber(arg) or 1.65
        writeEyeHeight(h)
        Log.Write(string.format("Native: eye_height -> %.3f", h))
    end)

    local function setBool(section, key, value)
        updateConfigLine(string.format("^%%s*%s%%s*=", key),
            string.format("%s = %s", key, value and "true" or "false"))
    end
    local function setFloat(key, value)
        updateConfigLine(string.format("^%%s*%s%%s*=", key),
            string.format("%s = %.3f", key, value))
    end

    Ext.RegisterConsoleCommand("dag_camera", function(_, arg)
        local on = (arg == "on" or arg == "1" or arg == "true")
        setBool("dag.camera", "enabled", on)
        Log.Write("dag.camera.enabled -> " .. tostring(on))
    end)
    Ext.RegisterConsoleCommand("dag_mouselook", function(_, arg)
        local on = (arg == "on" or arg == "1" or arg == "true")
        setBool("dag.mouselook", "enabled", on)
        Log.Write("dag.mouselook.enabled -> " .. tostring(on))
    end)
    Ext.RegisterConsoleCommand("dag_charface", function(_, arg)
        local on = (arg == "on" or arg == "1" or arg == "true")
        setBool("dag.mouselook", "character_facing", on)
        Log.Write("dag.mouselook.character_facing -> " .. tostring(on))
    end)

    -- Stubs (DLL logs the intent; real impl pending RE).
    Ext.RegisterConsoleCommand("dag_animspeed", function(_, arg)
        local f = tonumber(arg) or 1.0
        updateConfigLine("^%s*anim_test_speed%s*=",
            string.format("anim_test_speed = %.3f", f))
        Log.Write(string.format("dag_animspeed: wrote %.3f (DLL stub will log, no engine write yet)", f))
    end)
    Ext.RegisterConsoleCommand("dag_hitstop", function(_, arg)
        local ms = tonumber(arg) or 100
        updateConfigLine("^%s*hit_stop_test_ms%s*=",
            string.format("hit_stop_test_ms = %d", ms))
        Log.Write(string.format("dag_hitstop: wrote %dms (stub)", ms))
    end)
    Ext.RegisterConsoleCommand("dag_bone", function(_, arg)
        local name = arg or "Head"
        updateConfigLine("^%s*bone_test_name%s*=",
            string.format('bone_test_name = "%s"', name))
        Log.Write("dag_bone: wrote " .. name .. " (stub)")
    end)

    -- Raycast: REAL via SE Lua. No DLL involvement.
    Ext.RegisterConsoleCommand("dag_raynormal", function()
        local pick = Ext.Client.GetPickingHelper(1)
        if not pick then Log.Write("raycast: no picking helper"); return end
        local orig = pick.WalkablePosition or { 0, 0, 0 }
        local dir  = { 0, -1, 0 }  -- straight down; simplest test
        local hit = Ext.Level.RaycastClosest(orig, dir, { "Visible", "Walkable", "Default" })
        if not hit then Log.Write("raycast: no hit"); return end
        Log.Write(string.format(
            "raycast: pos=(%.2f,%.2f,%.2f) normal=(%.2f,%.2f,%.2f) entity=%s",
            hit.Position[1], hit.Position[2], hit.Position[3],
            hit.Normal[1],   hit.Normal[2],   hit.Normal[3],
            tostring(hit.HitObject)))
    end)
end

return M
