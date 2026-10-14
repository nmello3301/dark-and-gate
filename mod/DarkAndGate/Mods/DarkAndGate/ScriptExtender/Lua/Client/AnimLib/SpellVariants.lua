-- SPDX-License-Identifier: GPL-3.0-or-later
-- Which clips can a spell's animation ids become? (docs/spikes/spell-anims.md)
--
-- The same mapping id resolves in whichever animation set comes first, and
-- characters carry extra sets (AnimationWaterfall overrides, switched in by
-- tags, e.g. Gale's casting set 745fbb35). This lists, for each phase of a
-- spell, every distinct clip the id maps to across the player's active sets,
-- waterfall sets and override sets, and shows them side by side:
--
--   !dag_spell_variants [spell]            list (client.log)
--   !dag_spell_variants [spell] gallery    one gallery copy per PREPARE
--       variant: the copy's AnimationSet gets the variant's set first
--       (CastTags.PrependSet), then BG3's select event (prepare -> loop)
--       is sent to it; re-sent every resend_s so the prepare repeats.
--       Labels: "#n <clip> [set]". !dag_animlib clear removes the copies.

local Log          = Ext.Require("Shared/Log.lua")
local SpellAnims   = Ext.Require("Client/Combat/SpellAnims.lua")
local GenomeEvents = Ext.Require("Client/Combat/GenomeEvents.lua")
local CastTags     = Ext.Require("Client/Combat/CastTags.lua")
local Gallery      = Ext.Require("Client/AnimLib/Gallery.lua")
local Me = Ext.Require("Client/Me.lua")   -- the local player's character (multiplayer)

local M = {}

local RESEND_S = 7.0

local function player()
    local ok, ents = pcall(Me.All)
    return ok and ents and ents[1] or nil
end

local function clipOf(rid)
    local ok, ar = pcall(Ext.Resource.Get, rid, "Animation")
    if not ok or not ar then return nil end
    local f = tostring(ar.SourceFile or ""):gsub("^.*[/\\]", ""):gsub("%.[Gg][Rr]2$", "")
    return f, tonumber(ar.Duration) or 0
end

-- Every animation set the player can draw from, with where it comes from.
local function setsOf(ent)
    local list, seen = {}, {}
    local function add(res, label)
        res = tostring(res or "")
        if res ~= "" and not seen[res] then seen[res] = true; list[#list + 1] = { res = res, label = label } end
    end
    pcall(function()
        for i, e in ipairs(ent.AnimationSet.Entries) do add(e.Resource, "active#" .. i .. (e.Dynamic and " dynamic" or "")) end
    end)
    pcall(function()
        for _, o in ipairs(ent.AnimationWaterfall.Overrides) do
            for _, e in ipairs(o.Overrides) do
                add(e.Resource, string.format("override tag %s type %s", tostring(o.AnimationTag):sub(1, 8), tostring(o.OverrideType)))
            end
        end
    end)
    pcall(function()
        for i, e in ipairs(ent.AnimationWaterfall.Waterfall) do add(e.Resource, "waterfall#" .. i) end
    end)
    return list
end

-- id -> distinct clips { rid, file, dur, sets = {labels}, setRes, subset }.
local function variants(ent, id)
    local out, byRid = {}, {}
    for _, s in ipairs(setsOf(ent)) do
        pcall(function()
            local res = Ext.Resource.Get(s.res, "AnimationSet")
            if not res then return end
            for subKey, sub in pairs(res.AnimationBank.AnimationSubSets) do
                local okD, desc = pcall(function() return sub.Animation[id] end)
                if okD and desc then
                    local rid = tostring(desc.ID)
                    local v = byRid[rid]
                    if not v then
                        local f, d = clipOf(rid)
                        v = { rid = rid, file = f or "?", dur = d or 0, sets = {}, setRes = s.res, subset = tostring(subKey),
                              label = s.label }
                        byRid[rid] = v
                        out[#out + 1] = v
                    end
                    v.sets[#v.sets + 1] = s.label .. " " .. s.res:sub(1, 8) .. "/" .. tostring(subKey)
                end
            end
        end)
    end
    return out
end

local PHASE_SLOT = { prepare = 0, loop = 4, cast = 2, recover = 3, cancel = 6 }
local PHASES = { "prepare", "loop", "cast", "recover", "cancel" }

local function list(spell, ent)
    local slots = SpellAnims.Slots(spell)
    local res = {}
    for _, ph in ipairs(PHASES) do
        local id = slots[PHASE_SLOT[ph]]
        if id then
            local vs = variants(ent, id)
            res[ph] = { id = id, vs = vs }
            local lines = {}
            for i, v in ipairs(vs) do
                lines[#lines + 1] = string.format("  %d. %s (%.2fs) res %s\n       in: %s", i, v.file, v.dur, v.rid:sub(1, 8),
                    table.concat(v.sets, "; "))
            end
            Log.Write(string.format("SpellVariants: %s %s %s -> %d clip(s)\n%s", spell, ph, id:sub(1, 8), #vs, table.concat(lines, "\n")))
        end
    end
    return res, slots
end

local function gallery(spell, ent, res, slots)
    local prep = res.prepare
    if not prep or #prep.vs == 0 then Log.Write("SpellVariants: no prepare variants for " .. spell); return end
    local loopId = slots[PHASE_SLOT.loop]
    local clips = {}
    for i, v in ipairs(prep.vs) do
        local setRes = v.setRes
        local base = string.format("%s [%s]", v.file:gsub("^%a+_%a+_Rig_", ""), v.label)
        clips[i] = {
            base = base, dur = v.dur, keys = { prep.id },
            custom = function(s)
                local okE, ce = pcall(Ext.Entity.Get, s.uuid)
                if not okE or not ce then return 1.0 end
                local how = CastTags.PrependSet(ce, setRes)
                local ok, why = GenomeEvents.PlaySpell(ce, { prepare = { key = prep.id }, loop = loopId and { key = loopId } or nil })
                if not s.loggedVariant then
                    s.loggedVariant = true
                    Log.Write(string.format("SpellVariants: gallery #%d %s: set %s %s, select %s", i, v.file, setRes:sub(1, 8), how,
                        ok and "sent" or ("FAILED " .. tostring(why))))
                end
                return RESEND_S
            end,
        }
    end
    local uuid = nil
    pcall(function() uuid = ent.Uuid.EntityUuid end)
    Gallery.Open(#clips, "HUM_M", uuid and tostring(uuid) or nil, nil, clips)
    Log.Write(string.format("SpellVariants: gallery of %d %s prepare variants (labels #n = the list order above)", #clips, spell))
end

function M.Register()
    Ext.RegisterConsoleCommand("dag_spell_variants", function(_, spell, mode)
        spell = spell or "Projectile_FireBolt"
        local me = player()
        if not me then return end
        local res, slots = list(spell, me)
        if mode == "gallery" then gallery(spell, me, res, slots) end
    end)
end

return M
