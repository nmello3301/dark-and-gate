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
-- Moving jumps (2026-10-09 movement round): the lift is the same on a moving
-- jump; WASD keeps steering because the real position never leaves the
-- ground. Osi.PlayAnimation may stop the walk, so data.jump.moving_anims
-- decides whether clips play on a moving jump ("auto": the first one is
-- checked, and if the walk stops with WASD held, moving jumps skip clips for
-- the session; logged as "Jump: moving clip ROOTED ...").
--
-- Actions in the air (Client/Combat/Actions.lua): a swing, a cast or the
-- spell prepare loop suspends the phase clips; when it ends, the phase that
-- matches the arc resumes ("Jump: resumed <phase> ..."). An action still
-- playing at touchdown delays the landing clip instead of being cut off.
--
-- Commands (client console):
--   !dag_jump <mult> [height] [flatness]   tune live (duration multiplier,
--                                          apex height m, apex flatness k)
--   !dag_jump_status                       print the current tuning
--   !dag_lift_probe [m]                    SE-only body lift test (diagnostic)
--   !dag_jump_play_anims [on|off]          jump clips on/off (lift unaffected)
--   !dag_jump_mult <x> / !dag_jump_height <m>   the same as !dag_jump, one value
--   !dag_jump_moving_anims auto|on|off     clips on moving jumps (see above)

local Log       = Ext.Require("Shared/Log.lua")
local MCM       = Ext.Require("Shared/MCM.lua")
local ClientNet = Ext.Require("Client/Net.lua")
local State     = Ext.Require("Client/Combat/State.lua")
local FullPov   = Ext.Require("FullPov.lua")
local JumpAnims = Ext.Require("Client/Movement/JumpAnims.lua")
local movement  = Ext.Require("data/movement.lua")
local Actions   = Ext.Require("Client/Combat/Actions.lua")

local M = {}

local D = movement.jump
local A = movement.air_action

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
    P = nil,          -- phase clips of the current jump
    Ts = 0,           -- airtime, seconds
    rate = nil,       -- clip play rate of the current jump (nil = clips off)
    landPlayed = false,
    landPending = nil, -- { at = ms } touchdown happened while an action played
    rootCheck = nil,   -- { at = ms, v0 = m/s } moving-clip check
    movingPolicy = D.moving_anims or "auto",
    rootedSeen = false, -- auto: a moving clip stopped the walk this session
    movingChecked = false,
}

-- WASD held? Read-only key tracking (Input.lua owns the key handling) for
-- the moving-clip check.
local held = {}
local function moveKeysHeld() return held.W or held.A or held.S or held.D end

local function play(clip, label)
    if not clip or not cfg("play_anims") then return end
    if label == "land" then J.landPlayed = true end
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

