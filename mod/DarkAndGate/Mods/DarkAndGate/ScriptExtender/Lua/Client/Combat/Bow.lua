-- SPDX-License-Identifier: GPL-3.0-or-later
-- Bows and crossbows, client side (DECISIONS 2026-10-12, data/bows.lua,
-- docs/design/projectiles.md). Server side: Server/Combat/Bows.lua.
--
-- With the ranged weapon set active (Q switches melee / ranged; the server's
-- RangedState says what is in the ranged slot):
--   bow       LMB down = draw. BG3's own ranged-attack draw (slot 0 of
--             Projectile_MainHandAttack's SpellAnimation, resolved for the
--             bow in hand) is stretched to the draw time with the DLL's
--             per-clip rate, then its aim loop holds as long as you like
--             (full draw holds forever). The amber ring around the crosshair
--             fills; you walk at drawing_speed_mult.
--             LMB up = release along the crosshair line (the arrow drops);
--             below min_draw the draw is cancelled. RMB cancels.
--   crossbow  LMB = shoot at full power when loaded; R (or LMB when empty)
--             reloads for reload_s (the ring fills); then it shoots at once.
-- On the body: BG3's Prepare brings the bow up, then its Antic (the pull to
-- full draw, which vanilla only plays at the shot) is stretched over the rest
-- of the draw and held at full draw until the release (data/bows.lua).
-- Q: BG3's own "toggle weapon set" key is pressed for you (it is F, which is
-- ours in first person, so that one press is let through); the server
-- checks a moment later and switches the set itself if it didn't change.
-- Other characters' draws (NPC / companion archers, co-op players): BowAnim
-- from the server plays the same clips on that character, stretched through
-- the DLL's multi-character clip rates (FullPov.SetNpcClipRates).

local Log          = Ext.Require("Shared/Log.lua")
local Net          = Ext.Require("Shared/Net.lua")
local ClientNet    = Ext.Require("Client/Net.lua")
local State        = Ext.Require("Client/Combat/State.lua")
local Aim          = Ext.Require("Client/Combat/Aim.lua")
local Actions      = Ext.Require("Client/Combat/Actions.lua")
local SpellAnims   = Ext.Require("Client/Combat/SpellAnims.lua")
local GenomeEvents = Ext.Require("Client/Combat/GenomeEvents.lua")
local FullPov      = Ext.Require("FullPov.lua")
local Hud          = Ext.Require("Client/HUD/Hud.lua")
local Movement     = Ext.Require("Client/Movement/Movement.lua")
local TickBudget   = Ext.Require("Shared/TickBudget.lua")
local cfg          = Ext.Require("data/bows.lua")
local spells       = Ext.Require("data/spells.lua")
local airAction    = Ext.Require("data/movement.lua").air_action
local Me = Ext.Require("Client/Me.lua")   -- the local player's character (multiplayer)

local M = {}

local ARROW = cfg.arrow_spell
M.TOGGLE_KEY = cfg.weapon_set.key
M.RELOAD_KEY = cfg.reload_key or "R"

local states = {}            -- uuid -> RangedState from the server
local draw = nil             -- { t0, drawS, inst, anims, begun, waitUntil, full }
local reloadUntil, reloadS = 0, 0
local loaded = true          -- the crossbow has a bolt in
local recoverUntil = 0
local guardUntil, guardInst = nil, nil
local hudOwned = false
local passUntil = 0          -- ms: the toggle key goes to BG3 until then
local others = {}            -- uuid -> { ent, anims, inst, rates, untilAt }
local loggedNoClips = {}

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function player()
    local ok, ents = pcall(Me.All)
    return ok and ents and ents[1] or nil
end

local function instAddr(ent)
    local ok, inst = pcall(function() return ent.AnimationBlueprint.Instance end)
    return ok and inst and FullPov.AddrOf(inst) or nil
end

