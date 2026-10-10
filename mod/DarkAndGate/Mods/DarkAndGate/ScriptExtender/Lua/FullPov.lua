-- SPDX-License-Identifier: GPL-3.0-or-later
-- Full first-person POV: one console command, !dag_full_pov.
--
-- Lua's job is only to tell the DLL WHERE things are; the DLL does all
-- per-frame camera work (see tools/native/src/Hooks/Pov.cpp):
--   * on / active (active = no dialog or cutscene running)
--   * eye offsets (tunable with !dag_pov_eye)
--   * the controlled character's root position (sanity reference)
--   * the head socket's bone index and the skeleton bone count
--   * the memory addresses of the character's MeshBinding objects,
--     taken from tostring() of the SE userdata ("MeshBinding (ADDR)").
--     The DLL reads the head bone straight out of their Pose arrays.
--
-- Commands (client console, C >>):
--   !dag_full_pov [on|off]      toggle first-person POV
--   !dag_pov_eye <up> <fwd> [look]  eye offset from the head bone, metres
--   !dag_pov_anchor [head|pivot] camera on the head bone (default) or the engine pivot
--                               ("bone" = "head"); prints the A/B status line
--   !dag_pov_smooth <0..0.9>    light smoothing of the head bone (0 = raw, default)
--   !dag_pov_down <m>           extra forward shift when looking straight down (default 0.20)
--   !dag_pov_dump               DLL logs every pose candidate to native.log
--   !dag_pov_status             print the DLL's POV status line

local Log = Ext.Require("Shared/Log.lua")

local M = {}

local POV_PATH    = "DarkAndGate/native-pov.txt"
local STATUS_PATH = "DarkAndGate/native-pov-status.txt"
local CONFIG_PATH = "DarkAndGate/native-config.toml"

local S = {
    on = false,
    eye_up = 0.00,
    eye_fwd = 0.10,
    look = 1.0,
    eye_height = 1.65,
    pivot_up = -0.15,
    down_fwd = 0.20,
    dump = 0,
    -- 1 = camera anchored on the head bone (follows the body through
    -- attacks and jumps), 0 = the engine pivot (the M1a camera).
    anchor = 1,
    -- Jump lift (Client/Movement/Jump.lua -> M.Jump). The DLL starts the
    -- lift curve the frame it sees a new jump_seq.
    jump_seq = 0,
    jump_ms = 0,
    jump_h = 0,
    jump_k = 2,
    -- Per-character animation play rate (AnimRate.cpp): the character's
    -- GenomeBlueprintInstance address and the rate; rate 1 = off.
    anim_inst = "0",
    anim_rate = 1.0,
    -- Head-bone smoothing (0 = raw pose). Only if the CAM delta lines in
    -- native.log show jitter (docs/playtest/movement-round.md step 1).
    head_smooth = 0.0,
    -- Animation recorder target (Client/AnimLib/Recorder.lua): the
    -- player's GenomeBlueprintInstance address, "0" = off.
    rec_inst = "0",
    -- Per-clip play rates (AnimRate SetClipRates): "id:rate,id:rate" or "-".
    clip_inst = "0",
    clip_rates = "-",
    -- Jump: also lift the meshes' render objects (what is drawn), not only
    -- the root Visual. !dag_lift_objects off for A/B.
    lift_objects = 1,
    -- Jump mode: 0 = visual lift (default), 1 = real position (RealJump.cpp,
    -- docs/spikes/real-lift.md). strafe_sign flips A/D steering in the air.
    jump_mode = 0,
    -- 1 = the DLL logs every spell genome event to
    -- native-genome-capture.txt (GenomeCapture.cpp, docs/spikes/genome-capture.md).
    genome_capture = 0,
    strafe_sign = 1,
    rj_land_speed = 3.0,
    rj_wall_h = 1.5,
    -- WASD speed multipliers for the DLL's ground-speed lever
    -- (Client/Movement/Movement.lua, docs/spikes/move-speed.md).
    move_walk = 1.0,
    move_run = 1.0,
}

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
local function controlledEntity()
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    if ok and ents and #ents > 0 then return ents[1] end
    return nil
end

