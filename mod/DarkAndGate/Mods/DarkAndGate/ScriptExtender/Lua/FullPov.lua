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
}

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
local function controlledEntity()
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    if ok and ents and #ents > 0 then return ents[1] end
    return nil
end

local function isPaused()
    local ok, dlgs = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Dialog")
    if ok and dlgs and #dlgs > 0 then return true end
    for _, c in ipairs({ "Cinematic", "Cutscene", "ClientMoveToCutscene" }) do
        local ok2, es = pcall(Ext.Entity.GetAllEntitiesWithComponent, c)
        if ok2 and es and #es > 0 then return true end
    end
    return false
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
local cache = { meshes = {}, sock = -1, skel = 0, at = -100000, ent = nil }
local lastWrite = 0

local function refreshCache(e, now)
    if e == nil then cache.meshes = {}; return end
    if cache.ent ~= e or now - cache.at > 1000 then
        cache.ent = e
        cache.at = now
        cache.meshes = collectMeshes(e, nil)
        cache.sock, cache.skel = headSocket(e, nil)
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
    if S.on then refreshCache(e, now) end

    local line = string.format(
        "on=%d active=%d eye_up=%.3f eye_fwd=%.3f look=%.3f eye_height=%.3f pivot_up=%.3f down_fwd=%.3f dump=%d sock=%d skel=%d rootx=%.4f rooty=%.4f rootz=%.4f meshes=%s t=%d",
        S.on and 1 or 0, active and 1 or 0, S.eye_up, S.eye_fwd, S.look, S.eye_height, S.pivot_up, S.down_fwd,
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
    end)

    Log.Write("FullPov: registered !dag_full_pov / !dag_pov_eye / !dag_pov_down / !dag_pov_dump / !dag_pov_status")
end

return M
