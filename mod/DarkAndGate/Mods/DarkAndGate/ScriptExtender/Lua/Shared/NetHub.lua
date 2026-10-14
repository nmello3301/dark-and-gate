-- SPDX-License-Identifier: GPL-3.0-or-later
-- Every net message of OUR mod passes through here (multiplayer MP-4):
--   * counts per channel (msgs/s and bytes/s, in and out) for !dag_mp_status;
--   * a ring of the last 10 s of messages, dumped into issue markers;
--   * simulated lag (!dag_mp_lag <ms>): our own outgoing messages AND our
--     incoming handlers on this machine wait <ms> each (about 2 x ms added
--     to the round trip). 0 = off, the default: messages go straight through.
--
-- How: SE gives each mod its own environment with its own `Ext` table
-- (ModLoader.CreateModEnv), so Install() swaps OUR `Ext` for a proxy that
-- wraps Ext.Net.PostMessageToServer / PostMessageToUser / PostMessageToClient
-- / BroadcastMessage and Ext.RegisterNetListener, and forwards everything
-- else to the real one. Other mods never see it. Install() runs first thing
-- in both bootstraps.

local M = {}

local RING_S = 10
local RING_MAX = 3000

local real = Ext
local ring = {}            -- { t, dir = "in"|"out", ch, user, bytes, preview }
local lagMs = 0
local queue = {}           -- deferred sends / handlers while lag is on
local installed = false

local function now() return tonumber(real.Timer.MonotonicTime()) or 0 end

local function note(dir, ch, user, payload)
    local s = type(payload) == "string" and payload or ""
    ring[#ring + 1] = { t = now(), dir = dir, ch = tostring(ch), user = user, bytes = #s, preview = s:sub(1, 80) }
    if #ring > RING_MAX then table.remove(ring, 1) end
end

local function prune()
    local cut = now() - RING_S * 1000
    local i = 1
    while ring[i] and ring[i].t < cut do i = i + 1 end
    if i > 1 then
        local keep = {}
        for j = i, #ring do keep[#keep + 1] = ring[j] end
        ring = keep
    end
end

local function later(fn, ...)
    queue[#queue + 1] = { at = now() + lagMs, fn = fn, args = table.pack(...) }
end

local function flush()
    if #queue == 0 then return end
    local t = now()
    local keep = {}
    for _, q in ipairs(queue) do
        if q.at <= t then
            local ok, err = pcall(q.fn, table.unpack(q.args, 1, q.args.n))
            if not ok then pcall(function() real.Utils.Print("[DarkAndGate] NetHub: delayed message failed: " .. tostring(err)) end) end
        else
            keep[#keep + 1] = q
        end
    end
    queue = keep
end

-- sendFn(...) with the channel / payload at the given argument positions.
local function wrapOut(fn, chPos, payloadPos, userPos)
    return function(...)
        local a = table.pack(...)
        note("out", a[chPos], userPos and a[userPos] or nil, a[payloadPos])
        if lagMs > 0 then later(fn, ...); return end
        return fn(...)
    end
end

function M.Install()
    if installed then return end
    installed = true
    local realNet = real.Net
    local net = setmetatable({
        PostMessageToServer = wrapOut(function(...) return realNet.PostMessageToServer(...) end, 1, 2, nil),
        PostMessageToUser   = wrapOut(function(...) return realNet.PostMessageToUser(...) end, 2, 3, 1),
        PostMessageToClient = wrapOut(function(...) return realNet.PostMessageToClient(...) end, 2, 3, 1),
        BroadcastMessage    = wrapOut(function(...) return realNet.BroadcastMessage(...) end, 1, 2, nil),
    }, { __index = realNet })
    local proxy = setmetatable({
        Net = net,
        RegisterNetListener = function(ch, fn)
            return real.RegisterNetListener(ch, function(c, payload, user)
                note("in", c, user, payload)
                if lagMs > 0 then later(fn, c, payload, user); return end
                return fn(c, payload, user)
            end)
        end,
    }, { __index = real })
    Ext = proxy   -- our mod environment's Ext only (see the header)
    real.Events.Tick:Subscribe(function() pcall(flush) end)
end

function M.SetLag(ms) lagMs = math.max(0, math.min(2000, tonumber(ms) or 0)) end
function M.Lag() return lagMs end

-- Per channel over the last `secs` seconds: { ch = { inN, outN, inB, outB } },
-- plus totals.
function M.Stats(secs)
    prune()
    secs = secs or 5
    local cut = now() - secs * 1000
    local per, tot = {}, { inN = 0, outN = 0, inB = 0, outB = 0 }
    for _, e in ipairs(ring) do
        if e.t >= cut then
            local p = per[e.ch] or { inN = 0, outN = 0, inB = 0, outB = 0 }
            per[e.ch] = p
            if e.dir == "in" then p.inN = p.inN + 1; p.inB = p.inB + e.bytes; tot.inN = tot.inN + 1; tot.inB = tot.inB + e.bytes
            else p.outN = p.outN + 1; p.outB = p.outB + e.bytes; tot.outN = tot.outN + 1; tot.outB = tot.outB + e.bytes end
        end
    end
    return per, tot, secs
end

-- The last `secs` seconds of messages, oldest first.
function M.Recent(secs)
    prune()
    local cut = now() - (secs or RING_S) * 1000
    local out = {}
    for _, e in ipairs(ring) do if e.t >= cut then out[#out + 1] = e end end
    return out
end

-- One line per channel, busiest first ("DAG_HitClaim in 2.0/s out 0.0/s").
function M.StatsLines(secs)
    local per, tot, s = M.Stats(secs)
    local rows = {}
    for ch, p in pairs(per) do rows[#rows + 1] = { ch = ch, n = p.inN + p.outN, p = p } end
    table.sort(rows, function(a, b) return a.n > b.n end)
    local lines = { string.format("net last %ds: in %.1f msg/s %.0f B/s, out %.1f msg/s %.0f B/s, lag %d ms",
        s, tot.inN / s, tot.inB / s, tot.outN / s, tot.outB / s, lagMs) }
    for i = 1, math.min(#rows, 12) do
        local r = rows[i]
        lines[#lines + 1] = string.format("  %s in %.1f/s out %.1f/s", r.ch, r.p.inN / s, r.p.outN / s)
    end
    return lines
end

return M
