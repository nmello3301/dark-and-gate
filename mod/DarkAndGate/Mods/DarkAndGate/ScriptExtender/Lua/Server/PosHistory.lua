-- SPDX-License-Identifier: GPL-3.0-or-later
-- Host position history for lag-tolerant hit checks (multiplayer MP-2,
-- docs/design/multiplayer.md "Lag tolerance"). Every sample_ms the host
-- records the feet of every character near a player (the projectile
-- candidate list, Server/Combat/Projectiles.lua Near) and keeps history_ms.
-- HitValidator asks: the target's positions within the last rewind_ms.
-- Single player: the same samples are taken; with rewind on, a melee hit
-- that the host would reject by a hair at the CURRENT position still lands
-- if the target was in reach a moment ago (what the attacker saw).

local data = Ext.Require("data/mp.lua")

local M = {}

local hist = {}       -- uuid -> { {t, x, y, z}, ... } oldest first
local lastSample = -1e9
local nearFn = nil
local rewindMs = data.rewind_ms

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

function M.SetNear(fn) nearFn = fn end
function M.RewindMs() return rewindMs end
function M.SetRewind(ms) rewindMs = math.max(0, math.min(data.history_ms, tonumber(ms) or rewindMs)) end

local function sample()
    local t = now()
    if t - lastSample < data.sample_ms or not nearFn then return end
    lastSample = t
    local cut = t - data.history_ms
    for uuid, n in pairs(nearFn() or {}) do
        local ok, p = pcall(function() return n.ent.Transform.Transform.Translate end)
        if ok and p then
            local h = hist[uuid] or {}
            hist[uuid] = h
            h[#h + 1] = { t, p[1], p[2], p[3] }
            while h[1] and h[1][1] < cut do table.remove(h, 1) end
        end
    end
    for uuid, h in pairs(hist) do
        if not h[#h] or h[#h][1] < cut then hist[uuid] = nil end
    end
end

-- Positions of `uuid` in the last `ms` (newest first): { {x, y, z, ageMs}, ... }
function M.Recent(uuid, ms)
    local h = hist[uuid]
    if not h then return {} end
    local t = now()
    local out = {}
    for i = #h, 1, -1 do
        local s = h[i]
        if t - s[1] > (ms or rewindMs) then break end
        out[#out + 1] = { s[2], s[3], s[4], t - s[1] }
    end
    return out
end

function M.Register()
    Ext.Events.Tick:Subscribe(function() pcall(sample) end)
end

M._hist = hist

return M
