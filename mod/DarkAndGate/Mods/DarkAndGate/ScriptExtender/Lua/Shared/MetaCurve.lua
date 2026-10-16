-- SPDX-License-Identifier: GPL-3.0-or-later
-- Meta-Points curves (data/metapoints.lua effects): the one interpolation
-- every effect uses, and the self-test against the table the design was
-- signed off with (developer 2026-10-15). Pure Lua, no Ext: the offline
-- harness (scripts/test-lua.ps1) runs the same code.
--
--   MetaCurve.Eval(points, x)           piecewise-linear: { {points, value}, ... },
--                                       linear between breakpoints, flat outside
--   MetaCurve.SelfTest(effects, tol)    -> ok, lines (effects = the effect list)

local M = {}

function M.Eval(bps, x)
    if type(bps) ~= "table" or #bps == 0 then return nil end
    x = tonumber(x) or 0
    local first = bps[1]
    if x <= first[1] then return first[2] end
    for i = 2, #bps do
        local a, b = bps[i - 1], bps[i]
        if x <= b[1] then
            local span = b[1] - a[1]
            if span <= 0 then return b[2] end
            return a[2] + (b[2] - a[2]) * (x - a[1]) / span
        end
    end
    return bps[#bps][2]
end

-- The signed-off table: points 0, 12, ..., 96. scale = what the curve value
-- is multiplied by for the row (cast time is in seconds of the 2.0 s base).
-- Cast time and bow draw are raw curve values, before min_action_interval.
M.POINTS = { 0, 12, 24, 36, 48, 60, 72, 84, 96 }
M.EXPECTED = {
    { label = "Damage mult",    ids = { "melee_damage", "ranged_damage", "spell_damage" }, scale = 1,
      values = { 1.0, 1.5, 2.0, 2.5, 3.0, 3.25, 3.5, 3.75, 4.0 } },
    { label = "Mana mult",      ids = { "max_mana" }, scale = 1,
      values = { 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0 } },
    { label = "Cast time (s)",  ids = { "cast_time" }, scale = 2.0,
      values = { 2.0, 1.62, 1.23, 0.85, 0.47, 0.142, 0.095, 0.047, 0.0 } },
    { label = "Bow draw mult",  ids = { "bow_draw" }, scale = 1,
      values = { 1.0, 0.839, 0.678, 0.516, 0.355, 0.194, 0.083, 0.041, 0.0 } },
    { label = "Attack cd mult", ids = { "attack_cooldown" }, scale = 1,
      values = { 1.0, 0.874, 0.749, 0.623, 0.498, 0.372, 0.247, 0.121, 0.10 } },
    { label = "Block",          ids = { "block" }, scale = 1,
      values = { 0.40, 0.456, 0.513, 0.569, 0.625, 0.681, 0.738, 0.794, 0.85 } },
    { label = "Jump height",    ids = { "jump_height" }, scale = 1,
      values = { 1.0, 2.125, 3.25, 4.375, 5.5, 6.625, 7.75, 8.875, 10.0 } },
    { label = "Move speed",     ids = { "move_speed" }, scale = 1,
      values = { 1.0, 1.375, 1.75, 2.125, 2.5, 2.875, 3.25, 3.625, 4.0 } },
}

function M.SelfTest(effects, tol)
    tol = tol or 0.01
    local byId = {}
    for _, e in ipairs(effects or {}) do byId[e.id] = e end
    local lines, fails, checks = {}, 0, 0
    for _, row in ipairs(M.EXPECTED) do
        for _, id in ipairs(row.ids) do
            local e = byId[id]
            if not e then
                fails = fails + 1
                lines[#lines + 1] = string.format("FAIL %s: effect %s missing", row.label, id)
            else
                for i, p in ipairs(M.POINTS) do
                    checks = checks + 1
                    local got = (M.Eval(e.points, p) or 0) * row.scale
                    local want = row.values[i]
                    if math.abs(got - want) > tol then
                        fails = fails + 1
                        lines[#lines + 1] = string.format("FAIL %s (%s) at %d points: got %.4f, want %.4f", row.label, id, p, got, want)
                    end
                end
            end
        end
    end
    table.insert(lines, 1, string.format("%s: %d checks, %d failed (tolerance %.2f)", fails == 0 and "PASS" or "FAIL", checks, fails, tol))
    return fails == 0, lines
end

return M
