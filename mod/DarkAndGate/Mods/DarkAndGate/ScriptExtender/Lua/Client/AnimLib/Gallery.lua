-- SPDX-License-Identifier: GPL-3.0-or-later
-- Animation gallery, client side: n preview copies (spawned by
-- Server/AnimLib.lua), each looping one clip of the browser's current
-- page, with a floating "#n clip (1.2s)" label over its head.
--
--   * copies arrive one per tick (DAG_AnimLibSpawned) and are reused
--     across pages -- only their clip changes;
--   * at most ONE clip start per tick (staggered); a looping slot replays
--     after the clip's Duration + 0.3 s;
--   * labels: the copy's head (feet + 1.9 m) projected with the active
--     camera's ProjectionMatrix * ViewMatrix, drawn as small no-input,
--     no-background ImGui windows created once per slot.

local Log       = Ext.Require("Shared/Log.lua")
local Net       = Ext.Require("Shared/Net.lua")
local ClientNet = Ext.Require("Client/Net.lua")
local Aim       = Ext.Require("Client/Combat/Aim.lua")

local M = {}

local LOOP_GAP_S = 0.3
local LABEL_HZ_MS = 50
local HEAD_M = 1.9

local slots = {}          -- i -> { uuid, ent, clip, nextAt, err, label, shown, text }
local active = false
local loop = true
local paused = false
local requested = 0
local spawnT0 = 0
local lastLabelAt = 0
local labelWindows = {}
local playsThisPage = 0

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local function trySet(o, k, v) pcall(function() o[k] = v end) end

local FLAGS = { "NoTitleBar", "NoResize", "NoMove", "NoInputs", "NoScrollbar",
                "NoSavedSettings", "AlwaysAutoResize", "NoFocusOnAppearing", "NoNav", "NoBackground" }

local function labelWindow(i)
    local w = labelWindows[i]
    if w then return w end
    local ok = pcall(function()
        w = Ext.IMGUI.NewWindow("##DAG_AnimLabel_" .. i)
        trySet(w, "Closeable", false)
        pcall(function() w.Flags = FLAGS end)
        pcall(function() w:SetColor("WindowBg", { 0, 0, 0, 0 }) end)
        pcall(function() w:SetColor("Border", { 0, 0, 0, 0 }) end)
        w.text = w:AddText("")
        pcall(function() w.text:SetColor("Text", { 1, 1, 0.6, 1 }) end)
        trySet(w, "Open", false)
    end)
    if not ok then return nil end
    labelWindows[i] = w
    return w
end

local function showLabel(i, on)
    local s = slots[i]
    local w = labelWindow(i)
    if not w then return end
    if s and s.shown == on then return end
    if s then s.shown = on end
    trySet(w, "Open", on)
    trySet(w, "Visible", on)
end

local function hideAllLabels()
    for i, w in pairs(labelWindows) do
        trySet(w, "Open", false)
        trySet(w, "Visible", false)
        if slots[i] then slots[i].shown = false end
    end
end

-- mat4 (flat 16, column-major) * vec4
local function mul(m, x, y, z, w)
    return m[1] * x + m[5] * y + m[9] * z + m[13] * w,
           m[2] * x + m[6] * y + m[10] * z + m[14] * w,
           m[3] * x + m[7] * y + m[11] * z + m[15] * w,
           m[4] * x + m[8] * y + m[12] * z + m[16] * w
end

local function viewport()
    local ok, v = pcall(Ext.IMGUI.GetViewportSize)
    if ok and v then
        local w, h = tonumber(v[1] or v.x), tonumber(v[2] or v.y)
        if w and h and w > 0 then return w, h end
    end
    return 1920, 1080
end

local function project(p)
    local ctrl = Aim.ActiveCameraController and Aim.ActiveCameraController()
    if not ctrl then return nil end
    local ok, V, P = pcall(function() return ctrl.Camera.ViewMatrix, ctrl.Camera.ProjectionMatrix end)
    if not ok or not V or not P then return nil end
    local vx, vy, vz, vw = mul(V, p[1], p[2], p[3], 1)
    local cx, cy, _, cw = mul(P, vx, vy, vz, vw)
    if cw <= 0.01 then return nil end
    local sw, sh = viewport()
    local nx, ny = cx / cw, cy / cw
    if nx < -1.2 or nx > 1.2 or ny < -1.2 or ny > 1.2 then return nil end
    return (nx * 0.5 + 0.5) * sw, (1 - (ny * 0.5 + 0.5)) * sh
end

local function feetOf(s)
    if not s.ent then
        local ok, e = pcall(Ext.Entity.Get, s.uuid)
        if ok and e then s.ent = e end
    end
    if not s.ent then return nil end
    local ok, t = pcall(function() return s.ent.Transform.Transform.Translate end)
    if ok and t then return { t[1], t[2], t[3] } end
    return nil
end

local function labelText(i, s)
    if s.err then return string.format("#%d %s", i, s.err) end
    if not s.uuid then return string.format("#%d spawning...", i) end
    if not s.clip then return string.format("#%d no clip", i) end
    return string.format("#%d %s (%.1fs)", i, s.clip.base, s.clip.dur or 0)
