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
local CastTags     = Ext.Require("Client/Combat/CastTags.lua")
local movement     = Ext.Require("data/movement.lua")
local spells       = Ext.Require("data/spells.lua")
local Me = Ext.Require("Client/Me.lua")   -- the local player's character (multiplayer)

local M = {}

local P = movement.prepare
local enabled = P.enabled ~= false

local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function player()
    local ok, ents = pcall(Me.All)
    return ok and ents and ents[1] or nil
end

local function instAddr(ent)
    local ok, inst = pcall(function() return ent.AnimationBlueprint.Instance end)
    return ok and inst and FullPov.AddrOf(inst) or nil
end

local cur = nil      -- { spell, anims, t0, castTime, ready, inst }
local guardUntil, guardInst = nil, nil

-- Weapon stance the arm asks the server for (data spell_anims.unsheath,
-- Server/Combat/SpellCast.lua): true when the prepare must wait for the
-- weapon to come out.
local function stance(ent)
    local ok, st = pcall(function() return ent.Unsheath.State end)
    local s = ok and tostring(st) or "?"
    return (s == "3") and "Sheathed" or s   -- StatsUnsheathState 3 = Sheathed
end

local function wantsDrawn(spell)
    local U = spells.spell_anims and spells.spell_anims.unsheath or {}
    if U.enabled == false then return false, 0 end
    local okS, st = pcall(Ext.Stats.Get, spell)
    local sh = okS and st and tostring(st.Sheathing or "") or ""
    return (U[sh ~= "" and sh or "default"] or U.default) == "unsheath", U.wait_s or 0
end

-- Send the select event (prepare, then the held loop), stretching the
-- prepare over what is left of the cast time.
local function begin(me)
    local c = cur
    c.begun = true
    -- Re-resolve now that the casting set (CastTags) is first, so the
    -- logged clip and its duration are the ones that will play.
    c.anims = SpellAnims.For(c.spell, me, true) or c.anims
    local left = math.max(c.castTime - (nowMs() - c.t0) / 1000, 0.1)
    local prep = c.anims.prepare
    local rate = (prep and prep.dur and prep.dur > 0) and (prep.dur / left) or 1.0
    if prep and c.inst then FullPov.SetClipRates(c.inst, { [prep.key] = rate }) end
    local ok, how = GenomeEvents.PlaySpell(me, c.anims)
    Log.Write(string.format("Prepare: start %s via %s (stance %s, casting set %s, after %.2fs) -> prepare %s (%.2fs clip at x%.2f = %.2fs left of %.2fs), loop %s, rig %s%s",
        c.spell, ok and how or ("FAILED: " .. tostring(how)), stance(me), CastTags.Ready(me) and "ready" or "NOT ready", (nowMs() - c.t0) / 1000, prep and prep.file or "none",
        prep and prep.dur or 0, rate, left, c.castTime, c.anims.loop and c.anims.loop.file or "none", c.anims.rig,
        c.anims.fallback and " [fallback anims]" or ""))
    SpellFx.Start(c.spell, me)
end

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
    local drawn, wait = wantsDrawn(spell)
    cur.wantsDrawn = drawn
    local nTags = CastTags.Apply(me)
    local ctWait = (spells.spell_anims and spells.spell_anims.cast_tags and spells.spell_anims.cast_tags.wait_s) or 0.5
    if nTags > 0 then wait = math.max(wait, ctWait) end
    if wait > 0 and not M.CanBegin(me) then
        cur.waitUntil = cur.t0 + wait * 1000
        Log.Write(string.format("Prepare: %s waits up to %.2fs (stance %s, casting set %s)", spell, wait, stance(me),
            CastTags.Ready(me) and "ready" or "pending"))
    else
        begin(me)
    end
end

-- The select event waits for the weapon (when the arm draws it) and for the
-- casting animation set.
function M.CanBegin(me)
    if cur and cur.wantsDrawn and stance(me) == "Sheathed" then return false end
    return CastTags.Ready(me)
end

-- reason: "cast" (release), "cancel-rmb", "cancel-key", "cast aborted", "re-arm".
function M.Stop(reason)
    if not cur then return end
    local c = cur
    cur = nil
    local me = player()
    if c.begun then SpellFx.Stop(reason) end
    if reason ~= "re-arm" then CastTags.Release(reason) end
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
        if reason ~= "re-arm" and me and c.begun then
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
    if cur and not cur.begun then
        local me = player()
        if me and (M.CanBegin(me) or nowMs() >= cur.waitUntil) then begin(me) end
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
    CastTags.Register()
    -- Debug: run our channel without POV / the hotbar, to compare it with
    -- vanilla from the normal camera. !dag_prepare_test [spell] | stop
    Ext.RegisterConsoleCommand("dag_prepare_test", function(_, a)
        if a == "stop" then M.Stop("cancel-key"); return end
        Log.Write("Prepare: TEST channel " .. (a or "Projectile_FireBolt") .. " (no POV; !dag_prepare_test stop to cancel)")
        M.Start(a or "Projectile_FireBolt")
    end)
    Ext.RegisterConsoleCommand("dag_prepare_anims", function(_, a)
        if a == "off" or a == "0" then enabled = false; M.Stop("cancel-key")
        elseif a == "on" or a == "1" then enabled = true end
        Log.Write("Prepare: spell channel animation " .. (enabled and "ON" or "OFF"))
    end)
end

return M
