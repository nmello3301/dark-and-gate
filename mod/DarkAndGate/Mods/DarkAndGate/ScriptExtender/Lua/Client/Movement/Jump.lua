-- SPDX-License-Identifier: GPL-3.0-or-later
-- First-person jump on Space: floaty, straight up, visual only.
--
-- Split of work:
--   * Lua (this file) decides THAT a jump happens, plays BG3's jump clips
--     through the server (Osi.PlayAnimation, so other players see the
--     animation too) and tells the server, which lifts this character's
--     hitbox (Shared/Hitbox.lua) and relays the jump to other clients.
--   * The DLL lifts the local body and camera along the curve
--     y = h * (1 - |2u - 1|^k) for the jump's duration (Pov.cpp,
--     VisualLift.cpp). Lua hands it seq / duration / height / k through
--     native-pov.txt (FullPov.Jump); the DLL starts the curve the frame it
--     sees a new seq.
--
-- Animation path (logged on every jump as anim=...): no playback-speed
-- lever (docs/spikes/m1b-anim-speed.md), so the JumpFlight clips play in
-- phases at normal speed, timed to the jump:
--   [cast]  ascend  hang (re-triggered)  descend  land(recover)
--   0       0/cast  ascend end ->        T - lead - descend.dur   T - lead
-- "none" = no clips found yet (scan running or empty); the lift still runs.
--
-- Commands (client console):
--   !dag_jump <mult> [height] [flatness]   tune live (duration multiplier,
--                                          apex height m, apex flatness k)
--   !dag_jump_status                       print the current tuning
--   !dag_lift_probe [m]                    SE-only body lift test (diagnostic)
--   !dag_jump_play_anims [on|off]          jump clips on/off (lift unaffected)

local Log       = Ext.Require("Shared/Log.lua")
local MCM       = Ext.Require("Shared/MCM.lua")
local ClientNet = Ext.Require("Client/Net.lua")
local State     = Ext.Require("Client/Combat/State.lua")
local FullPov   = Ext.Require("FullPov.lua")
local JumpAnims = Ext.Require("Client/Movement/JumpAnims.lua")
local movement  = Ext.Require("data/movement.lua")

local M = {}

local D = movement.jump

local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function cfg(key) return MCM.Get("jump_" .. key) end

local J = {
    -- Seeded from the clock so a Lua `reset` never reuses the seq the DLL
    -- saw last (the DLL starts a lift on any seq change).
    seq = math.floor(nowMs() / 1000) % 1000000,
    active = false,
    t0 = 0,
    T = 0,            -- ms
    events = {},      -- { at = ms (absolute), clip, label, every = ms?, untilAt = ms? }
    readyAt = 0,      -- ms (absolute), next jump accepted
}

local function play(clip, label)
    if not clip or not cfg("play_anims") then return end
    ClientNet.PlayAnim(clip.key, (clip.dur or 0) > 0 and clip.dur or nil)
    Log.Write(string.format("Jump: anim %s %s (%.2fs)", label, clip.key, clip.dur or 0))
end

local function dur(clip) return (clip and clip.dur and clip.dur > 0) and clip.dur or 0 end

-- Base airtime is the data value (0.8 s x 1.6 = 1.28 s was signed off in
-- the 2026-10-09 playtest); the clips are fitted to it. Their own airtime
-- (ascend + descend at normal speed) is only logged for reference.
local function baseAir(ascend, descend)
    local clips = dur(ascend) + dur(descend)
    return D.clip_air_s, string.format("data, clips=%.2fs", clips)
end

