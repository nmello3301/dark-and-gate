-- SPDX-License-Identifier: GPL-3.0-or-later
-- Prepare VFX + sounds while channelling a spell (docs/spikes/spell-fx.md).
--
-- The genome select event (GenomeEvents.lua) plays only the animation. The
-- hand fire and the prepare sounds are separate spell stats that vanilla's
-- targeting mode plays on its own:
--   PrepareEffect     multi-effect resource, started through BG3's client
--                     effect system (Ext.System.ClientEffectHandler:
--                     InitMultiEffect, SE Components/Effect.h) on the caster
--   PrepareSound      Wwise event, posted once on the caster
--   PrepareLoopSound  Wwise event, posted once; loops until stopped
-- At cast / cancel the effect is destroyed and, with fx.stop_sounds, the
-- caster's sound object is stopped (Ext.Audio.Stop). The engine's own cast
-- effect / sound then play from UseSpell as before.
-- Local only for now: other players don't see / hear the prepare (MP later).
--
--   !dag_spell_fx_watch on|off   read-only: log every client effect the
--                                game creates / removes on the player
--                                (vanilla reference for the init info)

local Log    = Ext.Require("Shared/Log.lua")
local spells = Ext.Require("data/spells.lua")

local M = {}

local FX = (spells.spell_anims and spells.spell_anims.fx) or {}
local HAS_ENTITY = 1   -- ProvidedMultiEffectObjectFlags.HasEntity

local cur = nil   -- { spell, ent, effect, sounds }

local function hex(h)
    local ok, n = pcall(Ext.Utils.HandleToInteger, h)
    return ok and n and string.format("0x%016X", n) or "nil"
end

local function stat(spell, field)
    local ok, v = pcall(function() return Ext.Stats.Get(spell)[field] end)
    if ok and type(v) == "string" and v ~= "" then return v end
    return nil
end