-- 2026-10-09: the head-bone anchor is back (the DLL reads Head_M from the
-- live Granny world pose, docs/spikes/m1b-head-bone.md). The DLL only needs
-- MeshBinding addresses now (no socket walk), refreshed every 3 s or when
-- the controlled character changes; the cost of each walk is logged for
-- the first few runs (fix3 measured 3-4 ms for the old mesh+socket walk).
local USE_BONE_ANCHOR = true
local MESH_REFRESH_MS = 3000

local pausedCache = { at = -1e9, v = false }
local function isPausedUncached()
    local ok, dlgs = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Dialog")
    if ok and dlgs and #dlgs > 0 then return true end
    for _, c in ipairs({ "Cinematic", "Cutscene", "ClientMoveToCutscene" }) do
        local ok2, es = pcall(Ext.Entity.GetAllEntitiesWithComponent, c)
        if ok2 and es and #es > 0 then return true end
    end
    return false
end

local function isPaused()
    local now = Ext.Utils.MonotonicTime()
    if now - pausedCache.at < 450 then return pausedCache.v end
    pausedCache.at = now
    pausedCache.v = isPausedUncached()
    return pausedCache.v
end

local function readTranslate(e)
    local ok, t = pcall(function() return e.Transform.Transform.Translate end)
    if not ok or not t then return nil end
    local x, y, z = t[1] or t.x, t[2] or t.y, t[3] or t.z
    if x and y and z then return x, y, z end
    return nil
end

local function addrOf(obj)
    if obj == nil then return nil end
    local ok, s = pcall(tostring, obj)
    if not ok or not s then return nil end
    local h = s:match("%(0x(%x+)") or s:match("%((%x+)")
    if h and #h >= 8 then return h end
    return nil
end

local function templateName(vis)
    local ok, tpl = pcall(function() return vis.VisualResource.Template end)
    if ok and tpl then return tostring(tpl) end
    return "?"
end

