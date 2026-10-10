-- SPDX-License-Identifier: GPL-3.0-or-later
-- Spell prepare loop while a hotbar spell is armed (arm-then-cast).
--
-- Arming a spell (Hotbar.PressSlot) plays that spell's own prepare clip on
-- the player, then keeps its loop clip going until LMB casts or RMB / the
-- same key cancels. Cancel stops our clip on the server ("__stop__"), which
-- returns the body to idle or locomotion; a cast hands over to the engine's
-- own cast animation (the server clears our clip before UseSpell).
--
-- Clip ids come from the spell's stats, SpellAnimation (9 slots of
-- "mappingId,,"; slot 0 = prepare, slot 1 = prepare loop, slot 2 = cast).
-- Every slot is logged once per spell ("Prepare: <spell> SpellAnimation ...")
-- so the slot order can be checked against what plays. Durations come from
-- the player's own AnimationSet (mapping id -> Animation resource).
--
-- The prepare loop is an action (Client/Combat/Actions.lua): armed in the
-- air, it suspends the jump clips like a swing does.
--
-- Commands: !dag_prepare_anims on|off, !dag_prepare_info <spell>.

local Log       = Ext.Require("Shared/Log.lua")
local ClientNet = Ext.Require("Client/Net.lua")
local Actions   = Ext.Require("Client/Combat/Actions.lua")
local movement  = Ext.Require("data/movement.lua")

local M = {}

local P = movement.prepare
local enabled = P.enabled ~= false

local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function player()
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    return ok and ents and ents[1] or nil
end

local function isGuid(x)
    return type(x) == "string" and x:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

-- First GUID in a value that may be a string, an array or nested arrays.
local function firstGuid(v, depth)
    depth = depth or 0
    if v == nil or depth > 3 then return nil end
    if type(v) == "string" then
        for part in v:gmatch("[^,;%s]+") do if isGuid(part) then return part end end
        return nil
    end
    local okI, r = pcall(function()
        for _, x in ipairs(v) do
            local g = firstGuid(x, depth + 1)
            if g then return g end
        end
        return nil
    end)
    if okI and r then return r end
    local okS, str = pcall(tostring, v)
    if okS and str then
        for part in str:gmatch("[^,;%s%[%]\"]+") do if isGuid(part) then return part end end
    end
    return nil
end

-- slots[0..8] = first mapping id of each SpellAnimation slot (or nil).
local function spellSlots(spell)
    local slots, src = {}, nil
    -- 1) The stat entry's SpellAnimation (string "id,,;id,,;..." or a table).
    local okS, st = pcall(Ext.Stats.Get, spell)
    if okS and st then
        local okA, raw = pcall(function() return st.SpellAnimation end)
        if okA and raw ~= nil then
            if type(raw) == "string" then
                local i = 0
                for group in (raw .. ";"):gmatch("([^;]*);") do
                    slots[i] = firstGuid(group); i = i + 1
                end
                src = "stats string"
            else
                pcall(function()
                    for i, group in ipairs(raw) do slots[i - 1] = firstGuid(group) end
                end)
                src = "stats table"
            end
        end
    end
    -- 2) The cached spell prototype (Part0..Part8).
    local any = false
    for i = 0, 8 do if slots[i] then any = true end end
    if not any then
        local okC, proto = pcall(Ext.Stats.GetCachedSpell, spell)
        if okC and proto then
            pcall(function()
                local a = proto.SpellAnimation
                for i = 0, 8 do slots[i] = firstGuid(a["Part" .. i]) end
            end)
            src = "spell prototype"
        end
    end
    return slots, src or "none"
end

-- Mapping id -> clip length for the player (first AnimationSet that maps it).
local durCache = {}
local function clipDur(ent, mapping)
    if not mapping then return nil end
    if durCache[mapping] ~= nil then return durCache[mapping] or nil end
    local d = false
    pcall(function()
        for _, e in ipairs(ent.AnimationSet.Entries) do
            local okR, res = pcall(Ext.Resource.Get, tostring(e.Resource), "AnimationSet")
            if okR and res then
                for _, sub in pairs(res.AnimationBank.AnimationSubSets) do
                    local okD, desc = pcall(function() return sub.Animation[mapping] end)
                    if okD and desc then
                        local okA, ar = pcall(Ext.Resource.Get, tostring(desc.ID), "Animation")
                        if okA and ar then d = tonumber(ar.Duration) or false end
                        if d then return end
                    end
                end
            end
            if d then return end
        end
    end)
    durCache[mapping] = d
    return d or nil
