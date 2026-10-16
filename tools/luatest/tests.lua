-- SPDX-License-Identifier: GPL-3.0-or-later
-- Offline tests for the mod's pure logic (tools/luatest/run.py). Returns a
-- function(require) -> ok, report. `require` loads a mod file the way
-- Ext.Require does; Ext is a small stand-in with only what these modules use.

return function(require)
    local out, fails = {}, 0
    local function check(cond, what)
        if cond then out[#out + 1] = "ok   " .. what else fails = fails + 1; out[#out + 1] = "FAIL " .. what end
    end
    local function near(a, b, tol) return type(a) == "number" and math.abs(a - b) <= (tol or 1e-6) end

    -- Ext stand-in: a server Lua state with entities that carry Vars.
    local clock = 0
    local entities = {}
    Ext = {
        Require = require,
        IsServer = function() return true end,
        Utils = { Print = function() end },
        Timer = { MonotonicTime = function() clock = clock + 1; return clock end },
        IO = { SaveFile = function() return true end, LoadFile = function() return nil end },
        Events = setmetatable({}, { __index = function() return { Subscribe = function() end } end }),
        Vars = { RegisterUserVariable = function() end },
        Json = { Stringify = function() return "{}" end, Parse = function() return {} end },
        Entity = { Get = function(uuid) entities[uuid] = entities[uuid] or { Vars = {} }; return entities[uuid] end },
    }

    local Curve = require("Shared/MetaCurve.lua")
    local defaults = require("data/metapoints.lua")
    local MP = require("Shared/MetaPoints.lua")
    local MC = require("Shared/MeleeCooldown.lua")

    -- 1. The signed-off table (both the shared self-test and its lines).
    local ok, lines = Curve.SelfTest(defaults.effects, 0.01)
    check(ok, "Meta-Points curves match the signed-off table: " .. lines[1])
    if not ok then for i = 2, #lines do out[#out + 1] = "     " .. lines[i] end end

    -- 2. Interpolation edges.
    local bps = { { 0, 1.0 }, { 48, 3.0 }, { 96, 4.0 } }
    check(near(Curve.Eval(bps, 24), 2.0), "Eval: linear between breakpoints")
    check(near(Curve.Eval(bps, 200), 4.0), "Eval: flat after the last breakpoint")
    check(near(Curve.Eval(bps, -5), 1.0), "Eval: flat before the first breakpoint")
    check(near(Curve.Eval({ { 10, 0.5 } }, 99), 0.5), "Eval: a single breakpoint is flat")
    check(near(Curve.Eval({ { 0, 1 }, { 50, 2 }, { 50, 5 }, { 96, 5 } }, 50), 2), "Eval: a repeated point takes the first value at it")
    check(Curve.Eval({}, 3) == nil, "Eval: no breakpoints = nil")

    -- 3. Config merge: a changed curve, a broken one, an unknown effect.
    local merged, notes = MP.Merge(defaults, {
        respec_mode = "anywhere",
        _readme = "ignored",
        effects = {
            { id = "move_speed", points = { { 0, 1.0 }, { 96, 2.0 } } },
            { id = "cast_time", points = { { 50, 1 }, { 10, 2 } } },
            { id = "parry", points = { { 0, 1 } } },
        },
    })
    local byId = {}
    for _, e in ipairs(merged.effects) do byId[e.id] = e end
    check(merged.respec_mode == "anywhere" and merged._readme == nil, "Merge: plain keys replace, _ keys are ignored")
    check(near(Curve.Eval(byId.move_speed.points, 96), 2.0), "Merge: a valid curve replaces the default")
    check(near(Curve.Eval(byId.cast_time.points, 58), 0.075), "Merge: a curve out of order keeps the default")
    check(#notes == 2, "Merge: two notes (the broken curve, the unknown effect), got " .. #notes)
    check(near(Curve.Eval(defaults.effects[10].points, 96), 4.0), "Merge: the defaults are not modified")

    -- 4. Records and points.
    MP.SetConfig(defaults)
    local u = "11111111-2222-3333-4444-555555555555"
    check(MP.Record(u) == nil and MP.Mult(u, "melee_damage") == 1.0, "A character with no saved data: 0 spent, x1")
    Ext.Entity.Get(u).Vars[MP.VAR] = { v = 1, spent = { STR = 48, DEX = 86, WIS = 58, CON = 96, CHA = 12 }, bonus = 4 }
    check(near(MP.Mult(u, "melee_damage"), 3.0), "STR 48 -> melee x3.0")
    check(near(MP.Value(u, "block"), 0.85), "CON 96 -> block 85 %")
    check(near(MP.Value(u, "move_speed"), 1.375), "CHA 12 -> move x1.375")
    check(MP.SpentTotal(MP.Record(u)) == 300 and MP.Total(12, MP.Record(u)) == 100, "Spent total 300, total at level 12 with 4 bonus = 100")
    check(near(MP.Value(u, "melee_damage", { STR = 96 }), 4.0), "Preview with a pending spend table")
    check(near(MP.Floor(0), 0.05) and near(MP.Floor(1.2), 1.2), "min_action_interval floors at 0.05 s")

    -- 5. Melee cooldown and the faster swing.
    check(near(MC.Seconds("longsword", u), 0.15), "DEX 86: cooldown 1.5 s x 0.10 = 0.15 s")
    check(near(MC.Seconds("longsword"), 1.5), "No character: the base cooldown")
    check(near(MC.SwingRate(0.15, 420), 2.8), "A 420 ms swing under a 0.15 s cooldown plays x2.8")
    check(near(MC.SwingRate(1.5, 420), 1.0), "A cooldown longer than the swing: normal speed")
    check(near(MC.SwingRate(0.05, 580), 4.0), "Capped at max_swing_rate 4")
    check(near(MC.ServerSlack(0.15), 0.075) and near(MC.ServerSlack(1.5), 0.4), "Server slack: 0.4 s, at most half the cooldown")

    -- 6. min_action_interval 0 is allowed.
    local zero = MP.Merge(defaults, { min_action_interval = 0 })
    MP.SetConfig(zero)
    check(MP.Floor(0) == 0 and near(MC.Seconds("longsword", u), 0.15), "min_action_interval 0: no floor")
    MP.SetConfig(defaults)

    table.insert(out, 1, string.format("tests: %d checks, %d failed", #out, fails))
    return fails == 0, table.concat(out, "\n")
end