-- Collect MeshBinding addresses: the character's own renderables first
-- (the body binds the full skeleton), then each attachment's.
local function collectMeshes(ent, labels)
    local out, seen = {}, {}
    local function addVisual(vis, label)
        if vis == nil then return end
        local okO, descs = pcall(function() return vis.ObjectDescs end)
        if not okO or descs == nil then return end
        pcall(function()
            for i, od in ipairs(descs) do
                if #out >= 16 then return end
                local okR, r = pcall(function() return od.Renderable end)
                if okR and r then
                    local okM, mesh = pcall(function() return r.Mesh end)
                    if okM and mesh then
                        local h = addrOf(mesh)
                        if h and not seen[h] then
                            seen[h] = true
                            out[#out + 1] = h
                            if labels then labels[#labels + 1] = string.format("%s od[%d] %s", label, i, h) end
                        end
                    end
                end
            end
        end)
    end
    local okV, root = pcall(function() return ent.Visual.Visual end)
    if not okV or root == nil then return out end
    addVisual(root, "root")
    pcall(function()
        for i, att in ipairs(root.Attachments) do
            if #out >= 16 then return end
            addVisual(att.Visual, string.format("att[%d] %s", i, templateName(att.Visual)))
        end
    end)
    return out
end

-- Head socket bone index + skeleton bone count from the root visual.
local function headSocket(ent, lines)
    local bone, count, sockName = -1, 0, nil
    local okV, root = pcall(function() return ent.Visual.Visual end)
    if not okV or root == nil then return bone, count end
    pcall(function()
        for _, slot in pairs(root.SkeletonSlots) do
            local skel = slot.Skeleton
            if skel then
                local okC, c = pcall(function() return skel.BoneCount end)
                if okC and c then count = c end
                for _, so in ipairs(skel.Sockets) do
                    local name = tostring(so.Name)
                    local bi = so.BoneIndex
                    if lines then lines[#lines + 1] = string.format("socket %s bone=%s", name, tostring(bi)) end
                    if bone < 0 and (name:find("HeadFX") or name:find("Dummy_Head") or name == "Head") then
                        bone, sockName = bi, name
                    end
                end
                return
            end
        end
    end)
    return bone, count, sockName
end

local function setHideHead(on)
    local existing = ""
    local ok, c = pcall(Ext.IO.LoadFile, CONFIG_PATH)
    if ok and c then existing = c end
    local lines, replaced = {}, false
    for line in (existing .. "\n"):gmatch("([^\n]*)\n") do
        if not replaced and line:match("^%s*hide_head%s*=") then
            lines[#lines + 1] = string.format("hide_head            = %s", on and "true" or "false")
            replaced = true
        else
            lines[#lines + 1] = line
        end
    end
    if replaced then
        pcall(Ext.IO.SaveFile, CONFIG_PATH, table.concat(lines, "\n"))
    end
end

-- ---------------------------------------------------------------------
-- Per-tick writer
-- ---------------------------------------------------------------------
local cache = { meshes = {}, sock = -1, skel = 0, at = -100000, ent = nil, visual = nil, timed = 0 }
local lastWrite = 0

local function refreshCache(e, now)
    if e == nil then cache.meshes = {}; cache.visual = nil; return end
    -- Compare by handle string: a fresh entity userdata each tick need
    -- not compare equal to the cached one.
    local key = tostring(e)
    if cache.ent ~= key or now - cache.at > MESH_REFRESH_MS then
        local t0 = tonumber(Ext.Timer.MonotonicTime()) or 0
        cache.ent = key
        cache.at = now
        cache.meshes = collectMeshes(e, nil)
        local okV, vis = pcall(function() return e.Visual.Visual end)
        cache.visual = okV and addrOf(vis) or nil
        if cache.timed < 3 then
            cache.timed = cache.timed + 1
            Log.Write(string.format("FullPov: mesh walk %d meshes, visual=%s in %d ms",
                #cache.meshes, tostring(cache.visual), math.floor((tonumber(Ext.Timer.MonotonicTime()) or 0) - t0)))
        end
    end
end

local function writeState()
    local now = Ext.Utils.MonotonicTime()
    if now - lastWrite < 150 then return end
    lastWrite = now

    local e = controlledEntity()
    local active = (e ~= nil) and (not isPaused())
    local x, y, z = 0, 0, 0
    if e then
        local tx, ty, tz = readTranslate(e)
        if tx then x, y, z = tx, ty, tz end
    end
    if S.on and USE_BONE_ANCHOR then refreshCache(e, now) end

    local line = string.format(
        "on=%d active=%d anim_inst=%s anim_rate=%.3f clip_inst=%s clip_rates=%s rec_inst=%s lift_objects=%d jump_mode=%d genome_capture=%d strafe_sign=%d rj_land_speed=%.2f rj_wall_h=%.2f head_smooth=%.2f move_walk=%.3f move_run=%.3f visual=%s anchor=%d eye_up=%.3f eye_fwd=%.3f look=%.3f eye_height=%.3f pivot_up=%.3f down_fwd=%.3f jump_seq=%d jump_ms=%d jump_h=%.3f jump_k=%.2f dump=%d sock=%d skel=%d rootx=%.4f rooty=%.4f rootz=%.4f meshes=%s t=%d",
        S.on and 1 or 0, active and 1 or 0, S.anim_inst, S.anim_rate, S.clip_inst, S.clip_rates, S.rec_inst, S.lift_objects, S.jump_mode, S.genome_capture, S.strafe_sign, S.rj_land_speed, S.rj_wall_h, S.head_smooth, S.move_walk, S.move_run, (S.on and cache.visual) or "0", S.anchor, S.eye_up, S.eye_fwd, S.look, S.eye_height, S.pivot_up, S.down_fwd,
        S.jump_seq, math.floor(S.jump_ms + 0.5), S.jump_h, S.jump_k,
        S.dump, cache.sock or -1, cache.skel or 0, x, y, z,
        (S.on and #cache.meshes > 0) and table.concat(cache.meshes, ",") or "0",
        now)
    pcall(Ext.IO.SaveFile, POV_PATH, line)
end

local function readStatus()
    local ok, s = pcall(Ext.IO.LoadFile, STATUS_PATH)
    if ok and s then return s:match("[^\r\n]+") end
    return nil
end

-- ---------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------
-- BootstrapClient wires this once at load. We avoid Ext.Require inside
-- setOn because `pcall(Ext.Require, ...)` broke path resolution in the
-- round-2 build (povOn stayed false in-game even though setOn ran).
-- The injected reference is the exact same module table the Input / HUD /
-- Debug modules see, so a write here is visible across combat Lua on
-- the same frame.
local linkedState = nil
function M.LinkState(state) linkedState = state end

local function setOn(on)
    S.on = on
    cache.at = -100000
    setHideHead(on)
    lastWrite = 0
    writeState()
    if linkedState then
        linkedState.povOn = on
        Log.Write("FullPov: State.povOn <- " .. tostring(on))
    else
        Log.Write("FullPov: WARNING — LinkState never called; povOn gate will stay false")
    end
    if on then
        Log.Write("FullPov: ON. Mouse-look is on; press MMB to toggle it. !dag_full_pov again to exit.")
    else
        Log.Write("FullPov: OFF.")
    end
end

-- Start a jump lift in the DLL. Written straight away (not on the next
-- 150 ms tick) so the lift starts within a frame of the key press.
function M.Jump(seq, durMs, height, flatness)
    S.jump_seq, S.jump_ms, S.jump_h, S.jump_k = seq, durMs, height, flatness
    lastWrite = 0
    pcall(writeState)
end

-- Per-character play rate through the DLL's PlayAnimation hook.
-- inst: hex address of ent.AnimationBlueprint.Instance (nil = off).
function M.SetAnimRate(inst, rate)
    S.anim_inst = inst or "0"
    S.anim_rate = rate or 1.0
    lastWrite = 0
    pcall(writeState)
end
M.AddrOf = function(o) return addrOf(o) end

-- Jump mode for the DLL: "real" (the character's real position) or "visual".
function M.SetJumpMode(mode)
    S.jump_mode = (mode == "real") and 1 or 0
    lastWrite = 0
    pcall(writeState)
end
function M.JumpMode() return S.jump_mode == 1 and "real" or "visual" end

-- Native capture of the spell genome events (GenomeCapture.cpp).
function M.SetGenomeCapture(on)
    S.genome_capture = on and 1 or 0
    lastWrite = 0
    pcall(writeState)
end
function M.SetRealJumpTuning(strafeSign, landSpeed, wallH)
    if strafeSign then S.strafe_sign = strafeSign < 0 and -1 or 1 end
    if landSpeed then S.rj_land_speed = landSpeed end
    if wallH then S.rj_wall_h = wallH end
    lastWrite = 0
    pcall(writeState)
end
function M.FlipStrafe()
    S.strafe_sign = -S.strafe_sign
    lastWrite = 0
    pcall(writeState)
    return S.strafe_sign
end

-- Per-clip play rates on one character (hex instance, { [mappingId] = rate }).
function M.SetClipRates(inst, rates)
    local parts = {}
    for id, r in pairs(rates or {}) do parts[#parts + 1] = string.format("%s:%.3f", id, r) end
    table.sort(parts)
    local spec = #parts > 0 and table.concat(parts, ",") or "-"
    if spec == S.clip_rates and (inst or "0") == S.clip_inst then return end
    S.clip_inst, S.clip_rates = inst or "0", spec
    lastWrite = 0
    pcall(writeState)
end

-- Animation recorder (hex instance address or nil = off).
function M.SetRecInst(inst)
    S.rec_inst = inst or "0"
    lastWrite = 0
    pcall(writeState)
end
function M.RecInst() return S.rec_inst ~= "0" and S.rec_inst or nil end

-- WASD speed multipliers (walk, run) for the DLL.
function M.SetMove(walk, run)
    if math.abs((walk or 1) - S.move_walk) < 1e-4 and math.abs((run or 1) - S.move_run) < 1e-4 then return end
    S.move_walk, S.move_run = walk or 1.0, run or 1.0
    lastWrite = 0
    pcall(writeState)
end

-- One key=value from the DLL status line (nil if missing).
function M.StatusValue(key)
    local ok, s = pcall(Ext.IO.LoadFile, STATUS_PATH)
    if not ok or not s then return nil end
    return s:match("%s" .. key .. "=([^%s]+)") or s:match("^" .. key .. "=([^%s]+)")
end

local function abLine()
    local st = readStatus() or ""
    local function v(k) return st:match("[%s]" .. k .. "=([^%s]+)") or st:match("^" .. k .. "=([^%s]+)") or "?" end
    return string.format("anchor=%s src=%s eye=%s head=%s delta=%s deltaMax=%s jerk=%s smooth=%s headCal=%s eyeUpAuto=%s",
        v("anchor"), v("src"), v("eye"), v("head"), v("delta"), v("deltaMax"), v("jerk"), v("smooth"), v("headCal"), v("eyeUpAuto"))
end
M.ABLine = abLine

-- Animation browser: third person while its window is open.
function M.SetOn(on) setOn(on and true or false) end
function M.IsOn() return S.on end

function M.Register()
    -- POV starts off every session; make sure a hide_head left on by a
    -- previous session doesn't fire before the character exists.
    setHideHead(false)
    Ext.Events.Tick:Subscribe(function() pcall(writeState) end)

    Ext.RegisterConsoleCommand("dag_full_pov", function(_, arg)
        if arg == "on" or arg == "1" then setOn(true)
        elseif arg == "off" or arg == "0" then setOn(false)
        else setOn(not S.on) end
    end)

    Ext.RegisterConsoleCommand("dag_pov_eye", function(_, up, fwd, look)
        S.eye_up  = tonumber(up)  or S.eye_up
        S.eye_fwd = tonumber(fwd) or S.eye_fwd
        S.look    = tonumber(look) or S.look
        Log.Write(string.format("FullPov: eye_up=%.3f eye_fwd=%.3f look=%.2f", S.eye_up, S.eye_fwd, S.look))
    end)

    Ext.RegisterConsoleCommand("dag_pov_anchor", function(_, a)
        if a == "pivot" or a == "0" then S.anchor = 0
        elseif a == "head" or a == "bone" or a == "1" then S.anchor = 1
        else S.anchor = 1 - S.anchor end
        lastWrite = 0
        pcall(writeState)
        Log.Write("FullPov: camera anchor = " .. (S.anchor == 1 and "head bone" or "engine pivot")
            .. " | last DLL status: " .. abLine())
    end)

    Ext.RegisterConsoleCommand("dag_lift_objects", function(_, a)
        if a == "off" or a == "0" then S.lift_objects = 0 elseif a == "on" or a == "1" then S.lift_objects = 1
        else S.lift_objects = 1 - S.lift_objects end
        lastWrite = 0
        pcall(writeState)
        Log.Write("FullPov: jump lifts the render objects = " .. (S.lift_objects == 1 and "ON" or "OFF (root Visual only)"))
    end)

    Ext.RegisterConsoleCommand("dag_pov_smooth", function(_, x)
        local v = tonumber(x)
        if v then S.head_smooth = math.max(0, math.min(0.9, v)) end
        lastWrite = 0
        pcall(writeState)
        Log.Write(string.format("FullPov: head smoothing = %.2f (0 = raw pose)", S.head_smooth))
    end)

    Ext.RegisterConsoleCommand("dag_pov_down", function(_, m)
        S.down_fwd = tonumber(m) or S.down_fwd
        Log.Write(string.format("FullPov: down_fwd=%.3f (forward shift when looking straight down)", S.down_fwd))
    end)

    Ext.RegisterConsoleCommand("dag_pov_dump", function()
        S.dump = S.dump + 1
        local e = controlledEntity()
        if e then
            local labels, socks = {}, {}
            collectMeshes(e, labels)
            local b, c, n = headSocket(e, socks)
            Log.Write(string.format("FullPov dump: %d meshes, head socket=%s bone=%s skelBones=%s",
                #labels, tostring(n), tostring(b), tostring(c)))
            for _, l in ipairs(labels) do Log.Write("FullPov dump: mesh " .. l) end
            for _, l in ipairs(socks) do Log.Write("FullPov dump: " .. l) end
            local tx, ty, tz = readTranslate(e)
            Log.Write(string.format("FullPov dump: root=(%.3f, %.3f, %.3f)", tx or 0, ty or 0, tz or 0))
        else
            Log.Write("FullPov dump: no controlled entity")
        end
        Log.Write("FullPov dump: DLL pose dump requested (see native.log, 'POV dump:' lines)")
    end)

    Ext.RegisterConsoleCommand("dag_pov_status", function()
        Log.Write("FullPov status: " .. (readStatus() or "(no status file -- is DarkAndGate.dll loaded?)"))
        Log.Write("FullPov A/B: " .. abLine())
    end)

    Log.Write("FullPov: registered !dag_full_pov / !dag_pov_eye / !dag_pov_anchor / !dag_pov_smooth / !dag_pov_down / !dag_pov_dump / !dag_pov_status")
end

return M