function M.Start(spell, ent)
    if cur then M.Stop("re-arm") end
    if not spell or not ent then return end
    local effectId = stat(spell, "PrepareEffect")
    local bone = stat(spell, "PrepareEffectBone")
    local snd, loop = stat(spell, "PrepareSound"), stat(spell, "PrepareLoopSound")
    cur = { spell = spell, ent = ent }
    local parts = {}
    if FX.effect ~= false and effectId then
        local ok, h = pcall(function()
            return Ext.System.ClientEffectHandler:InitMultiEffect({
                EventProviderEntity = ent,
                Player = ent,
                SourceEffect = { Entity = ent, Flags = HAS_ENTITY },
                TargetEffect = { Entity = ent, Flags = HAS_ENTITY },
                MultiEffectDefinition = effectId,
                WeaponBones = bone or "",
                FXScale = 1.0,
            })
        end)
        if ok and h then cur.effect = h end
        parts[#parts + 1] = string.format("effect %s%s -> %s", effectId:sub(1, 8), bone and (" bone " .. bone) or "",
            ok and hex(h) or ("ERROR " .. tostring(h)))
    else
        parts[#parts + 1] = "effect none"
    end
    if FX.sounds ~= false then
        for _, ev in ipairs({ snd, loop }) do
            local ok, r = pcall(Ext.Audio.PostEvent, ent, ev)
            parts[#parts + 1] = string.format("sound %s -> %s", ev, ok and tostring(r) or ("ERROR " .. tostring(r)))
            if ok and r then cur.sounds = true end
        end
    end
    if not snd and not loop then parts[#parts + 1] = "sounds none" end
    Log.Write("SpellFx: start " .. spell .. ": " .. table.concat(parts, ", "))
end

-- reason as in Prepare.Stop.
function M.Stop(reason)
    if not cur then return end
    local c = cur
    cur = nil
    local parts = {}
    if c.effect then
        local ok, r = pcall(function() return Ext.System.ClientEffectHandler:DestroyMultiEffect(c.effect) end)
        parts[#parts + 1] = "effect destroyed " .. (ok and tostring(r) or ("ERROR " .. tostring(r)))
    end
    if c.sounds and FX.stop_sounds ~= false then
        local ok, err = pcall(Ext.Audio.Stop, c.ent)
        parts[#parts + 1] = "sounds stopped " .. (ok and "ok" or ("ERROR " .. tostring(err)))
    end
    Log.Write(string.format("SpellFx: stop %s (%s) %s", c.spell, reason, table.concat(parts, ", ")))
end

-- Watcher (read-only): every client effect handler whose source, target or
-- event provider is the player, logged when it appears and disappears.
local watching, known = false, {}
local knownDefs = nil

local function defName(def)
    if not knownDefs then
        knownDefs = {}
        for _, s in ipairs({ "Projectile_FireBolt", "Projectile_Fireball", "Target_MistyStep" }) do
            for _, f in ipairs({ "PrepareEffect", "CastEffect", "TargetEffect", "HitEffect", "PreviewEffect" }) do
                local v = stat(s, f)
                if v then knownDefs[v] = s .. "." .. f end
            end
        end
    end
    return knownDefs[def] or "?"
end

local function player()
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    return ok and ents and ents[1] or nil
end

local function obj(o)
    local s = "?"
    pcall(function()
        local pos = o.Position
        s = string.format("{%s flags=%s pos=%.2f,%.2f,%.2f tags=%d}", hex(o.Entity), tostring(o.Flags),
            pos[1] or 0, pos[2] or 0, pos[3] or 0, #(o.Tags or {}))
    end)
    return s
end

local function watchTick(baseline)
    local me = player()
    if not me then return end
    local meHex = hex(me)
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientEffectHandler")
    if not ok or not ents then return end
    local now = tonumber(Ext.Timer.MonotonicTime()) or 0
    local seen = {}
    for _, e in ipairs(ents) do
        local id = hex(e)
        seen[id] = true
        if not known[id] then
            pcall(function()
                local hd = e.ClientEffectHandler.Handler
                local ii = hd.InitInfo
                local related = hex(ii.SourceEffect.Entity) == meHex or hex(ii.TargetEffect.Entity) == meHex
                    or hex(ii.EventProviderEntity) == meHex
                known[id] = { t = now, def = ii.MultiEffectDefinition, related = related }
                if related and not baseline then
                    local pt = {}
                    for _, p in ipairs(ii.PlayTime or {}) do pt[#pt + 1] = string.format("%s:%.2f", tostring(p.Phase), p.Time or 0) end
                    Log.Write(string.format(
                        "SpellFx watch: +%s %s (%s) src=%s tgt=%s provider=%s player=%s bones=%s scale=%.2f dmg=%s verbal=%s zone=%.2f reset=%s save=%s playtime=[%s] active=%s",
                        id, tostring(ii.MultiEffectDefinition), defName(ii.MultiEffectDefinition), obj(ii.SourceEffect),
                        obj(ii.TargetEffect), hex(ii.EventProviderEntity), hex(ii.Player), tostring(ii.WeaponBones),
                        ii.FXScale or 0, tostring(ii.DamageType), tostring(ii.VerbalIntent), ii.ZoneRange or 0,
                        tostring(ii.Reset), tostring(ii.EnteredDuringSave), table.concat(pt, " "), tostring(hd.IsActive)))
                end
            end)
            known[id] = known[id] or { t = now, related = false }
        end
    end
    for id, k in pairs(known) do
        if not seen[id] then
            if k.related then
                Log.Write(string.format("SpellFx watch: -%s %s (%s) after %.2fs", id, tostring(k.def), defName(k.def), (now - k.t) / 1000))
            end
            known[id] = nil
        end
    end
end

function M.Register()
    Ext.Events.Tick:Subscribe(function() if watching then pcall(watchTick) end end)
    Ext.RegisterConsoleCommand("dag_spell_fx_watch", function(_, a)
        watching = (a == "on" or a == "1")
        if watching then
            known = {}
            -- Effects already alive are the baseline, not logged.
            pcall(watchTick, true)
            for _, k in pairs(known) do k.related = false end
        end
        Log.Write("SpellFx: watch " .. (watching and "ON (logs effects created / removed on the player)" or "OFF"))
    end)
end

return M
