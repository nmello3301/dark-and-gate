-- SPDX-License-Identifier: GPL-3.0-or-later
-- Client-side swing scheduler + hit detection.
--
-- Flow on LMB:
--   1. If a chain is live and we're inside the current swing's active or
--      early recovery window, advance to the next step. Else start swing 1.
--   2. Play the animation via PlayAnimRequest (server-authoritative).
--   3. Schedule the active window via Ext.OnTimer; during the window, sweep
--      the ray fan each 20 ms, send HitClaim for the first new character
--      hit per target.
--
-- M1b scope: one chain reset after the overhead or after combo_ms expires.
-- No weapon-family-specific logic yet (just reads longsword.lua).
--
-- Melee cooldown (DECISIONS 2026-10-13, Shared/MeleeCooldown.lua): one
-- swing per cooldown (1.5 s), swing start to swing start. A click in the
-- last buffer_s of it waits and swings on time; earlier clicks are ignored.
-- The chain still advances: combo_ms counts from the cooldown's end.

local Log       = Ext.Require("Shared/Log.lua")
local Net       = Ext.Require("Shared/Net.lua")
local State     = Ext.Require("Client/Combat/State.lua")
local Aim       = Ext.Require("Client/Combat/Aim.lua")
local longsword = Ext.Require("data/weapons/longsword.lua")
local ClientNet = Ext.Require("Client/Net.lua")
local Anims     = Ext.Require("Client/Combat/Anims.lua")
local Tags      = Ext.Require("Client/AnimLib/Tags.lua")
local Actions   = Ext.Require("Client/Combat/Actions.lua")
local airAction = Ext.Require("data/movement.lua").air_action
local MeleeCooldown = Ext.Require("Shared/MeleeCooldown.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")

local M = {}

-- Live swing data: { swingIndex, nonce, chainResetAt (ms), activeUntil,
--                    recoveryUntil, def, hitTargets = {} }
local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) end

local function chainExpired()
    if not State.currentSwing then return true end
    return nowMs() > State.currentSwing.chainResetAt
end

local function sendHitClaim(def, targetUuid, hitPos, zone)
    local nonce = State.currentSwing and State.currentSwing.nonce or 0
    ClientNet.Send(Net.Channels.HitClaim, {
        weapon      = longsword.name,
        swingIndex  = State.currentSwing and State.currentSwing.swingIndex or 1,
        swingNonce  = nonce,
        eye         = State.currentSwing and State.currentSwing.startEye or { 0, 0, 0 },
        forward     = State.currentSwing and State.currentSwing.startForward or { 0, 0, 1 },
        targetUuid  = targetUuid,
        hitPoint    = { x = hitPos[1], y = hitPos[2], z = hitPos[3] },
        hitZone     = zone,
        damage      = def.damage,
        reach       = def.reach_m,
    })
end

