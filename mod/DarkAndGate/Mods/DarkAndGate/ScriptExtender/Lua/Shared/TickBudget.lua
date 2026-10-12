-- SPDX-License-Identifier: GPL-3.0-or-later
-- Per-tick watchdog: every per-tick handler of the real-time combat pass
-- runs through Wrap(), which times it (Ext.Timer.MicrosecTime) and logs when
-- it goes over its budget (~1 ms by default), at most once per 10 s per
-- handler. Errors are caught and logged the same way.
--
--   Ext.Events.Tick:Subscribe(TickBudget.Wrap("NpcCombat", tick))
--   !dag_watchdog   worst and average time per handler since the last call

local Log = Ext.Require("Shared/Log.lua")

local M = {}

local stats = {}   -- name -> { n, sum, max, overAt, errAt }

local function us()
    local ok, v = pcall(Ext.Timer.MicrosecTime)
    if ok and tonumber(v) then return tonumber(v) end
    return (tonumber(Ext.Timer.MonotonicTime()) or 0) * 1000
end

function M.Wrap(name, fn, budgetMs)
    local budget = (budgetMs or 1.0) * 1000
    local st = { n = 0, sum = 0, max = 0, overAt = -1e12, errAt = -1e12 }
    stats[name] = st
    return function(...)
        local t0 = us()
        local ok, err = pcall(fn, ...)
        local dt = us() - t0
        st.n, st.sum = st.n + 1, st.sum + dt
        if dt > st.max then st.max = dt end
        if not ok and t0 - st.errAt > 10e6 then
            st.errAt = t0
            Log.Write(string.format("Watchdog: %s error: %s", name, tostring(err)))
        end
        if dt > budget and t0 - st.overAt > 10e6 then
            st.overAt = t0
            Log.Write(string.format("Watchdog: %s took %.2f ms (budget %.1f ms)", name, dt / 1000, budget / 1000))
        end
    end
end

function M.Report()
    local names = {}
    for n in pairs(stats) do names[#names + 1] = n end
    table.sort(names)
    for _, n in ipairs(names) do
        local st = stats[n]
        Log.Write(string.format("Watchdog: %-14s %6d ticks, avg %.3f ms, worst %.2f ms", n, st.n, st.n > 0 and st.sum / st.n / 1000 or 0,
            st.max / 1000))
        st.n, st.sum, st.max = 0, 0, 0
    end
end

function M.Register()
    Ext.RegisterConsoleCommand("dag_watchdog", function() M.Report() end)
end

return M
