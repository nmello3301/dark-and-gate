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
local PROBE_PATH    = "DarkAndGate/native-phase-probe.txt" -- Phase 1 read-only probe

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
local Me = Ext.Require("Client/Me.lua")       -- the local player's character (multiplayer)
local MPState = Ext.Require("Shared/MPState.lua")
local function getControlledEntity()
    -- Preferred: ClientControl component; in co-op other players' characters
    -- can carry it too, so Me.All() puts the local one first (Client/Me.lua).
    local ok, entities = pcall(Me.All)
    if ok and entities and #entities > 0 then
        return entities[1]
    end
    -- (The old picking-helper fallback read pick.HoverCharacter, a field the
    -- helper doesn't have, and the hovered character isn't the controlled
    -- one anyway: removed 2026-10-12.)
    return nil
end
M.GetControlledEntity = getControlledEntity

-- Returns true if any dialog on the controlled character or a party
-- member is active, or any cinematic/cutscene is playing.
local function isGameplayPaused()
    -- Co-op: another player's dialogue must not pause THIS player; the
    -- server's per-player scene message (Server/Scene.lua) covers ours.
    if MPState.Multi() then return false end
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
local lastCamYawReadMs = 0
local function tickApplyCamYaw()
    local now = Ext.Utils.MonotonicTime()
    if now - lastCamYawReadMs < 500 then return end
    lastCamYawReadMs = now
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
    -- Head hide driver: reads [dag.camera] hide_head from the TOML (via
    -- a fresh file read, cheap); calls Spike11's apply(true/false) on
    -- state change. Spike11 handles the per-player RenderPasses zero.
    local Spike11 = Ext.Require("Spikes/Spike11_HeadHiding.lua")
    local lastHideHead = false
    local lastHideHeadPollMs = 0
    local function readHideHeadFlag()
        local okC, c = pcall(Ext.IO.LoadFile, CONFIG_PATH)
        if not okC or not c then return false end
        local v = c:match("%[dag%.camera%][^%[]-hide_head%s*=%s*(%w+)")
        return v == "true" or v == "True" or v == "1"
    end
    -- Keep the head hidden: the engine sometimes writes RenderPasses back.
    -- Movement round (2026-10-09): a 1000 ms safety check (was 100 ms) plus
    -- an immediate re-hide when the player's equipment or visual changes
    -- (Spike11.PollVisualChange, a 200 ms signature check), which is when new head / helmet
    -- renderables appear.
    local ENFORCE_MS = 1000
    local lastEnforceMs = 0
    local function tickHeadHide()
        local now = Ext.Utils.MonotonicTime()
        if lastHideHead and Spike11 and Spike11.PollVisualChange then pcall(Spike11.PollVisualChange) end
        local due = Spike11 and Spike11.TakeEventRequest and Spike11.TakeEventRequest()
        if lastHideHead and (due or now - lastEnforceMs >= ENFORCE_MS) and Spike11 and Spike11.Enforce then
            lastEnforceMs = now
            pcall(Spike11.Enforce, due)
        end
        if now - lastHideHeadPollMs < 500 then return end
        lastHideHeadPollMs = now
        local want = readHideHeadFlag()
        if want ~= lastHideHead then
            lastHideHead = want
            Log.Write("Native: hide_head -> " .. tostring(want))
            if Spike11 and Spike11.Apply then
                pcall(Spike11.Apply, want)
            end
        end
    end
    Ext.Events.Tick:Subscribe(function() pcall(tickHeadHide) end)
    Ext.RegisterConsoleCommand("dag_hidehead", function(_, arg)
        local on = (arg == "on" or arg == "1" or arg == "true")
        updateConfigLine("^%s*hide_head%s*=",
            string.format("hide_head         = %s", on and "true" or "false"))
        Log.Write("dag.camera.hide_head -> " .. tostring(on))
    end)

    Ext.RegisterConsoleCommand("dag_camcheck", function()
        -- (A) Rendered position + forward from active camera's InvViewMatrix.
        -- Column-major mat4 (1-indexed in SE Lua):
        --   [1..4]=right col, [5..8]=up col, [9..11..12]=forward col (negated
        --   or not depending on handedness; empirically matches our write),
        --   [13..15]=translation.
        local renderedX, renderedY, renderedZ, renderedFx, renderedFy, renderedFz
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
                    renderedX  = m[13]; renderedY  = m[14]; renderedZ  = m[15]
                    renderedFx = m[9];  renderedFy = m[10]; renderedFz = m[11]
                    if active then activeTag = "active"; break else activeTag = "fallback" end
                end
            end
        end

        -- (B) DLL status line.
        local statusLine = ""
        local okS, s = pcall(Ext.IO.LoadFile, STATUS_PATH)
        if okS and s then statusLine = s:match("[^\r\n]+") or "" end

        -- (C) Live char pos.
        local charX, charY, charZ = nil, nil, nil
        local e = getControlledEntity()
        if e then charX, charY, charZ = readTranslate(e) end

        -- Convention probe: read all three InvViewMatrix columns + translation.
        local mCol0X, mCol0Y, mCol0Z    -- col 0 = right-ish
        local mCol1X, mCol1Y, mCol1Z    -- col 1 = up-ish
        local mCol2X, mCol2Y, mCol2Z    -- col 2 = forward or -forward
        local mTrX,  mTrY,  mTrZ        -- col 3 = translation = eye
        for _, eh in ipairs(cams) do
            local ent = Ext.Entity.Get(eh)
            local _, cam = pcall(function() return ent.Camera end)
            if cam then
                local _, active = pcall(function() return cam.Active end)
                local _, ctl    = pcall(function() return cam.Controller end)
                local _, inner  = pcall(function() return ctl and ctl.Camera end)
                local _, m      = pcall(function() return inner and inner.InvViewMatrix end)
                if m and active then
                    mCol0X, mCol0Y, mCol0Z = m[1],  m[2],  m[3]
                    mCol1X, mCol1Y, mCol1Z = m[5],  m[6],  m[7]
                    mCol2X, mCol2Y, mCol2Z = m[9],  m[10], m[11]
                    mTrX,  mTrY,  mTrZ    = m[13], m[14], m[15]
                    break
                end
            end
        end

        Log.Write("--- dag_camcheck ---")
        Log.Write(string.format("A rendered eye (%s): (%.3f, %.3f, %.3f)",
            activeTag,
            renderedX or 0/0, renderedY or 0/0, renderedZ or 0/0))
        Log.Write(string.format("A rendered fwd (col2): (%.3f, %.3f, %.3f)",
            renderedFx or 0/0, renderedFy or 0/0, renderedFz or 0/0))
        if mCol0X then
            Log.Write(string.format("A InvView col0 (right): (%.3f, %.3f, %.3f)", mCol0X, mCol0Y, mCol0Z))
            Log.Write(string.format("A InvView col1 (up)   : (%.3f, %.3f, %.3f)", mCol1X, mCol1Y, mCol1Z))
            Log.Write(string.format("A InvView col2 (fwd?) : (%.3f, %.3f, %.3f)", mCol2X, mCol2Y, mCol2Z))
            Log.Write(string.format("A InvView trans (eye) : (%.3f, %.3f, %.3f)", mTrX, mTrY, mTrZ))
        end
        Log.Write("B DLL status : " .. (statusLine == "" and "(no status file yet)" or statusLine))
        Log.Write(string.format("C char live  : (%.3f, %.3f, %.3f)",
            charX or 0/0, charY or 0/0, charZ or 0/0))

        -- Phase 1 read-only probe: cam[0x18] vs cam[0x24] vs cam[0xC4]
        -- vs Lua char Translate. Lets us see which offset is the LERPED
        -- pivot (lags behind the character on fast motion) and which is
        -- the pre-lerp target (same-frame-correct).
        local probeLine = ""
        local okP, p = pcall(Ext.IO.LoadFile, PROBE_PATH)
        if okP and p then probeLine = p:match("[^\r\n]+") or "" end
        if probeLine ~= "" then
            Log.Write("D phase probe: " .. probeLine)
            local function parseVec(s, key)
                local x,y,z = s:match(key .. "=([%-%d%.e]+),([%-%d%.e]+),([%-%d%.e]+)")
                if x then return tonumber(x), tonumber(y), tonumber(z) end
            end
            local rx, ry, rz = parseVec(probeLine, "root")
            local dx, dy, dz = parseVec(probeLine, "desired")
            if rx and dx and charX then
                local rChX = rx - charX; local rChZ = rz - charZ
                local dChX = dx - charX; local dChZ = dz - charZ
                Log.Write(string.format(
                    "   root-char   XZ=(%.3f,%.3f)  |XZ|=%.3f",
                    rChX, rChZ, math.sqrt(rChX*rChX + rChZ*rChZ)))
                Log.Write(string.format(
                    "   desired-char XZ=(%.3f,%.3f)  |XZ|=%.3f",
                    dChX, dChZ, math.sqrt(dChX*dChX + dChZ*dChZ)))
                Log.Write("   (smaller XZ gap = less lag; the field that stays near 0 on motion is the pre-lerp target)")
            end
        else
            Log.Write("D phase probe: (no probe file yet — rebuild + redeploy DLL)")
        end

        -- Convention probe: which column equals normalize(lookAt - engEye)?
        local lx, ly, lz = statusLine:match("lookAt=([%-%d%.e]+),([%-%d%.e]+),([%-%d%.e]+)")
        local ex, ey, ez = statusLine:match("engEye=([%-%d%.e]+),([%-%d%.e]+),([%-%d%.e]+)")
        if lx and ex and mCol0X then
            local dx = tonumber(lx) - tonumber(ex)
            local dy = tonumber(ly) - tonumber(ey)
            local dz = tonumber(lz) - tonumber(ez)
            local len = math.sqrt(dx*dx + dy*dy + dz*dz)
            if len > 0.01 then
                dx = dx / len; dy = dy / len; dz = dz / len
                Log.Write(string.format(
                    "   norm(lookAt - engEye) = (%.3f, %.3f, %.3f)",
                    dx, dy, dz))
                local function dot(ax,ay,az,bx,by,bz) return ax*bx+ay*by+az*bz end
                Log.Write(string.format("   dot vs col0=%.3f col1=%.3f col2=%.3f -col2=%.3f",
                    dot(dx,dy,dz, mCol0X,mCol0Y,mCol0Z),
                    dot(dx,dy,dz, mCol1X,mCol1Y,mCol1Z),
                    dot(dx,dy,dz, mCol2X,mCol2Y,mCol2Z),
                    dot(dx,dy,dz, -mCol2X,-mCol2Y,-mCol2Z)))
            end
        end

        -- Rendered eye vs ourEye (what the DLL wrote).
        local oex, oey, oez = statusLine:match("ourEye=([%-%d%.e]+),([%-%d%.e]+),([%-%d%.e]+)")
        if oex and renderedX then
            local dx = renderedX - tonumber(oex)
            local dy = renderedY - tonumber(oey)
            local dz = renderedZ - tonumber(oez)
            Log.Write(string.format("eye   rendered - ourEye = (%.3f, %.3f, %.3f) %s",
                dx, dy, dz,
                (math.abs(dx)<=0.05 and math.abs(dy)<=0.05 and math.abs(dz)<=0.05)
                    and "MATCH" or "MISS"))
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
            -- PhysicsType is a bitmask: a table of labels ("Static,Dynamic" as one string raised).
            return Ext.Level.RaycastClosest(src, dst, { "Static", "Dynamic" }, 0xFFFFFFFF, 0, 0)
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
