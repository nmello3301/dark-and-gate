-- SPDX-License-Identifier: GPL-3.0-or-later
-- Player actions (swing, spell cast, spell prepare loop) and who owns the
-- character's animation play rate.
--
-- An action plays its own clip at its own rate and has priority over the
-- jump clips (docs/playtest/movement-round.md step 4): while one is
-- running, Jump.lua suspends its phase clips and resumes the phase that
-- matches the arc when the last action ends. The vertical lift is the DLL's
-- and never pauses.
--
-- Play rate: one per-character rate through the native PlayAnimation hook
-- (AnimSpeed.SetCharacter). The "base" rate has owners in priority order:
-- the jump (while airborne) over the locomotion sync (Movement.lua); a
-- running action overrides the base with its own rate (1.0 unless given)
-- and the base comes back when it ends.
--
--   Actions.Begin(label, durS, rate)   timed action (swing, cast)
--   Actions.Hold(label, rate)          open-ended (spell prepare loop)
--   Actions.Release(label)             ends a Hold (or a timed one early)
--   Actions.Busy()                     true while any action runs
--   Actions.OnChange(fn)               fn(busy, label) on busy <-> idle
--   Actions.SetBaseRate(owner, rate)   base rate for "jump" / "loco" (1.0 = off)

local Log       = Ext.Require("Shared/Log.lua")
local AnimSpeed = Ext.Require("Client/AnimLib/AnimSpeed.lua")
local Me = Ext.Require("Client/Me.lua")   -- the local player's character (multiplayer)

local M = {}

local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local running = {}        -- label -> { untilAt = ms | nil (held), rate }
local listeners = {}
local BASE_ORDER = { "jump", "loco" }
local baseRates = {}      -- owner -> rate (absent = 1.0)
local function baseRate()
    for _, o in ipairs(BASE_ORDER) do
        local r = baseRates[o]
        if r and math.abs(r - 1.0) > 1e-3 then return r, o end
    end
    for o, r in pairs(baseRates) do
        if math.abs(r - 1.0) > 1e-3 then return r, o end
    end
    return 1.0, nil
end
local applied = 1.0
local wasBusy = false

local function player()
    local ok, ents = pcall(Me.All)
    return ok and ents and ents[1] or nil
end

local function topRate()
    -- The most recently started action wins.
    local best, bestAt = nil, -1
    for _, a in pairs(running) do
        if a.startedAt > bestAt then best, bestAt = a, a.startedAt end
    end
    return best and (best.rate or 1.0) or nil
end

local function applyRate(why)
    local r = topRate() or baseRate()
    if math.abs(r - applied) < 1e-3 then return end
    local me = player()
    if not me then return end
    local ok, how = AnimSpeed.SetCharacter(me, r)
    Log.Write(string.format("Actions: play rate x%.2f (%s) %s", r, why, ok and "" or ("FAILED " .. tostring(how))))
    if ok then applied = r end
end

local function busy() return next(running) ~= nil end

local function notify(label)
    local b = busy()
    if b == wasBusy then return end
    wasBusy = b
    for _, fn in ipairs(listeners) do pcall(fn, b, label) end
end

function M.Begin(label, durS, rate)
    local t = nowMs()
    local untilAt = t + math.max(0.05, tonumber(durS) or 1.0) * 1000
    running[label] = { untilAt = untilAt, rate = rate, startedAt = t }
    applyRate(label .. " start")
    notify(label)
    return untilAt
end

function M.Hold(label, rate)
    running[label] = { untilAt = nil, rate = rate, startedAt = nowMs() }
    applyRate(label .. " hold")
    notify(label)
end

-- Extend a timed action (e.g. while the engine still reports the cast).
function M.Extend(label, untilAt)
    local a = running[label]
    if a and a.untilAt and untilAt > a.untilAt then a.untilAt = untilAt end
end

function M.Release(label)
    if not running[label] then return end
    running[label] = nil
    applyRate(label .. " end")
    notify(label)
end

function M.Busy() return busy() end
function M.Running(label) return running[label] ~= nil end
-- A timed action (swing, cast) runs; holds (bow draw, spell prepare) don't count.
function M.TimedBusy()
    for _, a in pairs(running) do if a.untilAt then return true end end
    return false
end

function M.Describe()
    local parts = {}
    for l, a in pairs(running) do
        parts[#parts + 1] = string.format("%s(%s x%.2f)", l, a.untilAt and string.format("%dms", a.untilAt - nowMs()) or "held", a.rate or 1)
    end
    return #parts > 0 and table.concat(parts, " ") or "none"
end

function M.OnChange(fn) listeners[#listeners + 1] = fn end

function M.SetBaseRate(owner, rate)
    owner = owner or "?"
    rate = rate or 1.0
    local old = baseRates[owner] or 1.0
    baseRates[owner] = (math.abs(rate - 1.0) > 1e-3) and rate or nil
    if math.abs(old - rate) > 1e-3 then applyRate("base " .. owner) end
end
function M.BaseRate() return (baseRate()) end

local function tick()
    if not next(running) then return end
    local t = nowMs()
    for label, a in pairs(running) do
        if a.untilAt and t >= a.untilAt then
            running[label] = nil
            applyRate(label .. " done")
            notify(label)
        end
    end
end

function M.Register()
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
end

return M
