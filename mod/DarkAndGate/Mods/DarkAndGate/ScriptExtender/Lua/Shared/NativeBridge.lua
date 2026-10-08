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
local STATUS_PATH   = "DarkAndGate/native-cam-status.txt"  -- DLL writes

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
    local ok2, pick = pcall(Ext.UI.GetPickingHelper, 1)
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
-- Entity.Transform is a TransformComponent whose .Transform is the
-- actual Transform struct (RotationQuat, Scale, Translate). Confirmed
-- in bg3se IdeHelpers.lua:7110 and GameDefinitions/Components/Spell.inl.
local function readTranslate(entity)
    if not entity then return nil end
    local ok, t = pcall(function()
        return entity.Transform
           and entity.Transform.Transform
           and entity.Transform.Transform.Translate
    end)
    if not ok or not t then return nil end
    -- vec3 may expose [1..3] or .x/.y/.z depending on SE version.
    local x = t[1] or t.x
    local y = t[2] or t.y
    local z = t[3] or t.z
    if x and y and z then return x, y, z end
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
    if not e or not e.Transform or not e.Transform.Transform then return end
    -- yaw is in radians, around Y-axis. Quat (w, x, y, z) with Y rotation:
    local half = yaw * 0.5
    local w = math.cos(half)
    local y = math.sin(half)
    pcall(function()
        e.Transform.Transform.RotationQuat = { w, 0, y, 0 }
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

    -- Objective check: compare three positions.
    --   (A) Rendered camera position — Spike2's InvViewMatrix method:
    --       Camera.Controller.Camera.InvViewMatrix translation (indices
    --       13..15, column-major mat4). This is what the renderer uses.
    --   (B) DLL's last written position — read from native-cam-status.txt
    --       which the camera hook writes once per second.
    --   (C) Live character position via SE Transform component.
    -- "Our write reaches the screen" iff |A - DLL.wrote| <= 0.05 m.
    Ext.RegisterConsoleCommand("dag_camcheck", function()
        -- (A) Rendered position.
        local renderedX, renderedY, renderedZ
        local activeTag = "none"
        local cams = Ext.Entity.GetAllEntitiesWithComponent("Camera") or {}
        for _, eh in ipairs(cams) do
            local ent = Ext.Entity.Get(eh)
            local _, cam = pcall(function() return ent.Camera end)
            if cam then
                local _, active = pcall(function() return cam.Active end)
                local _, ctl    = pcall(function() return cam.Controller end)
                local _, inner  = pcall(function() return ctl and ctl.Camera end)
                local _, m      = pcall(function() return inner and inner.InvViewMatrix end)
                if m and (active or not renderedX) then
                    renderedX = m[13]; renderedY = m[14]; renderedZ = m[15]
                    if active then activeTag = "active"; break else activeTag = "fallback" end
                end
            end
        end

        -- (B) DLL last-wrote line.
        local statusLine = ""
        local okS, s = pcall(Ext.IO.LoadFile, STATUS_PATH)
        if okS and s then statusLine = s:match("[^\r\n]+") or "" end

        -- (C) Live char pos.
        local charX, charY, charZ = nil, nil, nil
        local e = getControlledEntity()
        if e then charX, charY, charZ = readTranslate(e) end

        Log.Write("--- dag_camcheck ---")
        Log.Write(string.format("A rendered   (%s): (%.3f, %.3f, %.3f)",
            activeTag,
            renderedX or 0/0, renderedY or 0/0, renderedZ or 0/0))
        Log.Write("B DLL status : " .. (statusLine == "" and "(no status file yet)" or statusLine))
        Log.Write(string.format("C char live  : (%.3f, %.3f, %.3f)",
            charX or 0/0, charY or 0/0, charZ or 0/0))
        -- Parse wrote=x,y,z from statusLine to compute diff.
        local wx, wy, wz = statusLine:match("wrote=([%-%d%.e]+),([%-%d%.e]+),([%-%d%.e]+)")
        if wx and renderedX then
            local dx = renderedX - tonumber(wx)
            local dy = renderedY - tonumber(wy)
            local dz = renderedZ - tonumber(wz)
            Log.Write(string.format(
                "diff rendered - DLL wrote = (%.3f, %.3f, %.3f); |dy|=%.3f -> %s",
                dx, dy, dz, math.abs(dy),
                (math.abs(dx) <= 0.05 and math.abs(dy) <= 0.05 and math.abs(dz) <= 0.05)
                    and "MATCH (write reaches screen)"
                    or  "MISS (write does NOT reach screen)"))
        end
    end)

    -- Raycast: REAL via SE Lua. No DLL involvement.
    -- Signature per bg3se Level.inl:280 (RaycastClosest):
    --   (source: vec3, destination: vec3, physicsType, includeGroups,
    --    excludeGroups, context: int) -> PhxPhysicsHit
    -- physicsType is a PhysicsType bitmask ("Static" | "Dynamic").
    -- Groups is PhysicsGroupFlags bitmask; empty = all.
    Ext.RegisterConsoleCommand("dag_raynormal", function()
        local e = getControlledEntity()
        if not e then Log.Write("raycast: no controlled entity"); return end
        local tx, ty, tz = readTranslate(e)
        if not tx then Log.Write("raycast: no translate"); return end
        -- Start 1 m above the character's feet, cast 10 m straight down.
        local src = { tx, ty + 1.0, tz }
        local dst = { tx, ty - 10.0, tz }
        -- include=0xFFFFFFFF matches every PhysicsGroupFlags bit (terrain,
        -- scenery, character, etc.). exclude=0 means filter nothing out.
        local ok, hit = pcall(function()
            return Ext.Level.RaycastClosest(src, dst, "Static,Dynamic", 0xFFFFFFFF, 0, 0)
        end)
        if not ok then Log.Write("raycast: call errored: " .. tostring(hit)); return end
        if not hit then Log.Write("raycast: no hit"); return end
        local pos = hit.Position or hit.ImpactPosition or { 0, 0, 0 }
        local nrm = hit.Normal   or hit.ImpactNormal   or { 0, 0, 0 }
        Log.Write(string.format(
            "raycast: pos=(%.2f,%.2f,%.2f) normal=(%.2f,%.2f,%.2f)",
            pos[1], pos[2], pos[3], nrm[1], nrm[2], nrm[3]))
    end)
end

return M
