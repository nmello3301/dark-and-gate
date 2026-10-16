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
--   !dag_pov_foreign [follow|hold] [mouse_ms] [ease_ms]
--                               view direction while BG3's camera is not on you

local Log = Ext.Require("Shared/Log.lua")
local Me = Ext.Require("Client/Me.lua")   -- the local player's character (multiplayer)
local MPState = Ext.Require("Shared/MPState.lua")
local FOREIGN = Ext.Require("data/camera.lua").foreign_camera or {}

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
    -- Per-clip play rates on other characters (AnimRate SetNpcClipRates,
    -- Client/Combat/Bow.lua: NPC / co-op archers' draws): "INST:ID:RATE|..." or "-".
    nclips = "-",
    -- 1 = the DLL clears the camera's combat mode flag while first person is on
    -- (BG3's combat camera would follow casters and give WASD to the camera).
    nocombatcam = 1,
    -- 1 = the DLL skips BG3's "no WASD while in a combat" check while first
    -- person is on (CombatWasd.cpp); !dag_combat_wasd on|off.
    combat_wasd = 1,
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
    rj_sync_guard = 1,   -- RealJump: skip the server-flag reset during a jump
    jump_wait_ms = 250,  -- bunny-hop grace: a jump that comes while still falling waits this long for the landing
    rj_land_hold = 0,    -- RealJump: 1 = keep BG3's landing hold (recover) after a jump
    rj_slope_deg = 50,   -- RealJump: steepest uphill the jump's floor follows (0 = off)
    mp_tag = "-",        -- multiplayer: native.log line tag ("p2", "p1-host"; Client/MP.lua)
    mp_remote = 0,       -- multiplayer: 1 = other players connected (the host's server replays their direct movement)
    -- WASD speed multipliers for the DLL's ground-speed lever
    -- (Client/Movement/Movement.lua, docs/spikes/move-speed.md).
    move_walk = 1.0,
    move_run = 1.0,
    -- Direct WASD controller (MoveFeel.cpp, Client/Movement/Movement.lua):
    -- move_mode 1 = direct, 0 = vanilla; accel / decel seconds; move_turn -1
    -- instant facing, 0 = BG3's steering, > 0 deg/s; move_raw 1 = physical
    -- keys; move_hold 1 = input released; move_metrics 1 = MOVEFEEL lines.
    move_mode = 0, move_accel = 0.06, move_decel = 0.04, move_turn = 0,
    move_raw = 0, move_hold = 0, move_metrics = 0,
    -- Body facing from the camera: standing still past move_face_idle deg
    -- (0 = never); move_face_air 1 = in the air all the time.
    move_face_idle = 30, move_face_air = 1,
    -- Locomotion Start / End / turn clips fast-forwarded in direct mode
    -- (Client/Movement/LocoSkip.lua, AnimRate SetLocoSkip).
    loco_inst = "0", loco_skip = "-", loco_rate = 1.0,
    -- Crouch = sneaking (Client/Crouch.lua): the DLL pauses its eye-height
    -- calibration while crouched (the head bone lowers by itself).
    crouch = 0,
    -- Bumped on a level load / fast travel / teleport: the DLL resets its
    -- head selection and forgets the WASD character (stale pointers).
    level_seq = 0,
    -- Downed orbit camera (Client/Downed.lua, Pov.cpp OrbitCommit).
    orbit = 0, orbit_seq = 0, orbit_dist = 3.5, orbit_up = 0.6, orbit_pmin = -10, orbit_pmax = 70,
    orbit_spin = 0, orbit_tilt = 0, orbit_rate = 120, orbit_tilt_rate = 60, orbit_vis = "0",
    orbit_x = 0, orbit_y = 0, orbit_z = 0,
    -- Foreign camera (data/camera.lua foreign_camera, Pov.cpp Foreign): while
    -- BG3 renders through a camera that is not on you, 1 = the view keeps
    -- following your mouse, 0 = it holds the last direction; mouse window
    -- and ease back, ms.
    foreign_follow = (FOREIGN.follow == false) and 0 or 1,
    foreign_mouse_ms = tonumber(FOREIGN.mouse_ms) or 300,
    foreign_ease_ms = tonumber(FOREIGN.ease_ms) or 150,
}

-- Level loads and teleports (2026-10-12, fast travel): first person goes
-- inactive while the world is (re)loading and comes back after a settle
-- delay, so the DLL re-presses Camera Rotate once BG3 takes input again.
local settle = { loading = false, untilMs = 0, lastPos = nil, why = nil }
local SETTLE_LOAD_MS, SETTLE_TP_MS, TELEPORT_M = 1000, 500, 8.0

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
local function controlledEntity()
    local ok, ents = pcall(Me.All)
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
local linkedState = nil   -- Client/Combat/State.lua (M.LinkState, below)
local function isPausedUncached()
    -- A dialogue / cutscene the server reported (Server/Scene.lua), or BG3's
    -- game-over screen after giving up (Client/Downed.lua).
    if linkedState and (linkedState.sceneOn or linkedState.gameOver) then return true end
    -- Co-op: another player's dialogue must not pause our first person; the
    -- server's per-player scene message (sceneOn) covers ours.
    if MPState.Multi() then return false end
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

-- The head is hidden only while the camera is in your eyes (developer
-- 2026-10-13: "if we are zoomed out of first person POV, the head renders
-- again"): first person on, not the downed orbit, no dialogue or cutscene
-- (BG3's own camera shows you then). Shared/NativeBridge.lua reads the flag
-- and Spikes/Spike11_HeadHiding.lua hides or shows the head.
local headHidden = false
local function syncHead(want, why)
    if want == headHidden then return end
    headHidden = want
    setHideHead(want)
    Log.Write("FullPov: your head " .. (want and "hidden (first person)" or ("shown (" .. why .. ")")))
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
    local paused = isPaused()
    local active = (e ~= nil) and (not paused)
    if e ~= nil or not S.on then
        syncHead(S.on and S.orbit == 0 and not paused,
            not S.on and "first person off" or (S.orbit ~= 0 and "downed camera") or "dialogue / cutscene")
    end
    local x, y, z = 0, 0, 0
    if e then
        local tx, ty, tz = readTranslate(e)
        if tx then x, y, z = tx, ty, tz end
    end
    -- A same-level teleport (waypoint, portal) changes no game state: a jump
    -- of more than TELEPORT_M between two writes counts as one.
    -- (lastPos first: Settle writes the state again, which used to see the same
    -- jump and recurse ~200 times on a Misty Step, playtest 2026-10-12.)
    if e and settle.lastPos and not settle.loading then
        local dx, dy, dz = x - settle.lastPos[1], y - settle.lastPos[2], z - settle.lastPos[3]
        settle.lastPos = { x, y, z }
        if dx * dx + dy * dy + dz * dz > TELEPORT_M * TELEPORT_M then M.Settle("teleport", SETTLE_TP_MS) end
    end
    if e then settle.lastPos = { x, y, z } end
    if settle.loading or now < settle.untilMs then active = false
    elseif settle.why then
        Log.Write("FullPov: first person back after " .. tostring(settle.why) .. " (level_seq " .. S.level_seq .. ")")
        settle.why = nil
    end
    if S.on and USE_BONE_ANCHOR then refreshCache(e, now) end

    local line = string.format(
        "orbit=%d orbit_seq=%d orbit_dist=%.2f orbit_up=%.2f orbit_pmin=%.1f orbit_pmax=%.1f orbit_spin=%d orbit_tilt=%d orbit_rate=%.1f orbit_tilt_rate=%.1f orbit_vis=%s orbit_x=%.3f orbit_y=%.3f orbit_z=%.3f crouch=%d level_seq=%d on=%d active=%d menu=%d foreign_follow=%d foreign_mouse_ms=%d foreign_ease_ms=%d anim_inst=%s anim_rate=%.3f clip_inst=%s clip_rates=%s nclips=%s nocombatcam=%d combat_wasd=%d rec_inst=%s lift_objects=%d jump_mode=%d genome_capture=%d strafe_sign=%d rj_land_speed=%.2f rj_wall_h=%.2f rj_sync_guard=%d jump_wait_ms=%d rj_land_hold=%d rj_slope_deg=%.1f mp_tag=%s mp_remote=%d head_smooth=%.2f move_walk=%.3f move_run=%.3f move_mode=%d move_accel=%.3f move_decel=%.3f move_turn=%.1f move_raw=%d move_hold=%d move_metrics=%d move_face_idle=%.1f move_face_air=%d loco_inst=%s loco_rate=%.2f loco_skip=%s visual=%s anchor=%d eye_up=%.3f eye_fwd=%.3f look=%.3f eye_height=%.3f pivot_up=%.3f down_fwd=%.3f jump_seq=%d jump_ms=%d jump_h=%.3f jump_k=%.2f dump=%d sock=%d skel=%d rootx=%.4f rooty=%.4f rootz=%.4f meshes=%s t=%d",
        S.orbit, S.orbit_seq, S.orbit_dist, S.orbit_up, S.orbit_pmin, S.orbit_pmax, S.orbit_spin, S.orbit_tilt, S.orbit_rate,
        S.orbit_tilt_rate, S.orbit_vis, S.orbit_x, S.orbit_y, S.orbit_z, S.crouch, S.level_seq,
        S.on and 1 or 0, active and 1 or 0, S.menu and 1 or 0,
        S.foreign_follow, math.floor(S.foreign_mouse_ms + 0.5), math.floor(S.foreign_ease_ms + 0.5), S.anim_inst, S.anim_rate, S.clip_inst, S.clip_rates, S.nclips, S.nocombatcam, S.combat_wasd, S.rec_inst, S.lift_objects, S.jump_mode, S.genome_capture, S.strafe_sign, S.rj_land_speed, S.rj_wall_h, S.rj_sync_guard, math.floor(S.jump_wait_ms + 0.5), S.rj_land_hold, S.rj_slope_deg, S.mp_tag, S.mp_remote, S.head_smooth, S.move_walk, S.move_run, S.move_mode, S.move_accel, S.move_decel, S.move_turn, S.move_raw, S.move_hold, S.move_metrics, S.move_face_idle, S.move_face_air, S.loco_inst, S.loco_rate, S.loco_skip, (S.on and cache.visual) or "0", S.anchor, S.eye_up, S.eye_fwd, S.look, S.eye_height, S.pivot_up, S.down_fwd,
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
function M.LinkState(state) linkedState = state end

local function setOn(on)
    S.on = on
    cache.at = -100000
    lastWrite = 0
    writeState()   -- the head follows (syncHead)
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

-- Hand the DLL the starting seq without a jump (jump_ms 0). The DLL treats
-- the first seq it reads as a sync, not a jump; with jump_seq left at 0
-- (= its own default) that sync never happened and the FIRST real jump of
-- a session was swallowed (playtest 2026-10-10: "first couple of jumps
-- glitch"). Called once at load by Jump.lua.
-- A BG3 panel (inventory, party view, map, ...) is open: the DLL turns
-- mouse-look off so the cursor works in it; the first-person camera stays.
function M.SetMenuOpen(on)
    on = on and true or false
    if S.menu == on then return end
    S.menu = on
    lastWrite = 0
    pcall(writeState)
end

function M.SyncJumpSeq(seq)
    S.jump_seq, S.jump_ms = seq, 0
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
function M.SetJumpSyncGuard(on)
    S.rj_sync_guard = on and 1 or 0
    lastWrite = 0
    pcall(writeState)
end
-- Bunny-hop grace in the DLL: a jump that reaches it while the character
-- is still falling waits this long for the landing (Pov.cpp UpdateJump).
function M.SetJumpWait(ms)
    S.jump_wait_ms = math.max(0, tonumber(ms) or 0)
    lastWrite = 0
    pcall(writeState)
end
-- Multiplayer: other players connected (Client/MP.lua roster).
function M.SetMpRemote(on)
    local v = on and 1 or 0
    if S.mp_remote == v then return end
    S.mp_remote = v
    lastWrite = 0
    pcall(writeState)
end
-- Multiplayer: tag the DLL's native.log lines with who this machine is.
function M.SetMpTag(t)
    S.mp_tag = (t and t ~= "") and t:gsub("%s", "-") or "-"
    lastWrite = 0
    pcall(writeState)
end
-- Uphill jumps: the steepest slope (degrees) the real jump's floor follows
-- (RealJump.cpp FollowSlope); 0 = off.
function M.SetJumpSlope(deg)
    S.rj_slope_deg = math.max(0, tonumber(deg) or 0)
    lastWrite = 0
    pcall(writeState)
end
function M.JumpSlope() return S.rj_slope_deg end
-- Keep (true) or skip (false) BG3's landing hold after a real jump.
function M.SetJumpLandHold(on)
    S.rj_land_hold = on and 1 or 0
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

-- Per-clip play rates on several characters: list of { inst = hex, id = mapping id,
-- rate }; at most 16 entries reach the DLL. nil / {} = none.
function M.SetNpcClipRates(list)
    local parts = {}
    for _, e in ipairs(list or {}) do
        if e.inst and e.id and tonumber(e.rate) and #parts < 16 then
            parts[#parts + 1] = string.format("%s:%s:%.3f", e.inst, e.id, e.rate)
        end
    end
    table.sort(parts)
    local spec = #parts > 0 and table.concat(parts, "|") or "-"
    if spec == S.nclips then return end
    S.nclips = spec
    lastWrite = 0
    pcall(writeState)
end

function M.SetNoCombatCam(on)
    S.nocombatcam = on and 1 or 0
    lastWrite = 0
    pcall(writeState)
end
function M.NoCombatCam() return S.nocombatcam == 1 end

function M.SetCombatWasd(on)
    S.combat_wasd = on and 1 or 0
    lastWrite = 0
    pcall(writeState)
end
function M.CombatWasd() return S.combat_wasd == 1 end

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

-- Direct WASD controller settings for the DLL (Client/Movement/Movement.lua):
-- { mode = 0|1, accel = s, decel = s, turn = -1|0|deg/s, raw = 0|1,
--   hold = 0|1, metrics = 0|1, face_idle = deg, face_air = 0|1 }; only the
--   keys given change.
function M.SetMoveFeel(t)
    local changed = false
    for k, v in pairs(t or {}) do
        local key = "move_" .. k
        if S[key] ~= nil and S[key] ~= v then S[key] = v; changed = true end
    end
    if changed then
        lastWrite = 0
        pcall(writeState)
    end
end

-- Locomotion transition clips to fast-forward in direct mode
-- (Client/Movement/LocoSkip.lua): hex instance, list of mapping ids, rate.
function M.SetLocoSkip(inst, ids, rate)
    local spec = (ids and #ids > 0) and table.concat(ids, ",") or "-"
    inst, rate = inst or "0", rate or 1.0
    if spec == S.loco_skip and inst == S.loco_inst and rate == S.loco_rate then return end
    S.loco_inst, S.loco_skip, S.loco_rate = inst, spec, rate
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

-- Go inactive now, bump level_seq, come back after ms (level load /
-- fast travel / teleport; the server also sends PovSettle on Teleported).
function M.Settle(why, ms)
    settle.untilMs = Ext.Utils.MonotonicTime() + (ms or SETTLE_TP_MS)
    settle.why = why
    S.level_seq = S.level_seq + 1
    cache.at = -100000
    Log.Write(string.format("FullPov: %s -> first person paused %d ms, level_seq %d", tostring(why), ms or SETTLE_TP_MS, S.level_seq))
    lastWrite = 0
    pcall(writeState)
end

-- Crouch flag for the DLL (eye calibration paused while crouched).
function M.SetCrouch(on)
    local v = on and 1 or 0
    if S.crouch == v then return end
    S.crouch = v
    lastWrite = 0
    pcall(writeState)
end

-- Downed orbit camera. on: third person around the watched character
-- (visHex = its root Visual address, pos = its feet); the head shows again.
function M.SetOrbit(on, opts)
    opts = opts or {}
    local v = on and 1 or 0
    if v ~= S.orbit then
        S.orbit = v
        S.orbit_seq = S.orbit_seq + 1
        Log.Write("FullPov: orbit camera " .. (on and "ON" or "OFF") .. " (your head " .. (on and "shows" or "hides again") .. ")")
    end
    for _, k in ipairs({ "dist", "up", "pmin", "pmax", "rate", "tilt_rate" }) do
        if opts[k] then S["orbit_" .. k] = opts[k] end
    end
    lastWrite = 0
    pcall(writeState)
end
function M.SetOrbitTarget(visHex, pos, newTarget)
    S.orbit_vis = visHex or "0"
    if pos then S.orbit_x, S.orbit_y, S.orbit_z = pos[1], pos[2], pos[3] end
    if newTarget then S.orbit_seq = S.orbit_seq + 1; lastWrite = 0; pcall(writeState) end
end
function M.SetOrbitInput(spin, tilt)
    spin, tilt = spin or 0, tilt or 0
    if spin == S.orbit_spin and tilt == S.orbit_tilt then return end
    S.orbit_spin, S.orbit_tilt = spin, tilt
    lastWrite = 0
    pcall(writeState)
end
function M.Orbiting() return S.orbit == 1 end

-- Animation browser: third person while its window is open.
function M.SetOn(on) setOn(on and true or false) end
function M.IsOn() return S.on end

function M.Register()
    -- POV starts off every session; make sure a hide_head left on by a
    -- previous session doesn't fire before the character exists.
    setHideHead(false)
    headHidden = false
    Ext.Events.Tick:Subscribe(function() pcall(writeState) end)
    -- Level loads (region change, fast travel to another region, save load).
    pcall(function()
        Ext.Events.GameStateChanged:Subscribe(function(e)
            local to = tostring(e.ToState)
            if to == "UnloadLevel" or to == "LoadLevel" or to == "SwapLevel" or to == "LoadSession" then
                if not settle.loading then Log.Write("FullPov: game state " .. to .. " -> first person paused until Running") end
                settle.loading = true
                settle.lastPos = nil
                cache.meshes, cache.visual, cache.ent, cache.at = {}, nil, nil, -100000
                lastWrite = 0
                pcall(writeState)
            elseif to == "Running" and settle.loading then
                settle.loading = false
                M.Settle("level load", SETTLE_LOAD_MS)
            end
        end)
    end)

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

    -- While BG3 renders through a camera that is not on you (Pov.cpp
    -- "foreign" camera): follow = the view keeps following your mouse,
    -- hold = the last direction (the old behaviour). Session only; the
    -- defaults live in data/camera.lua foreign_camera.
    Ext.RegisterConsoleCommand("dag_pov_foreign", function(_, mode, mouseMs, easeMs)
        if mode == "follow" or mode == "on" or mode == "1" then S.foreign_follow = 1
        elseif mode == "hold" or mode == "off" or mode == "0" then S.foreign_follow = 0 end
        if tonumber(mouseMs) then S.foreign_mouse_ms = math.max(0, tonumber(mouseMs)) end
        if tonumber(easeMs) then S.foreign_ease_ms = math.max(0, tonumber(easeMs)) end
        lastWrite = 0
        pcall(writeState)
        Log.Write(string.format("FullPov: foreign camera -> %s (mouse window %d ms, ease back %d ms; DLL foreignCam=%s)",
            S.foreign_follow == 1 and "the view follows your mouse" or "the view holds your last direction",
            math.floor(S.foreign_mouse_ms + 0.5), math.floor(S.foreign_ease_ms + 0.5),
            tostring(M.StatusValue("foreignCam"))))
    end)

    Log.Write("FullPov: registered !dag_full_pov / !dag_pov_eye / !dag_pov_anchor / !dag_pov_smooth / !dag_pov_down / !dag_pov_dump / !dag_pov_status / !dag_pov_foreign")
end

return M
