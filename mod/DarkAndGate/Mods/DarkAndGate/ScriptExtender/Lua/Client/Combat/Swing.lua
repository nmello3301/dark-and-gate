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

local Log       = Ext.Require("Shared/Log.lua")
local Net       = Ext.Require("Shared/Net.lua")
local State     = Ext.Require("Client/Combat/State.lua")
local Aim       = Ext.Require("Client/Combat/Aim.lua")
local longsword = Ext.Require("data/weapons/longsword.lua")
local ClientNet = Ext.Require("Client/Net.lua")

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
    local hit = Aim.FanClosestCharacter(
        eye, fwd, s.def.reach_m, s.def.arc_deg_h, 0, s.def.arc_rays, 0.3)
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
        local zone = Aim.ClassifyZone(hit.targetUuid, hit.pos[2])
        sendHitClaim(s.def, hit.targetUuid, hit.pos, zone)
    end
end

local function startSwing(index)
    local def = longsword.chain[index]
    if not def then return end
    local eye, fwd = Aim.ReadInvView()
    State.currentSwing = {
        swingIndex    = index,
        nonce         = State.NextSwingNonce(),
        def           = def,
        startEye      = eye or { 0, 0, 0 },
        startForward  = fwd or { 0, 0, 1 },
        activeStart   = nowMs() + def.windup_ms,
        activeUntil   = nowMs() + def.windup_ms + def.active_ms,
        recoveryUntil = nowMs() + def.windup_ms + def.active_ms + def.recovery_ms,
        chainResetAt  = nowMs() + def.windup_ms + def.active_ms + def.combo_ms,
        hitTargets    = {},
        sampling      = false,
    }
    Log.Write(string.format("Swing: start #%d (%s) damage=%.1f reach=%.1f",
        index, def.name, def.damage, def.reach_m))
    -- Play the animation (server-authoritative). The hit sampling is on
    -- our client ticks; the animation is cosmetic.
    ClientNet.PlayAnim(def.anim)
end

function M.OnLMB()
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

local function tick()
    local s = State.currentSwing
    if not s then return end
    local now = nowMs()
    if now >= s.activeStart and now < s.activeUntil then
        -- Sample every tick while active.
        sampleHit()
    elseif now > s.chainResetAt then
        State.currentSwing = nil
    end
end

function M.Register()
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
    Log.Write("Swing: registered (longsword, " .. #longsword.chain .. " swings)")
end

return M
