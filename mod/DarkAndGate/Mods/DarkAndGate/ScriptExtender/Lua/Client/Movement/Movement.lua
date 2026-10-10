-- SPDX-License-Identifier: GPL-3.0-or-later
-- WASD ground speed: walk / run / overall multipliers, modifiers, and the
-- locomotion animation rate that keeps the feet from sliding.
--
-- Walk vs run is BG3WASD's (walk by default, Left Shift toggles; its
-- WalkSpeed scales the input). The speed itself goes through the DLL's
-- lever on the client MoveController (MoveSpeed.cpp, docs/spikes/move-speed.md):
-- Lua sends the effective multipliers as move_walk / move_run in
-- native-pov.txt; the DLL turns them into the template Stroll / Run values
-- the WASD update reads. Client-side, like BG3WASD's walk: it changes only
-- the character this client drives.
--
--   effective walk = walk_speed x speed_mult x (product of modifiers)
--   effective run  = run_speed  x speed_mult x (product of modifiers)
--
-- Modifiers (future traits, spells, encumbrance), same idea as the jump's
-- live tuning:
--   Movement.AddModifier(id, fn)   fn(ent) -> number (both) or { walk =, run = }
--   Movement.RemoveModifier(id)
--
-- Locomotion sync: the walk / run clips are authored for the natural
-- speeds, so at x1.5 the feet would slide. While moving (and not jumping or
-- in an action), the character's play rate is set to the multiplier of the
-- current gait through Actions (owner "loco"). Gait = whichever expected
-- speed (walk or run, from the DLL's template read) the measured speed is
-- closer to.
--
-- Commands: !dag_speed_mult <x>, !dag_walk_speed <x>, !dag_run_speed <x>,
--           !dag_move_status, !dag_loco_sync on|off

local Log      = Ext.Require("Shared/Log.lua")
local MCM      = Ext.Require("Shared/MCM.lua")
local FullPov  = Ext.Require("FullPov.lua")
local State    = Ext.Require("Client/Combat/State.lua")
local Actions  = Ext.Require("Client/Combat/Actions.lua")
local movement = Ext.Require("data/movement.lua")

local M = {}

local D = movement.move

local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function player()
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    return ok and ents and ents[1] or nil
end

-- ---------------------------------------------------------------------
-- Modifiers
-- ---------------------------------------------------------------------
local modifiers = {}      -- id -> fn
local modErrLogged = {}

function M.AddModifier(id, fn)
    modifiers[id] = fn
    Log.Write("Move: modifier added " .. tostring(id))
end

function M.RemoveModifier(id)
    if modifiers[id] then
        modifiers[id] = nil
        Log.Write("Move: modifier removed " .. tostring(id))
    end
end

local function effective(ent)
    local all = MCM.Get("move_speed_mult") or 1.0
    local w = (MCM.Get("move_walk_speed") or 1.0) * all
    local r = (MCM.Get("move_run_speed") or 1.0) * all
    local names = {}
    for id, fn in pairs(modifiers) do
        local ok, v = pcall(fn, ent)
        if not ok then
            if not modErrLogged[id] then
                modErrLogged[id] = true
                Log.Write("Move: modifier " .. tostring(id) .. " ERROR " .. tostring(v))
            end
        elseif type(v) == "number" then
            w, r = w * v, r * v
            names[#names + 1] = string.format("%s x%.2f", id, v)
        elseif type(v) == "table" then
            w, r = w * (tonumber(v.walk) or 1), r * (tonumber(v.run) or 1)
            names[#names + 1] = string.format("%s walk x%.2f run x%.2f", id, tonumber(v.walk) or 1, tonumber(v.run) or 1)
        end
    end
    w = math.max(D.min_mult, math.min(D.max_mult, w))
    r = math.max(D.min_mult, math.min(D.max_mult, r))
    return w, r, names
end

-- ---------------------------------------------------------------------
-- Speed sampling + gait
-- ---------------------------------------------------------------------
local speed = { at = 0, x = nil, z = nil, v = 0 }
local function sampleSpeed(now, ent)
    if now - speed.at < 100 then return end
    local ok, t = pcall(function() return ent.Transform.Transform.Translate end)
    if ok and t then
        if speed.x then
            local dt = (now - speed.at) / 1000
            local dx, dz = t[1] - speed.x, t[3] - speed.z
            local v = dt > 0 and math.sqrt(dx * dx + dz * dz) / dt or 0
            -- Light filter: 100 ms samples of a 30-60 fps transform are noisy.
            speed.v = speed.v * 0.5 + v * 0.5
        end
        speed.x, speed.z = t[1], t[3]
    end
    speed.at = now
end
function M.Speed() return speed.v end

-- Natural speeds from the DLL's template read (status line, every 500 ms).
local nat = { at = -1e9, stroll = nil, run = nil, t = nil }
local function readNatural(now)
    if now - nat.at < 500 then return end
    nat.at = now
    nat.stroll = tonumber(FullPov.StatusValue("tmplStroll"))
    nat.run    = tonumber(FullPov.StatusValue("tmplRun"))
    nat.t      = tonumber(FullPov.StatusValue("walkT"))
end

local S = {
    walk = 1.0, run = 1.0, sentAt = -1e9,
    gait = "idle", locoRate = 1.0, locoSync = D.loco_sync ~= false,
    lastLogged = nil,
}

local function gaitOf(v, w, r)
    if v < D.idle_speed then return "idle" end
    if not (nat.stroll and nat.run and nat.t) or nat.run <= 0 then return "unknown" end
    local walkNat = nat.stroll + nat.t * (nat.run - nat.stroll)
    local expW, expR = walkNat * w, nat.run * r
    -- Compare in log space (ratios), so x2 walk vs x1 run is fair.
    local dw = math.abs(math.log(math.max(v, 0.05) / math.max(expW, 0.05)))
    local dr = math.abs(math.log(math.max(v, 0.05) / math.max(expR, 0.05)))
    return dw <= dr and "walk" or "run", expW, expR
end

local function tick()
    local now = nowMs()
    local ent = player()
    if not ent then return end
    sampleSpeed(now, ent)
    readNatural(now)

    -- Multipliers -> DLL (every 150 ms, written only when they change).
    if now - S.sentAt >= 150 then
        S.sentAt = now
        local w, r, names = effective(ent)
        if math.abs(w - S.walk) > 1e-3 or math.abs(r - S.run) > 1e-3 then
            S.walk, S.run = w, r
            Log.Write(string.format("Move: speed walk x%.2f run x%.2f (walk_speed %.2f run_speed %.2f speed_mult %.2f%s)",
                w, r, MCM.Get("move_walk_speed") or 1, MCM.Get("move_run_speed") or 1, MCM.Get("move_speed_mult") or 1,
                #names > 0 and (", modifiers: " .. table.concat(names, ", ")) or ""))
        end
        FullPov.SetMove(S.walk, S.run)
    end

    -- Locomotion play rate follows the gait's multiplier.
    local gait, expW, expR = gaitOf(speed.v, S.walk, S.run)
    local rate = 1.0
    if S.locoSync and not State.jumping then
        if gait == "walk" then rate = S.walk elseif gait == "run" then rate = S.run end
    end
    if math.abs(rate - 1.0) < D.loco_deadband then rate = 1.0 end
    if gait ~= S.gait or math.abs(rate - S.locoRate) > 1e-3 then
        S.gait, S.locoRate = gait, rate
        Actions.SetBaseRate("loco", rate)
        Log.Write(string.format("Move: gait=%s speed=%.2fm/s expect walk=%s run=%s loco rate x%.2f%s",
            gait, speed.v, expW and string.format("%.2f", expW) or "?", expR and string.format("%.2f", expR) or "?",
            rate, State.jumping and " (jumping: jump owns the rate)" or ""))
    end
end

local function status()
    local w, r, names = effective(player())
    nat.at = -1e9
    readNatural(nowMs())
    Log.Write(string.format(
        "Move: walk_speed=%.2f run_speed=%.2f speed_mult=%.2f -> walk x%.2f run x%.2f | modifiers: %s | speed=%.2fm/s gait=%s loco rate x%.2f (sync %s) | DLL move=%s tmplStroll=%s tmplRun=%s walkT=%s outStroll=%s outRun=%s calls=%s rateHits=%s",
        MCM.Get("move_walk_speed") or 1, MCM.Get("move_run_speed") or 1, MCM.Get("move_speed_mult") or 1, w, r,
        #names > 0 and table.concat(names, ", ") or "none", speed.v, S.gait, S.locoRate, S.locoSync and "on" or "off",
        tostring(FullPov.StatusValue("move")), tostring(FullPov.StatusValue("tmplStroll")), tostring(FullPov.StatusValue("tmplRun")),
        tostring(FullPov.StatusValue("walkT")), tostring(FullPov.StatusValue("outStroll")), tostring(FullPov.StatusValue("outRun")),
        tostring(FullPov.StatusValue("moveCalls")), tostring(FullPov.StatusValue("rateHits"))))
end

function M.Register()
    MCM.DefineNumber("move_walk_speed", D.walk_speed, "Walk speed multiplier", D.min_mult, D.max_mult)
    MCM.DefineNumber("move_run_speed", D.run_speed, "Run speed multiplier", D.min_mult, D.max_mult)
    MCM.DefineNumber("move_speed_mult", D.speed_mult, "Overall movement speed multiplier", D.min_mult, D.max_mult)

    Ext.Events.Tick:Subscribe(function() pcall(tick) end)

    local function numCmd(cmd, key)
        Ext.RegisterConsoleCommand(cmd, function(_, x)
            if tonumber(x) then MCM.Set(key, tonumber(x)) end
            S.sentAt = -1e9
            status()
        end)
    end
    numCmd("dag_speed_mult", "move_speed_mult")
    numCmd("dag_walk_speed", "move_walk_speed")
    numCmd("dag_run_speed", "move_run_speed")
    Ext.RegisterConsoleCommand("dag_move_status", function() status() end)
    Ext.RegisterConsoleCommand("dag_loco_sync", function(_, a)
        if a == "off" or a == "0" then S.locoSync = false elseif a == "on" or a == "1" then S.locoSync = true end
        Log.Write("Move: locomotion rate sync " .. (S.locoSync and "ON" or "OFF"))
    end)
    Log.Write("Move: registered (!dag_speed_mult / !dag_walk_speed / !dag_run_speed / !dag_move_status / !dag_loco_sync)")
end

return M