end

local function updateLabels()
    local t = now()
    if t - lastLabelAt < LABEL_HZ_MS then return end
    lastLabelAt = t
    for i, s in pairs(slots) do
        local feet = s.uuid and feetOf(s)
        local x, y
        if feet then x, y = project({ feet[1], feet[2] + HEAD_M, feet[3] }) end
        if x then
            local w = labelWindow(i)
            if w then
                local txt = labelText(i, s)
                if txt ~= s.text then s.text = txt; trySet(w.text, "Label", txt) end
                pcall(function() w:SetPos({ x - 60, y - 20 }) end)
                showLabel(i, true)
            end
        else
            showLabel(i, false)
        end
    end
end

local function startOne()
    if paused then return end
    local t = now()
    for i, s in pairs(slots) do
        if s.uuid and s.clip and s.nextAt and t >= s.nextAt then
            ClientNet.PlayAnimOn(s.uuid, s.clip.playId or s.clip.keys[1], s.clip.dur, true, true)
            playsThisPage = playsThisPage + 1
            if playsThisPage <= 2 or playsThisPage == requested then
                Log.Write(string.format("AnimLib: gallery #%d plays %s (%s)%s", i, s.clip.base, s.clip.keys[1],
                    playsThisPage == requested and " -- every copy started" or ""))
            end
            s.nextAt = loop and (t + ((s.clip.dur or 1) + LOOP_GAP_S) * 1000) or nil
            return  -- one clip start per tick
        end
    end
end

-- ---------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------
function M.Active() return active end

-- Client entities of the spawned copies (for the play-rate slider).
function M.Entities()
    local out = {}
    for _, s in pairs(slots) do
        if s.uuid then
            if not s.ent then local ok, e = pcall(Ext.Entity.Get, s.uuid); if ok then s.ent = e end end
            if s.ent then out[#out + 1] = s.ent end
        end
    end
    return out
end
function M.Size() return requested end
function M.SetLoop(on) loop = on and true or false
    if loop then for _, s in pairs(slots) do if s.clip and not s.nextAt then s.nextAt = now() end end end
end
function M.Loop() return loop end
function M.SetPaused(on) paused = on and true or false end

-- clips: the browser's current page (array, up to n).
function M.SetPage(clips)
    local t = now()
    local n = 0
    for i = 1, requested do if clips[i] then n = n + 1 end end
    playsThisPage = 0
    if requested > 0 then
        Log.Write(string.format("AnimLib: gallery page -> %d clips on %d copies%s", n, requested,
            n == 0 and " (EMPTY page: the filters match nothing)" or ("; #1 " .. clips[1].base)))
    end
    for i = 1, requested do
        local s = slots[i]
        if s then
            s.clip = clips[i]
            s.nextAt = s.clip and t or nil
            s.text = nil
        end
    end
end

function M.Open(n, rig, target, template, clips)
    n = math.max(1, math.min(25, tonumber(n) or 12))
    requested = n
    active = true
    paused = false
    spawnT0 = now()
    for i = 1, n do slots[i] = slots[i] or {} end
    for i = n + 1, 25 do if slots[i] then showLabel(i, false); slots[i] = nil end end
    local fwd = { 0, 0, 1 }
    local okE, eye, f = pcall(Aim.ReadInvView)
    if okE and f then fwd = f end
    ClientNet.Send(Net.Channels.AnimLibSpawn, { n = n, rig = rig, target = target, template = template, fwd = fwd })
    Log.Write(string.format("AnimLib: gallery requested n=%d rig=%s%s", n, tostring(rig),
        template and (" template=" .. template) or ""))
    M.SetPage(clips or {})
end

-- Restart slot i's clip now (clicking its row in the browser).
function M.Restart(i)
    local s = slots[i]
    if s and s.clip then s.nextAt = 0 end
end

function M.Clear(why)
    if not active and next(slots) == nil then return end
    active = false
    requested = 0
    hideAllLabels()
    slots = {}
    ClientNet.Send(Net.Channels.AnimLibClear, { why = why or "browser" })
    Log.Write("AnimLib: gallery cleared (" .. tostring(why or "browser") .. ")")
end

function M.Tick()
    if not active then return end
    pcall(startOne)
    pcall(updateLabels)
end

function M.Register()
    Ext.RegisterNetListener(Net.Channels.AnimLibSpawned, function(_, payload)
        local ok, msg = pcall(Ext.Json.Parse, payload)
        if not ok or not msg then return end
        local i = tonumber(msg.slot) or 0
        if i == 0 then
            Log.Write("AnimLib: gallery failed: " .. tostring(msg.error))
            return
        end
        local s = slots[i]
        if not s then return end
        if msg.error then
            s.err = "no copy (" .. tostring(msg.error) .. ")"
        else
            s.uuid, s.ent, s.err = msg.uuid, nil, nil
            if s.clip then s.nextAt = now() end
        end
        local have = 0
        for _, x in pairs(slots) do if x.uuid or x.err then have = have + 1 end end
        if have == requested then
            Log.Write(string.format("AnimLib: gallery ready, %d slots in %d ms", have, now() - spawnT0))
        end
    end)
end

return M