local function sampleHit()
    local s = State.currentSwing
    if not s then return end
    local eye, fwd = Aim.ReadInvView()
    if not eye then return end
    -- fix3: geometric melee test only (ray hits can't name an entity).
    -- Body within reach + 0.5 m, inside half the swing arc (>= 35 deg),
    -- with line of sight.
    local half = math.max(35, (s.def.arc_deg_h or 90) / 2)
    local hit = Aim.MeleeTarget(eye, fwd, (s.def.reach_m or 2.2) + 0.5, half)
    if State.swingDebug then
        local n = s.def.arc_rays
        local reach = s.def.reach_m
        Log.Write(string.format(
            "SwingDbg: eye=(%.2f,%.2f,%.2f) fwd=(%.2f,%.2f,%.2f) arc=%d rays=%d reach=%.1f hit=%s",
            eye[1], eye[2], eye[3], fwd[1], fwd[2], fwd[3],
            s.def.arc_deg_h, n, reach, hit and hit.targetUuid or "none"))
    end
    if hit and not s.hitTargets[hit.targetUuid] then
        s.hitTargets[hit.targetUuid] = true
        local zone = hit.zone or Aim.ClassifyZone(hit.targetUuid, hit.pos[2])
        sendHitClaim(s.def, hit.targetUuid, hit.pos, zone)
    end
    if hit and not s.firstHit then s.firstHit = hit end
    s.lastFwd = fwd
end

-- One summary line per swing, logged when its active window closes.
local function logSummary(s)
    if s.summaryLogged then return end
    s.summaryLogged = true
    local h, f = s.firstHit, s.lastFwd or { 0, 0, 0 }
    Log.Write(string.format("Swing: #%d result hit=%s%s fwd=(%.2f,%.2f,%.2f)",
        s.swingIndex, h and h.targetUuid or "NONE",
        h and string.format(" dist=%.2f", h.distance or 0)
          or string.format(" (characters nearby=%d)", #Aim.Characters()),
        f[1], f[2], f[3]))
end

local function startSwing(index)
    local def = longsword.chain[index]
    if not def then return end
    if State.currentSwing then logSummary(State.currentSwing) end
    local eye, fwd = Aim.ReadInvView()
    local t = nowMs()
    local cooldownS = MeleeCooldown.Seconds(longsword)
    -- Next swing allowed: the cooldown or the swing's own recovery, the later.
    local readyAt = t + math.max(cooldownS * 1000, def.windup_ms + def.active_ms + def.recovery_ms)
    State.currentSwing = {
        swingIndex    = index,
        nonce         = State.NextSwingNonce(),
        def           = def,
        startEye      = eye or { 0, 0, 0 },
        startForward  = fwd or { 0, 0, 1 },
        activeStart   = t + def.windup_ms,
        activeUntil   = t + def.windup_ms + def.active_ms,
        recoveryUntil = t + def.windup_ms + def.active_ms + def.recovery_ms,
        readyAt       = readyAt,
        chainResetAt  = math.max(t + def.windup_ms + def.active_ms, readyAt) + def.combo_ms,
        hitTargets    = {},
        sampling      = false,
    }
    Log.Write(string.format("Swing: start #%d (%s) damage=%.1f reach=%.1f cooldown=%.2fs",
        index, def.name, def.damage, def.reach_m, cooldownS))
    -- Play the animation (server-authoritative). The hit sampling is on
    -- our client ticks; the animation is cosmetic.
    -- fix3: real attack clip from the animation scan (Anims.lua). The old
    -- def.anim id was a looping combat idle and only made Gale twitch.
    -- Tags picked in the animation browser (swing1..3) win over the
    -- automatic picks from the Anims.lua scan.
    local tagged = Tags.ForPlayer("swing" .. index)
    local anim = tagged and tagged.key or Anims.ForSwing(index)
    if anim then
        local clipS = tagged and tagged.dur and tagged.dur > 0 and tagged.dur or nil
        ClientNet.PlayAnim(anim, clipS)
        -- The swing owns the body for its clip (or the data fallback): jump
        -- clips wait, the lift doesn't (Client/Combat/Actions.lua).
        local timingS = (def.windup_ms + def.active_ms + def.recovery_ms) / 1000
        local actS = math.max(clipS or airAction.swing_s, timingS)
        Actions.Begin("swing", actS)
        Log.Write(string.format("Swing: #%d anim %s clip=%s action=%.2fs%s", index, tostring(anim),
            clipS and string.format("%.2fs", clipS) or "?", actS, State.jumping and " (airborne)" or ""))
        if tagged and not State["tagLogged" .. index] then
            State["tagLogged" .. index] = true
            Log.Write(string.format("Swing: #%d uses tagged clip %s (%s)", index, tostring(tagged.file), tagged.key))
        end
    elseif not State.animWarned then
        State.animWarned = true
        Log.Write("Swing: no attack animation yet (Anims state=" .. tostring(Anims.State()) .. ")")
    end
end

-- 2026-10-09: a swing can't start before the previous one's recovery
-- ends (recovery_ms in the weapon data was never enforced, so LMB spam
-- restarted the animation every click). 2026-10-13: nor before the melee
-- cooldown ends (readyAt). One click in the last buffer_s is buffered and
-- fires the moment the next swing is allowed.
local buffered = false

local function advance()
    if chainExpired() then
        startSwing(1)
    else
        local s = State.currentSwing
        local next = (s.swingIndex % #longsword.chain) + 1
        -- Resetting after overhead:
        if s.swingIndex == #longsword.chain then
            startSwing(1)
        else
            startSwing(next)
        end
    end
end

function M.OnLMB()
    local s = State.currentSwing
    local now = nowMs()
    if s and now < s.readyAt then
        local left = s.readyAt - now
        if left <= MeleeCooldown.Buffer() * 1000 then
            if not buffered then
                buffered = true
                Log.Write(string.format("Swing: LMB buffered, swings in %d ms (melee cooldown)", math.floor(left)))
            end
        elseif not s.cooldownLogged then
            -- Once per swing: spam clicks would flood the log.
            s.cooldownLogged = true
            Log.Write(string.format("Swing: LMB ignored, melee cooldown %.2fs left", left / 1000))
        end
        return
    end
    advance()
end

local function tick()
    local s = State.currentSwing
    if not s then buffered = false; return end
    -- A BG3 panel opened: a click buffered before it must not fire later.
    if State.uiPaused and buffered then buffered = false; Log.Write("Swing: buffered LMB dropped (a BG3 panel opened)") end
    local now = nowMs()
    if buffered and now >= s.readyAt then
        buffered = false
        advance()
        s = State.currentSwing
        if not s then return end
    end
    if now >= s.activeStart and now < s.activeUntil then
        -- Sample every tick while active.
        sampleHit()
    elseif now >= s.activeUntil and not s.summaryLogged then
        logSummary(s)
    elseif now > s.chainResetAt then
        State.currentSwing = nil
    end
end

function M.Register()
    Anims.Register()
    Aim.Register()
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
    -- !dag_melee_cooldown <s>: here and on the server (HitValidator), which
    -- rejects hits from swings faster than its own value.
    ConsoleForward.Local("dag_melee_cooldown", function(_, v)
        MeleeCooldown.Set(v)
        Log.Write(string.format("Swing: melee cooldown %.2fs (longsword %.2fs; data/combat.lua melee.cooldown_s)",
            MeleeCooldown.Base(), MeleeCooldown.Seconds(longsword)))
    end)
    Log.Write(string.format("Swing: registered (longsword, %d swings, melee cooldown %.2fs)",
        #longsword.chain, MeleeCooldown.Seconds(longsword)))
end

return M
