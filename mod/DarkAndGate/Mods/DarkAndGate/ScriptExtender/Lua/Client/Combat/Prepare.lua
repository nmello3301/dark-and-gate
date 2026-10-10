-- SPDX-License-Identifier: GPL-3.0-or-later
-- Spell channel animation (docs/spikes/spell-anims.md, spell-anims-native.md).
--
-- Arming a spell (Hotbar.PressSlot) starts the channel: the spell's own
-- PREPARE plays, stretched to exactly the cast time (per-clip play rate in
-- the DLL, so the legs aren't sped up), then its LOOP holds until LMB
-- releases (Spells.Cast -> server UseSpell plays CAST + RECOVER) or RMB /
-- the same key cancels.
--
-- Path (2026-10-10, developer's choice): BG3's own spell animation event to
-- the animation blueprint (GenomeEvents.lua), not Osi.PlayAnimation, so
-- nothing roots the character: WASD (70% / 100%) and the jump keep working.
-- Full body: while walking the legs hold the cast pose (accepted).
-- Release guard: for release_guard_s after LMB, the spell's prepare / loop
-- clips are fast-forwarded (x guard_rate) in case the engine's UseSpell
-- replays them; logged by the DLL as "RATE: clip rates ...".
--
-- Prepare VFX + sounds (the spell's PrepareEffect / PrepareSound /
-- PrepareLoopSound) run alongside: SpellFx.lua.
-- The channel is an action (Actions.lua): the jump clips wait for it.
-- Commands: !dag_prepare_anims on|off.

local Log          = Ext.Require("Shared/Log.lua")
local Actions      = Ext.Require("Client/Combat/Actions.lua")
local State        = Ext.Require("Client/Combat/State.lua")
local FullPov      = Ext.Require("FullPov.lua")
local SpellAnims   = Ext.Require("Client/Combat/SpellAnims.lua")
local GenomeEvents = Ext.Require("Client/Combat/GenomeEvents.lua")
local SpellFx      = Ext.Require("Client/Combat/SpellFx.lua")
local movement     = Ext.Require("data/movement.lua")

local M = {}

local P = movement.prepare
local enabled = P.enabled ~= false

local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function player()
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    return ok and ents and ents[1] or nil
end

local function instAddr(ent)
    local ok, inst = pcall(function() return ent.AnimationBlueprint.Instance end)
    return ok and inst and FullPov.AddrOf(inst) or nil
end

local cur = nil      -- { spell, anims, t0, castTime, ready, inst }
local guardUntil, guardInst = nil, nil

function M.Start(spell)
    if cur then M.Stop("re-arm") end
    if not enabled then return end
    local me = player()
    if not me then return end
    local anims = SpellAnims.For(spell, me)
    if not anims then return end
    local castTime = State.armedCastTime or 2.0
    cur = { spell = spell, anims = anims, t0 = nowMs(), castTime = castTime, inst = instAddr(me) }
    Actions.Hold("prepare")
    -- Stretch the prepare to exactly the cast time.
    local prep = anims.prepare
    local rate = (prep and prep.dur and prep.dur > 0) and (prep.dur / castTime) or 1.0
    if prep and cur.inst then FullPov.SetClipRates(cur.inst, { [prep.key] = rate }) end
    local ok, how = GenomeEvents.PlaySpell(me, anims)
    Log.Write(string.format("Prepare: start %s via %s -> prepare %s (%.2fs clip at x%.2f = %.2fs cast time), loop %s, rig %s%s",
        spell, ok and how or ("FAILED: " .. tostring(how)), prep and prep.file or "none", prep and prep.dur or 0, rate, castTime,
        anims.loop and anims.loop.file or "none", anims.rig, anims.fallback and " [fallback anims]" or ""))
    SpellFx.Start(spell, me)
end

-- reason: "cast" (release), "cancel-rmb", "cancel-key", "cast aborted", "re-arm".
function M.Stop(reason)
    if not cur then return end
    local c = cur
    cur = nil
    local me = player()
    SpellFx.Stop(reason)
    if reason == "cast" then
        -- Guard: fast-forward the engine's own prepare / loop if UseSpell
        -- replays them; the cast and recover play at normal speed.
        local g = {}
        if c.anims.prepare then g[c.anims.prepare.key] = P.guard_rate end
        if c.anims.loop then g[c.anims.loop.key] = P.guard_rate end
        if c.inst then FullPov.SetClipRates(c.inst, g) end
        guardUntil, guardInst = nowMs() + P.release_guard_s * 1000, c.inst
    else
        if c.inst then FullPov.SetClipRates(c.inst, nil) end
        if reason ~= "re-arm" and me then
            local ok, how = GenomeEvents.Cancel(me, c.anims)
            Log.Write("Prepare: cancel via " .. (ok and how or ("none (" .. tostring(how) .. ")")))
        end
    end
    Actions.Release("prepare")
    Log.Write(string.format("Prepare: stop %s (%s) after %.2fs%s", c.spell, reason, (nowMs() - c.t0) / 1000,
        c.ready and " (was READY)" or ""))
end

function M.Active() return cur ~= nil end

local function tick()
    if guardUntil and nowMs() >= guardUntil then
        guardUntil = nil
        if guardInst then FullPov.SetClipRates(guardInst, nil) end
        Log.Write("Prepare: release guard over (clip rates cleared)")
    end
    if cur and not cur.ready and nowMs() - cur.t0 >= cur.castTime * 1000 then
        cur.ready = true
        Log.Write(string.format("Prepare: %s READY after %.2fs -> loop %s", cur.spell, (nowMs() - cur.t0) / 1000,
            cur.anims.loop and cur.anims.loop.file or "none"))
    end
end

function M.Register()
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
    GenomeEvents.Register()
    SpellFx.Register()
    Ext.RegisterConsoleCommand("dag_prepare_anims", function(_, a)
        if a == "off" or a == "0" then enabled = false; M.Stop("cancel-key")
        elseif a == "on" or a == "1" then enabled = true end
        Log.Write("Prepare: spell channel animation " .. (enabled and "ON" or "OFF"))
    end)
end

return M
