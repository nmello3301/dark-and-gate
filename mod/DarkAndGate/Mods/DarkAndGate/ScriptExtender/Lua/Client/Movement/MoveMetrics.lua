-- SPDX-License-Identifier: GPL-3.0-or-later
-- !dag_move_metrics on|off: movement-feel metrics (docs/spikes/move-feel.md).
--
-- The DLL (MoveFeel.cpp) times starts, stops, reversals and strafe changes
-- from the physical W/A/S/D and logs every position jump the speed can't
-- explain (a server correction): MOVEFEEL lines in native.log, with a
-- summary every 60 s and on off. This module adds the client / server drift:
-- the server sends its own position of your character every 50 ms
-- (Server/MoveProbe.lua); each one is compared with where this client has
-- you now ("raw") and with the closest point of your last 0.5 s of positions
-- ("matched": what is left once the server's delay is allowed for, with that
-- delay). Split into moving and standing (still for 300 ms); a summary every
-- 10 s while on, and the whole run on off.

local Log     = Ext.Require("Shared/Log.lua")
local Net     = Ext.Require("Shared/Net.lua")
local FullPov = Ext.Require("FullPov.lua")
local Me = Ext.Require("Client/Me.lua")   -- the local player's character (multiplayer)

local M = {}

local HISTORY_MS, SUMMARY_MS, MOVING_MPS, STANDING_WARN_M = 500, 10000, 0.5, 0.1

local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function player()
    local ok, ents = pcall(Me.All)
    return ok and ents and ents[1] or nil
end

local function pos(ent)
    if not ent then return nil end
    local ok, t = pcall(function() return ent.Transform.Transform.Translate end)
    if ok and t then return t[1], t[2], t[3] end
    return nil
end

local function newAcc() return { n = 0, rawMax = 0, rawSum = 0, mMax = 0, mSum = 0, lagSum = 0 } end
local S = { on = false, hist = {}, lastSum = 0, warnAt = 0 }
local acc = { moving = newAcc(), standing = newAcc() }
local total = { moving = newAcc(), standing = newAcc() }

local function mode() return tostring(FullPov.StatusValue("mf") or "?") end

local function speedNow()
    local h = S.hist
    local a = h[#h]
    if not a then return nil end
    for i = #h - 1, 1, -1 do
        local b = h[i]
        if a.t - b.t >= 100 then
            local dx, dz = a.x - b.x, a.z - b.z
            return math.sqrt(dx * dx + dz * dz) / ((a.t - b.t) / 1000)
        end
    end
    return nil
end

-- "moving" (over 0.5 m/s), "standing" (still for 300 ms: the server has had
-- time to arrive), or nil while starting / stopping.
local function phase(t)
    local v = speedNow()
    if v == nil then return nil end
    if v > MOVING_MPS then S.stillSince = nil; return "moving" end
    if v < 0.05 then
        S.stillSince = S.stillSince or t
        if t - S.stillSince >= 300 then return "standing" end
    else
        S.stillSince = nil
    end
    return nil
end

local function add(a, raw, m, lag)
    a.n = a.n + 1
    a.rawSum, a.mSum, a.lagSum = a.rawSum + raw, a.mSum + m, a.lagSum + lag
    if raw > a.rawMax then a.rawMax = raw end
    if m > a.mMax then a.mMax = m end
end

local function line(tag, a)
    if a.n == 0 then return tag .. ": no samples" end
    return string.format("%s n=%d: raw max %.3f m avg %.3f | matched max %.3f m avg %.3f (server ~%d ms behind)",
        tag, a.n, a.rawMax, a.rawSum / a.n, a.mMax, a.mSum / a.n, math.floor(a.lagSum / a.n + 0.5))
end

local function summary(why, a)
    Log.Write(string.format("MoveMetrics: drift [%s] (%s) %s || %s", mode(), why, line("moving", a.moving), line("standing", a.standing)))
end

local function onProbe(payload)
    if not S.on then return end
    local ok, p = pcall(Ext.Json.Parse, payload)
    if not ok or type(p) ~= "table" or not p.x then return end
    local x, _, z = pos(player())
    if not x then return end
    local t = nowMs()
    local dx, dz = p.x - x, p.z - z
    local raw = math.sqrt(dx * dx + dz * dz)
    local best, bestLag = raw, 0
    for i = #S.hist, 1, -1 do
        local h = S.hist[i]
        if t - h.t > HISTORY_MS then break end
        local hx, hz = p.x - h.x, p.z - h.z
        local d = math.sqrt(hx * hx + hz * hz)
        if d < best then best, bestLag = d, t - h.t end
    end
    local key = phase(t)
    if not key then return end
    add(acc[key], raw, best, bestLag)
    add(total[key], raw, best, bestLag)
    if key == "standing" and raw > STANDING_WARN_M and t - S.warnAt > 1000 then
        S.warnAt = t
        Log.Write(string.format("MoveMetrics: standing still, but the server has you %.2f m away", raw))
    end
end

local function tick()
    if not S.on then return end
    local x, y, z = pos(player())
    local t = nowMs()
    if x then
        S.hist[#S.hist + 1] = { t = t, x = x, y = y, z = z }
        while #S.hist > 0 and t - S.hist[1].t > 1000 do table.remove(S.hist, 1) end
    end
    if t - S.lastSum >= SUMMARY_MS then
        S.lastSum = t
        summary("last 10 s", acc)
        acc = { moving = newAcc(), standing = newAcc() }
    end
end

local function setOn(on)
    if on == S.on then
        Log.Write("MoveMetrics: already " .. (on and "ON" or "OFF"))
        return
    end
    S.on = on
    FullPov.SetMoveFeel({ metrics = on and 1 or 0 })
    pcall(Ext.Net.PostMessageToServer, Net.Channels.MoveProbeReq, Ext.Json.Stringify({ on = on }))
    if on then
        S.hist, S.lastSum, S.stillSince = {}, nowMs(), nil
        acc = { moving = newAcc(), standing = newAcc() }
        total = { moving = newAcc(), standing = newAcc() }
        Log.Write("MoveMetrics: ON [" .. mode() .. "]: start / stop / reverse / strafe timings and corrections as "
            .. "MOVEFEEL lines in native.log; client/server drift here every 10 s. !dag_move_metrics off for the summary.")
    else
        summary("whole run", total)
        Log.Write("MoveMetrics: OFF (the DLL's MOVEFEEL summary is in native.log)")
    end
end

function M.On() return S.on end

function M.Register()
    Ext.RegisterNetListener(Net.Channels.MoveProbe, function(_, payload) pcall(onProbe, payload) end)
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
    Ext.RegisterConsoleCommand("dag_move_metrics", function(_, a)
        setOn(not (a == "off" or a == "0"))
    end)
end

return M
