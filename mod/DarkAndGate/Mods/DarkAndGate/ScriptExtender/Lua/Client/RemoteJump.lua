-- SPDX-License-Identifier: GPL-3.0-or-later
-- Other players' jumps on this screen (multiplayer MP-1). The jumper's DLL
-- steers the real arc only on the jumper's machine; the other clients see at
-- most BG3's own short fall. On JumpNotify { uuid, durMs, arcH, k, t0 (host
-- clock), y0 } this client lifts that character's drawn body along the same
-- curve y = h * (1 - |2u - 1|^k), minus whatever height the engine already
-- shows (so it never doubles), and puts it back down at the end.
-- Switch: jump_sync (Shared/MPFeatures.lua). Never runs for our own
-- character, and single player never receives JumpNotify (it excludes the
-- jumper).

local Log        = Ext.Require("Shared/Log.lua")
local MPState    = Ext.Require("Shared/MPState.lua")
local MPFeatures = Ext.Require("Shared/MPFeatures.lua")
local Me         = Ext.Require("Client/Me.lua")

local M = {}

local active = {}    -- uuid -> { start (local ms), dur (ms), h, k, y0 }
local logged = 0

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function curve(u, h, k)
    if u <= 0 or u >= 1 then return 0 end
    return h * (1 - math.abs(2 * u - 1) ^ k)
end

local function setVisualY(uuid, y)
    pcall(function()
        local e = Ext.Entity.Get(uuid)
        local t = e.Transform.Transform.Translate
        e.Visual.Visual:SetWorldTranslate({ t[1], y or t[2], t[3] })
    end)
end

function M.Start(msg)
    if not MPFeatures.On("jump_sync") or type(msg) ~= "table" or not msg.uuid then return end
    if msg.uuid == Me.Uuid() then return end
    local h = tonumber(msg.arcH) or tonumber(msg.h) or 0
    local dur = tonumber(msg.durMs) or 0
    if h <= 0.01 or dur <= 50 then return end
    local start = msg.t0 and MPState.ToLocal(msg.t0) or now()
    if start > now() then start = now() end
    active[msg.uuid] = { start = start, dur = dur, h = h, k = tonumber(msg.k) or 3, y0 = tonumber(msg.y0) }
    if logged < 20 then
        logged = logged + 1
        Log.Write(string.format("RemoteJump: %s jumps (%.0f ms, %.2f m, started %.0f ms ago by the host clock)",
            tostring(msg.uuid), dur, h, now() - start))
    end
end

local function tick()
    if next(active) == nil then return end
    local t = now()
    for uuid, j in pairs(active) do
        local u = (t - j.start) / j.dur
        if u >= 1 or not MPFeatures.On("jump_sync") then
            active[uuid] = nil
            setVisualY(uuid, nil)   -- back onto the real position
        else
            pcall(function()
                local e = Ext.Entity.Get(uuid)
                local cur = e.Transform.Transform.Translate
                local y0 = j.y0 or cur[2]
                if not j.y0 then j.y0 = y0 end
                local want = y0 + curve(u, j.h, j.k)
                if want > cur[2] + 0.01 then
                    e.Visual.Visual:SetWorldTranslate({ cur[1], want, cur[3] })
                end
            end)
        end
    end
end

function M.Register()
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
    Log.Write("RemoteJump: registered (other players' jump arcs; switch jump_sync)")
end

M._active = active

return M