-- Phase schedule for a jump of T seconds starting at t0 (ms).
local function schedule(t0, T, P)
    local ev = {}
    local landAt = math.max(0, T - D.land_lead_s)
    local cursor = 0
    if D.use_cast and P.cast then
        ev[#ev + 1] = { at = 0, clip = P.cast, label = "cast" }
        cursor = dur(P.cast)
    end
    if P.ascend then
        ev[#ev + 1] = { at = cursor, clip = P.ascend, label = "ascend" }
        cursor = cursor + dur(P.ascend)
    end
    local descendAt = landAt - dur(P.descend)
    if P.hang and descendAt - cursor > 0.1 then
        local every = dur(P.hang) >= 0.1 and dur(P.hang) or nil
        ev[#ev + 1] = { at = cursor, clip = P.hang, label = "hang", every = every, untilAt = descendAt }
    end
    if P.descend and descendAt > 0 then
        ev[#ev + 1] = { at = math.max(cursor, descendAt), clip = P.descend, label = "descend" }
    end
    if P.land then
        ev[#ev + 1] = { at = landAt, clip = P.land, label = "land" }
    end
    for _, e in ipairs(ev) do
        e.at = t0 + e.at * 1000
        if e.untilAt then e.untilAt = t0 + e.untilAt * 1000 end
    end
    return ev
end

-- Horizontal speed of the controlled character (m/s), sampled every
-- 100 ms, so each jump logs whether it started standing or moving.
local speed = { at = 0, x = nil, z = nil, v = 0 }
local function sampleSpeed(now)
    if now - speed.at < 100 then return end
    local ok, t = pcall(function()
        return Ext.Entity.GetAllEntitiesWithComponent("ClientControl")[1].Transform.Transform.Translate
    end)
    if ok and t then
        if speed.x then
            local dt = (now - speed.at) / 1000
            local dx, dz = t[1] - speed.x, t[3] - speed.z
            speed.v = dt > 0 and math.sqrt(dx * dx + dz * dz) / dt or 0
        end
        speed.x, speed.z = t[1], t[3]
    end
    speed.at = now
end

function M.OnSpace()
    if not cfg("enabled") then return end
    local now = nowMs()
    if J.active or now < J.readyAt then return end

    local P = {}
    for _, ph in ipairs({ "cast", "ascend", "hang", "descend", "land" }) do P[ph] = JumpAnims.Pick(ph) end
    local base, baseSrc = baseAir(P.ascend, P.descend)
    local T = base * cfg("duration_mult")
    if T < D.min_air_s then T = D.min_air_s end
    if T > D.max_air_s then T = D.max_air_s end
    local h, k = cfg("height_m"), cfg("apex_flatness")

    J.seq = J.seq + 1
    J.active = true
    J.t0 = now
    J.T = T * 1000
    J.events = schedule(now, T, P)
    State.jumping = true

    FullPov.Jump(J.seq, J.T, h, k)
    ClientNet.JumpStart(J.T, h, k)

    local animPath = (#J.events > 0) and "substitute" or "none"
    Log.Write(string.format(
        "Jump: start seq=%d T=%.2fs h=%.2fm k=%.1f base=%.2fs(%s) mult=%.2f anim=%s phases=%d clips=%s speed=%.1fm/s",
        J.seq, T, h, k, base, baseSrc, cfg("duration_mult"), animPath, #J.events, JumpAnims.State(), speed.v))
end

local function tick()
    local now = nowMs()
    sampleSpeed(now)
    if not J.active then return end
    for _, e in ipairs(J.events) do
        if e.at and now >= e.at then
            if e.untilAt and now >= e.untilAt then
                e.at = nil
            else
                play(e.clip, e.label)
                e.at = e.every and (now + e.every * 1000) or nil
                if e.at and e.untilAt and e.at >= e.untilAt then e.at = nil end
            end
        end
    end
    if now >= J.t0 + J.T then
        J.active = false
        State.jumping = false
        J.readyAt = now + D.cooldown_s * 1000
        Log.Write(string.format("Jump: landed seq=%d after %.2fs", J.seq, (now - J.t0) / 1000))
    end
end

function M.Register()
    MCM.DefineBool("jump_enabled", D.enabled, "Jump on Space (first person)")
    -- Osi.PlayAnimation is an Osiris task; if it roots Gale while moving,
    -- !dag_jump_play_anims off keeps the lift without the clips.
    MCM.DefineBool("jump_play_anims", true, "Play BG3's jump animation")
    MCM.RegisterToggleCommand("dag_jump_play_anims", "jump_play_anims")
    MCM.DefineNumber("jump_duration_mult", D.duration_mult, "Jump airtime multiplier (floatiness)", 0.5, 4.0)
    MCM.DefineNumber("jump_height_m", D.height_m, "Jump height (m)", 0.1, 2.0)
    MCM.DefineNumber("jump_apex_flatness", D.apex_flatness, "Jump apex hang (2 = parabola)", 1.0, 8.0)

    Ext.Events.Tick:Subscribe(function() pcall(tick) end)

    Ext.RegisterConsoleCommand("dag_jump", function(_, mult, height, flat)
        if tonumber(mult)   then MCM.Set("jump_duration_mult", tonumber(mult)) end
        if tonumber(height) then MCM.Set("jump_height_m", tonumber(height)) end
        if tonumber(flat)   then MCM.Set("jump_apex_flatness", tonumber(flat)) end
        Log.Write(string.format("Jump: mult=%.2f height=%.2fm flatness=%.1f",
            cfg("duration_mult"), cfg("height_m"), cfg("apex_flatness")))
    end)
    Ext.RegisterConsoleCommand("dag_jump_status", function()
        Log.Write(string.format("Jump: enabled=%s mult=%.2f height=%.2fm flatness=%.1f active=%s seq=%d scan=%s",
            tostring(cfg("enabled")), cfg("duration_mult"), cfg("height_m"), cfg("apex_flatness"),
            tostring(J.active), J.seq, JumpAnims.State()))
    end)

    -- Diagnostic from docs/spikes/m1b-visual-lift.md: lift the body's Visual
    -- once via SE's SetWorldTranslate (vtable slot 2). Standing still it
    -- should stay up; walking snaps it back. !dag_lift_probe 0 to drop it.
    Ext.RegisterConsoleCommand("dag_lift_probe", function(_, m)
        local dy = tonumber(m) or 0.5
        local ok, err = pcall(function()
            local e = Ext.Entity.GetAllEntitiesWithComponent("ClientControl")[1]
            local v = e.Visual.Visual
            local t = e.Transform.Transform.Translate
            v:SetWorldTranslate({ t[1], t[2] + dy, t[3] })
            Log.Write(string.format("Jump: lift probe %+.2f m on Visual %s", dy, tostring(v)))
        end)
        if not ok then Log.Write("Jump: lift probe ERROR " .. tostring(err)) end
    end)

    Log.Write("Jump: registered (Space; !dag_jump <mult> [height] [flatness]; !dag_jump_status; !dag_lift_probe)")
end

return M