-- Phase schedule for a jump of T seconds starting at t0 (ms). Clip
-- lengths are divided by the play rate (the clips are fitted to T).
-- 2026-10-09: phases = cast, ascend, descend (data.jump.phases); without a
-- land clip, descend ends at touchdown.
local function schedule(t0, T, P, rate)
    rate = (rate and rate > 0) and rate or 1.0
    local function sd(c) return dur(c) / rate end
    local ev = {}
    local landAt = P.land and math.max(0, T - D.land_lead_s) or T
    local cursor = 0
    if D.use_cast and P.cast then
        ev[#ev + 1] = { at = 0, clip = P.cast, label = "cast" }
        cursor = sd(P.cast)
    end
    if P.ascend then
        ev[#ev + 1] = { at = cursor, clip = P.ascend, label = "ascend" }
        cursor = cursor + sd(P.ascend)
    end
    local descendAt = landAt - sd(P.descend)
    if P.hang and descendAt - cursor > 0.1 then
        local every = sd(P.hang) >= 0.1 and sd(P.hang) or nil
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

-- After an action: rebuild the schedule and play the phase that matches
-- the current point of the arc now (earlier phases are dropped, later ones
-- keep their times). Returns the phase label or nil.
local function resumePhase(now)
    if not J.P or J.rate == nil then return nil end
    local ev = schedule(J.t0, J.Ts, J.P, J.rate)
    local cur
    for i, e in ipairs(ev) do if e.at <= now then cur = i end end
    -- The next phase is about due (e.g. landing 30 ms away): go straight
    -- to it instead of starting a clip that would be cut at once.
    if cur and ev[cur + 1] and ev[cur + 1].at - now < A.resume_skip_s * 1000 then
        cur = cur + 1
        ev[cur].at = now
    end
    local out = {}
    local label
    for i, e in ipairs(ev) do
        if cur and i < cur then
            -- already past
        elseif i == cur then
            if not (e.untilAt and now >= e.untilAt) and not (e.label == "land" and J.landPlayed) then
                e.at = now
                out[#out + 1] = e
                label = e.label
            end
        else
            out[#out + 1] = e
        end
    end
    J.events = out
    return label or "next"
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

-- Airborne with horizontal momentum? (Prepare.lua defers its clip: an
-- Osi.PlayAnimation clip stops the walk, which killed the jump's inertia.)
function M.AirborneMoving()
    return J.active and (J.moving or moveKeysHeld()) and true or false
end
function M.Airborne() return J.active end

function M.OnSpace()
    if not cfg("enabled") then return end
    local now = nowMs()
    if J.active or now < J.readyAt then
        if J.active then Log.Write("Jump: ignored (already airborne, no double jump)") end
        return
    end

    local P = {}
    for _, ph in ipairs(D.phases or { "cast", "ascend", "hang", "descend", "land" }) do P[ph] = JumpAnims.Pick(ph) end
    local moving = speed.v >= (D.moving_speed or 0.8)
    J.moving = moving
    local clipsWhy
    local clipsOn = cfg("play_anims")
    if not clipsOn then
        clipsWhy = "off (!dag_jump_play_anims)"
    elseif moving and J.movingPolicy == "off" then
        clipsOn, clipsWhy = false, "off on moving jumps (policy off)"
    elseif moving and J.movingPolicy == "auto" and J.rootedSeen and FullPov.JumpMode() ~= "real" then
        clipsOn, clipsWhy = false, "off on moving jumps (a clip rooted the walk earlier)"
    else
        clipsWhy = moving and ("on, moving (policy " .. J.movingPolicy .. ")") or "on"
    end
    local base, baseSrc = baseAir(P.ascend, P.descend)
    local T = base * cfg("duration_mult")
    if T < D.min_air_s then T = D.min_air_s end
    if T > D.max_air_s then T = D.max_air_s end
    local h, k = cfg("height_m"), cfg("apex_flatness")

    J.seq = J.seq + 1
    J.active = true
    J.t0 = now
    J.T = T * 1000
    J.Ts = T
    J.P = P
    -- Fit the clips to the airtime: rate = clip time / airtime.
    local clipsAir = (D.use_cast and dur(P.cast) or 0) + dur(P.ascend) + dur(P.descend)
    local rate = clipsAir > 0 and math.max(0.3, math.min(D.max_clip_rate or 1.0, clipsAir / T)) or 1.0
    J.events = clipsOn and schedule(now, T, P, rate) or {}
    J.landPlayed = false
    J.landPending = nil
    J.rate = nil
    J.rootCheck = nil
    -- Real jump: the DLL owns the horizontal motion, so a clip can't root it.
    if clipsOn and moving and J.movingPolicy == "auto" and not J.movingChecked and #J.events > 0
        and FullPov.JumpMode() ~= "real" then
        J.rootCheck = { at = now + 450, v0 = speed.v }
    end
    State.jumping = true

    FullPov.Jump(J.seq, J.T, h, k)
    -- Real jump: the character's real position rises, so the hitbox follows
    -- by itself; only the visual lift needs the hitbox lifted by hand.
    ClientNet.JumpStart(J.T, FullPov.JumpMode() == "real" and 0 or h, k)

    -- Slow the jump clips to fit the airtime with the native per-character
    -- play rate (AnimRate.cpp, docs/spikes/anim-clock.md); reset on landing.
    -- (base rate through Actions: an action in the air plays at its own
    -- rate and the jump rate comes back after it); reset on landing.
    local animPath = (#J.events > 0) and "substitute" or "none"
    if #J.events > 0 and clipsAir > 0 then
        J.rate = rate
        Actions.SetBaseRate("jump", J.rate)
        animPath = string.format("phases at x%.2f", J.rate)
    elseif #J.events > 0 then
        J.rate = 1.0
    end

    Log.Write(string.format(
        "Jump: start seq=%d T=%.2fs h=%.2fm k=%.1f base=%.2fs(%s) mult=%.2f anim=%s phases=%d clips=%s data=%s speed=%.1fm/s moving=%s wasd=%s actions=%s",
        J.seq, T, h, k, base, baseSrc, cfg("duration_mult"), animPath, #J.events, clipsWhy, JumpAnims.State(),
        speed.v, moving and "yes" or "no", moveKeysHeld() and "held" or "none", Actions.Describe()))
end

local function landNow(why)
    play(J.P and J.P.land, "land")
    Log.Write("Jump: landing clip " .. why)
end

local function tick()
    local now = nowMs()
    sampleSpeed(now)

    -- Touchdown happened during an action: the landing clip waits for it.
    if J.landPending and not Actions.Busy() then
        local late = now - J.landPending.at
        if late <= A.land_after_s * 1000 then
            landNow(string.format("after the action (%d ms after touchdown)", late))
        else
            Log.Write(string.format("Jump: landing clip skipped (action ended %d ms after touchdown > %d)",
                late, math.floor(A.land_after_s * 1000)))
        end
        J.landPending = nil
    end

    if not J.active then return end

    -- Moving-clip check (policy auto, once per session until it passes).
    if J.rootCheck and now >= J.rootCheck.at then
        local rc = J.rootCheck
        J.rootCheck = nil
        if moveKeysHeld() and speed.v < D.rooted_speed then
            J.rootedSeen = true
            J.events = {}
            Actions.SetBaseRate("jump", 1.0)
            ClientNet.PlayAnim("__stop__")
            Log.Write(string.format(
                "Jump: moving clip ROOTED the walk (%.1f -> %.1f m/s with WASD held); clips skipped on moving jumps from now (!dag_jump_moving_anims on|auto)",
                rc.v0, speed.v))
        elseif moveKeysHeld() then
            J.movingChecked = true
            Log.Write(string.format("Jump: moving clip check ok (%.1f -> %.1f m/s with WASD held)", rc.v0, speed.v))
        else
            Log.Write("Jump: moving clip check skipped (WASD released mid-jump)")
        end
    end

    -- An action (swing / cast / prepare loop) owns the body: no phase clips
    -- until it ends (the landing below still runs on time).
    local suspended = Actions.Busy()
    for _, e in ipairs(suspended and {} or J.events) do
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
        if J.rate then Actions.SetBaseRate("jump", 1.0) end
        -- Real jump: the last clip (descend) is still an Osiris task at
        -- touchdown and held the character ("stuck in the landing"); end it
        -- now unless an action (swing / cast) owns the body.
        if FullPov.JumpMode() == "real" and J.rate and not Actions.Busy() then
            ClientNet.PlayAnim("__stop__")
        end
        local landWait = ""
        if suspended and J.rate and not J.landPlayed and J.P and J.P.land then
            J.landPending = { at = now }
            landWait = " (landing clip waits for " .. Actions.Describe() .. ")"
        end
        Log.Write(string.format("Jump: landed seq=%d after %.2fs speed=%.1fm/s wasd=%s%s",
            J.seq, (now - J.t0) / 1000, speed.v, moveKeysHeld() and "held" or "none", landWait))
    end
end

-- Actions start / end while airborne.
local function onActions(busy, label)
    if not J.active or J.rate == nil then return end
    local now = nowMs()
    local u = (now - J.t0) / J.T
    if busy then
        Log.Write(string.format("Jump: clips suspended for %s at u=%.2f (lift continues)", tostring(label), u))
    else
        local ph = resumePhase(now)
        Log.Write(string.format("Jump: resumed %s after %s at u=%.2f", tostring(ph), tostring(label), u))
    end
end

function M.Register()
    MCM.DefineBool("jump_enabled", D.enabled, "Jump on Space (first person)")
    -- Osi.PlayAnimation is an Osiris task; if it roots Gale while moving,
    -- !dag_jump_play_anims off keeps the lift without the clips.
    MCM.DefineBool("jump_play_anims", true, "Play BG3's jump animation")
    MCM.RegisterToggleCommand("dag_jump_play_anims", "jump_play_anims")
    MCM.DefineNumber("jump_duration_mult", D.duration_mult, "Jump airtime multiplier (floatiness)", 0.5, 4.0)
    -- Max 10 m: 2026-10-10 test of casting at the top of a 10x jump.
    MCM.DefineNumber("jump_height_m", D.height_m, "Jump height (m)", 0.1, 10.0)
    MCM.DefineNumber("jump_apex_flatness", D.apex_flatness, "Jump apex hang (2 = parabola)", 1.0, 8.0)

    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
    Actions.OnChange(onActions)
    Ext.Events.KeyInput:Subscribe(function(e)
        local k = tostring(e.Key or "")
        if k == "W" or k == "A" or k == "S" or k == "D" then
            held[k] = tostring(e.Event or "") == "KeyDown"
        end
    end)

    Ext.RegisterConsoleCommand("dag_jump_mult", function(_, x)
        if tonumber(x) then MCM.Set("jump_duration_mult", tonumber(x)) end
        Log.Write(string.format("Jump: mult=%.2f (airtime %.2fs)", cfg("duration_mult"), D.clip_air_s * cfg("duration_mult")))
    end)
    Ext.RegisterConsoleCommand("dag_jump_height", function(_, x)
        if tonumber(x) then MCM.Set("jump_height_m", tonumber(x)) end
        Log.Write(string.format("Jump: height=%.2fm", cfg("height_m")))
    end)
    Ext.RegisterConsoleCommand("dag_jump_mode", function(_, x)
        if x == "real" or x == "visual" then FullPov.SetJumpMode(x) end
        Log.Write("Jump: mode = " .. FullPov.JumpMode() .. " (real = the character itself goes up; native.log RJUMP lines)")
    end)
    Ext.RegisterConsoleCommand("dag_jump_strafe_flip", function()
        Log.Write("Jump: A/D in the air flipped, strafe_sign = " .. tostring(FullPov.FlipStrafe()))
    end)
    FullPov.SetRealJumpTuning(D.strafe_sign, D.land_speed, D.wall_check_m)
    if D.mode == "real" then FullPov.SetJumpMode("real") end

    Ext.RegisterConsoleCommand("dag_jump_moving_anims", function(_, x)
        if x == "auto" or x == "on" or x == "off" then
            J.movingPolicy = x
            J.rootedSeen, J.movingChecked = false, false
        end
        Log.Write("Jump: clips on moving jumps = " .. J.movingPolicy)
    end)

    Ext.RegisterConsoleCommand("dag_jump", function(_, mult, height, flat)
        if tonumber(mult)   then MCM.Set("jump_duration_mult", tonumber(mult)) end
        if tonumber(height) then MCM.Set("jump_height_m", tonumber(height)) end
        if tonumber(flat)   then MCM.Set("jump_apex_flatness", tonumber(flat)) end
        Log.Write(string.format("Jump: mult=%.2f height=%.2fm flatness=%.1f",
            cfg("duration_mult"), cfg("height_m"), cfg("apex_flatness")))
    end)
    Ext.RegisterConsoleCommand("dag_jump_status", function()
        Log.Write(string.format("Jump: enabled=%s mult=%.2f height=%.2fm flatness=%.1f active=%s seq=%d scan=%s moving_anims=%s rooted=%s",
            tostring(cfg("enabled")), cfg("duration_mult"), cfg("height_m"), cfg("apex_flatness"),
            tostring(J.active), J.seq, JumpAnims.State(), J.movingPolicy, tostring(J.rootedSeen)))
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

    Log.Write("Jump: registered (Space; !dag_jump <mult> [height] [flatness]; !dag_jump_mult; !dag_jump_height; !dag_jump_moving_anims; !dag_jump_status; !dag_lift_probe)")
end

return M