-- The weapon set as this client sees it (nil when the component can't be read).
local function localSet(ent)
    ent = ent or player()
    if not ent then return nil end
    local ok, s = pcall(function() return tostring(ent.WeaponSet.WeaponSet) end)
    return (ok and s and s ~= "nil") and s or nil
end

-- The bow is out (not on the back)?
local function bowOut(ent)
    local ok, st = pcall(function() return tostring(ent.Unsheath.State) end)
    return ok and (st == "Ranged" or st == "2")
end

local function myState() return states[Aim.SelfUuid() or ""] end

-- The draw on the body over drawS seconds from t0 (ms): the clips for
-- GenomeEvents.PlaySpell (Prepare = the raise, Antic = the held pull), their
-- rates now, and the hold step { at, key, rate } that freezes the pull at
-- full draw. Without an Antic: the old stretched prepare + aim loop.
local function drawPlan(anims, drawS, t0)
    local prep, pull = anims.prepare, anims.antic
    local rates, step = {}, nil
    local play = { prepare = prep, loop = pull or anims.loop, slot6 = anims.slot6 }
    local tPrep = 0
    if pull and pull.dur and pull.dur > 0 then
        if prep and prep.dur and prep.dur > 0 then
            local rr = cfg.raise_rate or 1.0
            tPrep = prep.dur / rr
            local cap = drawS * (cfg.raise_max_frac or 0.5)
            if tPrep > cap then rr, tPrep = prep.dur / cap, cap end
            rates[prep.key] = rr
        end
        rates[pull.key] = pull.dur * (cfg.pull_hold_frac or 0.85) / math.max(0.1, drawS - tPrep)
        step = { at = t0 + drawS * 1000, key = pull.key, rate = cfg.hold_rate or 0.002 }
    elseif prep and prep.dur and prep.dur > 0 then
        rates[prep.key] = prep.dur / math.max(0.1, drawS)
    end
    return play, rates, step, tPrep
end

-- Right after the release: a replayed raise runs fast; the pull stays held
-- until the shot's own release clip takes over (no snap back to the bow down).
local function guardRates(anims)
    local g = {}
    if anims.prepare then g[anims.prepare.key] = cfg.guard_rate end
    if anims.antic then g[anims.antic.key] = cfg.hold_rate or 0.002
    elseif anims.loop then g[anims.loop.key] = cfg.guard_rate end
    return g
end

local function planText(anims, rates, step, tPrep, drawS)
    local prep, pull = anims.prepare, anims.antic
    if pull then
        return string.format("raise %s (%.2fs at x%.2f), pull %s (%.2fs at x%.2f over %.2fs, held from %.1fs)",
            prep and prep.file or "none", prep and prep.dur or 0, prep and rates[prep.key] or 1,
            pull.file, pull.dur or 0, rates[pull.key] or 1, drawS - tPrep, drawS)
    end
    return string.format("draw clip %s (%.2fs at x%.2f), aim loop %s [no pull clip]", prep and prep.file or "none",
        prep and prep.dur or 0, prep and rates[prep.key] or 1, anims.loop and anims.loop.file or "none")
end

-- "bow" | "crossbow" | nil: what LMB does right now.
function M.Mode()
    local st = myState()
    if not st or not st.kind then return nil end
    local set = localSet() or st.set
    if set ~= "Ranged" then return nil end
    return st.kind
end

function M.Drawing() return draw ~= nil end

-- ---------------------------------------------------------------------
-- Other characters' draws (BowAnim)
-- ---------------------------------------------------------------------
local function pushRates()
    local list = {}
    for _, o in pairs(others) do
        if o.inst then
            for id, r in pairs(o.rates) do list[#list + 1] = { inst = o.inst, id = id, rate = r } end
        end
    end
    FullPov.SetNpcClipRates(list)
end

local function endOther(uuid, why, lower)
    local o = others[uuid]
    if not o then return end
    others[uuid] = nil
    if lower and o.anims then pcall(GenomeEvents.Cancel, o.ent, o.anims) end
    pushRates()
    Log.Write(string.format("Bow: %s's draw ends (%s)", tostring(uuid), why))
end

local function startOther(uuid, drawS)
    local ok, ent = pcall(Ext.Entity.Get, uuid)
    if not ok or not ent then return end
    local anims = SpellAnims.For(ARROW, ent, true)
    if not anims or not (anims.prepare or anims.loop) then
        if not loggedNoClips[uuid] then
            loggedNoClips[uuid] = true
            Log.Write("Bow: no draw clips resolve for " .. tostring(uuid) .. " (its bow isn't out?): its draw shows no animation")
        end
        return
    end
    local o = { ent = ent, anims = anims, inst = instAddr(ent), rates = {}, untilAt = now() + (drawS + 3) * 1000 }
    local play, rates, step, tPrep = drawPlan(anims, math.max(0.1, drawS), now())
    o.rates, o.step = rates, step
    others[uuid] = o
    pushRates()
    local okP, how = GenomeEvents.PlaySpell(ent, play)
    Log.Write(string.format("Bow: %s draws %.1fs: %s, via %s%s", tostring(uuid), drawS,
        planText(anims, rates, step, tPrep, drawS), okP and how or ("FAILED: " .. tostring(how)),
        o.inst and "" or " (no animation instance: native speed)"))
end

local function releaseOther(uuid)
    local o = others[uuid]
    if not o then return end
    -- The engine's own draw / aim, if it replays them before the release clip, run fast.
    o.rates = guardRates(o.anims)
    o.step = nil
    o.untilAt = now() + cfg.release_guard_s * 1000
    pushRates()
end

-- ---------------------------------------------------------------------
-- My draw
-- ---------------------------------------------------------------------
local function begin(me)
    local d = draw
    d.begun = true
    d.anims = SpellAnims.For(ARROW, me, true)
    if not d.anims or not (d.anims.prepare or d.anims.loop) then
        Log.Write("Bow: no draw clips resolve for your bow (is it out?): drawing without the animation")
        return
    end
    local left = math.max(d.drawS - (now() - d.t0) / 1000, 0.1)
    local play, rates, step, tPrep = drawPlan(d.anims, left, now())
    d.step = step
    if d.inst then FullPov.SetClipRates(d.inst, rates) end
    local ok, how = GenomeEvents.PlaySpell(me, play)
    Log.Write(string.format("Bow: draw %.2fs left of %.1fs: %s, via %s%s", left, d.drawS, planText(d.anims, rates, step, tPrep, left),
        ok and how or ("FAILED: " .. tostring(how)), d.anims.fallback and " [fallback clips]" or ""))
end

local function stopDraw()
    draw = nil
    Actions.Release("bow")
end

-- Lower the bow of draw `d` (already stopped) and tell the server.
local function lower(d, why)
    local me = player()
    if d.inst then FullPov.SetClipRates(d.inst, nil) end
    if me and d.begun and d.anims then pcall(GenomeEvents.Cancel, me, d.anims) end
    ClientNet.Send(Net.Channels.BowDraw, { on = false, why = why })
    Log.Write(string.format("Bow: draw cancelled after %.2fs (%s)", (now() - d.t0) / 1000, tostring(why)))
end

-- Cancel my draw (RMB, too early, a spell, a panel...): the bow is lowered.
function M.Cancel(why)
    local d = draw
    if not d then return end
    stopDraw()
    lower(d, why)
end

local function shoot(f, d)
    -- Arrows reach data/spells.lua shot_range_m (70 m; the flight ends there too).
    local aim = Aim.SpellAim(spells.shot_range_m or 70)
    if not aim then
        Log.Write("Bow: camera not readable, no shot")
        if d then lower(d, "no aim") end
        return false
    end
    local p = aim.pos
    ClientNet.Send(Net.Channels.BowRelease, {
        draw = f, targetUuid = aim.target,
        eye = { x = aim.eye[1], y = aim.eye[2], z = aim.eye[3] },
        dir = { x = aim.fwd[1], y = aim.fwd[2], z = aim.fwd[3] },
        hitPoint = { x = p[1], y = p[2], z = p[3] },
    })
    if d and d.anims and d.inst then
        FullPov.SetClipRates(d.inst, guardRates(d.anims))
        guardUntil, guardInst = now() + cfg.release_guard_s * 1000, d.inst
    end
    Actions.Begin("cast", airAction.cast_s)
    Log.Write(string.format("Bow: release at %.0f %% -> %s %.1f m (%s)%s", f * 100, aim.via, aim.distance or 0,
        string.format("(%.2f,%.2f,%.2f)", p[1], p[2], p[3]), aim.target and (" target " .. aim.target) or ""))
    return true
end

-- LMB down. True when the bow / crossbow took it.
function M.OnPress()
    local kind = M.Mode()
    if not kind then return false end
    local t = now()
    local st = myState() or {}
    if kind == "crossbow" then
        if t < reloadUntil then
            Log.Write(string.format("Bow: crossbow still reloading (%.1fs left)", (reloadUntil - t) / 1000))
            return true
        end
        if not loaded then M.Reload(); return true end
        if shoot(1.0, nil) then loaded = false end
        return true
    end
    if draw then return true end
    if t < recoverUntil then return true end
    local me = player()
    if not me then return true end
    draw = { t0 = t, drawS = tonumber(st.drawS) or cfg.draw_s, inst = instAddr(me), waitUntil = t + 400 }
    Actions.Hold("bow")
    ClientNet.Send(Net.Channels.BowDraw, { on = true })
    Log.Write(string.format("Bow: LMB -> draw (%s, %.1f s to full; bow %s)", tostring(st.family), draw.drawS, bowOut(me) and "out" or "on the back"))
    if bowOut(me) then begin(me) end
    return true
end

-- R: reload the crossbow (reload_s), after which LMB shoots at once.
function M.Reload()
    if M.Mode() ~= "crossbow" then return end
    local t = now()
    if loaded then Log.Write("Bow: the crossbow is already loaded"); return end
    if t < reloadUntil then return end
    local st = myState() or {}
    reloadS = tonumber(st.reloadS) or 1.5
    reloadUntil = t + reloadS * 1000
    ClientNet.Send(Net.Channels.BowDraw, { reload = true })
    Log.Write(string.format("Bow: reloading the %s (%.1f s)", tostring(st.family), reloadS))
end

-- LMB up: release (or cancel below min_draw). True when a draw was running.
function M.OnRelease()
    local d = draw
    if not d then return false end
    local f = math.min(1, (now() - d.t0) / 1000 / d.drawS)
    if f < cfg.min_draw then
        M.Cancel(string.format("let go at %.0f %%, below %.0f %%", f * 100, cfg.min_draw * 100))
        return true
    end
    stopDraw()
    recoverUntil = now() + cfg.recover_s * 1000
    shoot(f, d)
    return true
end

-- ---------------------------------------------------------------------
-- Q: melee <-> ranged
-- ---------------------------------------------------------------------
function M.ToggleSet()
    if draw then M.Cancel("weapon set switch") end
    local st = myState()
    local from = localSet() or (st and st.set) or "?"
    passUntil = now() + 500
    local ok, err = pcall(function() Ext.Input.InjectKeyPress(cfg.weapon_set.toggle_key) end)
    ClientNet.Send(Net.Channels.WeaponSetToggle, { from = from, injected = ok })
    Log.Write(string.format("Bow: Q -> BG3's weapon set toggle (key %s pressed%s), set was %s", cfg.weapon_set.toggle_key,
        ok and "" or (" -- FAILED: " .. tostring(err)), from))
end

-- Input.lua: let this key through to BG3 (Q's toggle press)?
function M.PassKey(key, evt)
    if key ~= cfg.weapon_set.toggle_key or now() > passUntil then return false end
    if evt == "KeyUp" then passUntil = 0 end
    return true
end

-- ---------------------------------------------------------------------
-- Tick
-- ---------------------------------------------------------------------
local function setHud(v)
    if v == nil then
        if hudOwned then hudOwned = false; Hud.SetBowDraw(nil) end
        return
    end
    hudOwned = true
    Hud.SetBowDraw(v)
end

local function tick()
    local t = now()
    if draw then
        if not State.IsCombatActive() or State.uiPaused or State.downed then M.Cancel("first person paused")
        elseif State.armedSpell then M.Cancel("a spell was armed")
        elseif M.Mode() ~= "bow" then M.Cancel("no bow in hand any more")
        end
    end
    if draw then
        if not draw.begun then
            local me = player()
            if me and (bowOut(me) or t >= draw.waitUntil) then begin(me) end
        end
        if draw.step and t >= draw.step.at then
            if draw.inst then FullPov.SetClipRates(draw.inst, { [draw.step.key] = draw.step.rate }) end
            draw.step = nil
        end
        local f = math.min(1, (t - draw.t0) / 1000 / draw.drawS)
        setHud(f)
        if f >= 1 and not draw.full then
            draw.full = true
            Log.Write(string.format("Bow: full draw after %.2fs (holds until you let go)", (t - draw.t0) / 1000))
        end
    elseif t < reloadUntil and reloadS > 0 then
        setHud(1 - (reloadUntil - t) / (reloadS * 1000))
    elseif reloadUntil > 0 then
        reloadUntil = 0
        loaded = true
        setHud(nil)
        Log.Write("Bow: crossbow loaded")
    else
        setHud(nil)
    end
    if guardUntil and t >= guardUntil then
        guardUntil = nil
        if guardInst and not draw then FullPov.SetClipRates(guardInst, nil) end
        guardInst = nil
    end
    for u, o in pairs(others) do
        if t > o.untilAt then endOther(u, "done", false)
        elseif o.step and t >= o.step.at then
            o.rates[o.step.key] = o.step.rate
            o.step = nil
            pushRates()
        end
    end
end

function M.Register()
    Ext.RegisterNetListener(Net.Channels.RangedState, function(_, payload)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" or not p.uuid then return end
        local old = states[p.uuid]
        states[p.uuid] = p
        if p.uuid == Aim.SelfUuid() and old and old.family ~= p.family then loaded, reloadUntil = true, 0 end
        if p.uuid == Aim.SelfUuid() and (not old or old.set ~= p.set or old.kind ~= p.kind) then
            Log.Write(string.format("Bow: weapon set %s, ranged weapon %s%s", tostring(p.set), tostring(p.family or "none"),
                p.kind and (" (" .. p.kind .. ")") or ""))
        end
    end)
    Ext.RegisterNetListener(Net.Channels.BowAnim, function(_, payload)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" or not p.uuid or p.uuid == Aim.SelfUuid() then return end
        if p.phase == "draw" then startOther(p.uuid, tonumber(p.drawS) or cfg.draw_s)
        elseif p.phase == "release" then releaseOther(p.uuid)
        else endOther(p.uuid, "cancelled", true) end
    end)
    Movement.AddModifier("drawing", function()
        return (draw and not State.jumping) and (cfg.drawing_speed_mult or 1.0) or 1.0
    end)
    Ext.Events.Tick:Subscribe(TickBudget.Wrap("Bow", tick))
    Log.Write(string.format("Bow: registered (bows: hold LMB %.1f s, no shot below %.0f %%; crossbows: click + reload; %s = melee / ranged)",
        cfg.draw_s, cfg.min_draw * 100, cfg.weapon_set.key))
end

return M