end

local info = {}   -- spell -> { prepare = {key,dur}, loop = {key,dur} } | false
local function infoFor(spell, ent)
    if info[spell] ~= nil then return info[spell] or nil end
    local slots, src = spellSlots(spell)
    local parts = {}
    for i = 0, 8 do parts[#parts + 1] = string.format("%d=%s", i, slots[i] or "-") end
    Log.Write(string.format("Prepare: %s SpellAnimation (%s) %s", spell, src, table.concat(parts, " ")))
    local r = {}
    if slots[0] then r.prepare = { key = slots[0], dur = clipDur(ent, slots[0]) } end
    if slots[1] then r.loop = { key = slots[1], dur = clipDur(ent, slots[1]), from = "spell" } end
    if not r.loop and P.loop_fallback then
        r.loop = { key = P.loop_fallback, dur = clipDur(ent, P.loop_fallback), from = "data fallback" }
    end
    Log.Write(string.format("Prepare: %s prepare=%s (%s) loop=%s (%s, %s)", spell,
        r.prepare and r.prepare.key or "none", r.prepare and r.prepare.dur and string.format("%.2fs", r.prepare.dur) or "?",
        r.loop and r.loop.key or "none", r.loop and r.loop.dur and string.format("%.2fs", r.loop.dur) or "?",
        r.loop and r.loop.from or "hold after prepare"))
    if not r.prepare and not r.loop then r = false end
    info[spell] = r
    return r or nil
end

local cur = nil   -- { spell, i, phase, nextAt, t0, loops }

local function playClip(c, label)
    ClientNet.PlayAnim(c.key, c.dur)
    if cur then cur.phase = label end
end

function M.Start(spell)
    if cur then M.Stop("re-arm") end
    if not enabled then return end
    local me = player()
    if not me then return end
    local i = infoFor(spell, me)
    if not i then
        Log.Write("Prepare: " .. spell .. " has no prepare / loop clip -- nothing plays while armed")
        return
    end
    local t = nowMs()
    cur = { spell = spell, i = i, t0 = t, loops = 0 }
    Actions.Hold("prepare")
    local first = i.prepare or i.loop
    playClip(first, i.prepare and "prepare" or "loop")
    local d = first.dur or P.unknown_dur_s
    cur.nextAt = t + math.max(0.1, d - P.refresh_margin_s) * 1000
    Log.Write(string.format("Prepare: start %s -> %s %s (%s)", spell, cur.phase, first.key,
        first.dur and string.format("%.2fs", first.dur) or string.format("length unknown, assuming %.2fs", d)))
end

-- reason: "cast" (the engine's cast clip takes over), "cancel-rmb",
-- "cancel-key", "re-arm".
function M.Stop(reason)
    if not cur then return end
    local c = cur
    cur = nil
    if reason ~= "cast" and reason ~= "re-arm" then ClientNet.PlayAnim("__stop__") end
    Actions.Release("prepare")
    Log.Write(string.format("Prepare: stop %s (%s) after %.2fs, %d loop plays", c.spell, reason,
        (nowMs() - c.t0) / 1000, c.loops))
end

function M.Active() return cur ~= nil end

local function tick()
    if not cur or not cur.nextAt then return end
    local t = nowMs()
    if t < cur.nextAt then return end
    local l = cur.i.loop
    if not l then
        cur.nextAt = nil
        Log.Write("Prepare: " .. cur.spell .. " holds after the prepare clip (no loop clip)")
        return
    end
    playClip(l, "loop")
    cur.loops = cur.loops + 1
    if cur.loops == 1 then
        Log.Write(string.format("Prepare: %s loop %s (%s)", cur.spell, l.key, l.dur and string.format("%.2fs", l.dur) or "?"))
    end
    cur.nextAt = t + math.max(0.1, (l.dur or P.unknown_dur_s) - P.refresh_margin_s) * 1000
end

function M.Register()
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
    Ext.RegisterConsoleCommand("dag_prepare_anims", function(_, a)
        if a == "off" or a == "0" then enabled = false; M.Stop("cancel-key")
        elseif a == "on" or a == "1" then enabled = true end
        Log.Write("Prepare: spell prepare loop " .. (enabled and "ON" or "OFF"))
    end)
    Ext.RegisterConsoleCommand("dag_prepare_info", function(_, spell)
        spell = spell or "Projectile_FireBolt"
        info[spell] = nil
        local me = player()
        if me then infoFor(spell, me) end
    end)
end

return M
