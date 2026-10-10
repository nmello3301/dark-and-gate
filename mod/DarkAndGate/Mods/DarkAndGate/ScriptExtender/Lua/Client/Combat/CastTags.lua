-- SPDX-License-Identifier: GPL-3.0-or-later
-- Casting animation set, like vanilla targeting (docs/spikes/spell-anims.md).
--
-- Snapshot diff 2026-10-10 (!dag_anim_state, vanilla vs ours): while a spell
-- is selected vanilla adds a type-1 copy of one of the character's dynamic
-- animation tags (Gale: a865965f, type 0 -> also type 1). The character's
-- AnimationWaterfall has an OverrideType 1 entry for that tag, so the engine
-- puts its animation set (745fbb35, Dynamic) first in AnimationSet, and the
-- spell's prepare / loop ids resolve there: Gale's own casting pose instead
-- of the generic one.
-- Generic rule: every type-0 tag that has an OverrideType 1 waterfall entry
-- (and no type-1 copy yet) gets a type-1 copy while channelling. The copies
-- are removed after the cast (cast_hold_s) or cancel (cancel_hold_s), so the
-- cast / recover / stow clips also come from that set.
-- Client-side and local, like the select event.
--
--   !dag_cast_tags [on|off]   apply / remove by hand (shows the idle change)

local Log    = Ext.Require("Shared/Log.lua")
local spells = Ext.Require("data/spells.lua")

local M = {}

local CT = (spells.spell_anims and spells.spell_anims.cast_tags) or {}

local added = nil        -- { ent, tags = {guid...}, sets = {resource...} }
local removeAt = nil

local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function tagName(guid)
    local ok, t = pcall(Ext.StaticData.Get, guid, "Tag")
    local okN, n = pcall(function() return t and t.Name end)
    return (ok and okN and n) and tostring(n) or "?"
end

-- Tags to add and the sets they bring.
local function candidates(ent)
    local have0, have1 = {}, {}
    for _, t in ipairs(ent.DynamicAnimationTags.Tags) do
        local g = tostring(t.Tag)
        if tonumber(t.field_10) == 1 then have1[g] = true else have0[g] = true end
    end
    local out = {}
    for _, o in ipairs(ent.AnimationWaterfall.Overrides) do
        local g = tostring(o.AnimationTag)
        if tonumber(o.OverrideType) == 1 and have0[g] and not have1[g] then
            local sets = {}
            for _, e in ipairs(o.Overrides) do sets[#sets + 1] = tostring(e.Resource) end
            out[#out + 1] = { tag = g, sets = sets }
            have1[g] = true
        end
    end
    return out
end

-- Put animation set `res` first in ent's AnimationSet (Dynamic, like the
-- engine's own override entry). Returns a short status. The engine did NOT
-- rebuild the AnimationSet from a Lua-written tag (playtest 2026-10-10:
-- "casting set NOT ready"), so force_set writes the entry directly.
function M.PrependSet(ent, res)
    if not ent or not res then return "no entity / set" end
    local ok, r = pcall(function()
        local entries = ent.AnimationSet.Entries
        if #entries > 0 and tostring(entries[1].Resource) == res then return "already first" end
        local old = {}
        for i, e in ipairs(entries) do
            if tostring(e.Resource) ~= res then
                old[#old + 1] = { Slot = tostring(e.Slot or ""), Resource = tostring(e.Resource), Type = tostring(e.Type), Dynamic = e.Dynamic }
            end
        end
        local n = #entries
        entries[1] = { Slot = "", Resource = res, Type = "Visual", Dynamic = true }
        for i, e in ipairs(old) do entries[i + 1] = e end
        for i = #entries, #old + 2, -1 do entries[i] = nil end
        return string.format("prepended (%d -> %d entries, first %s)", n, #entries, tostring(entries[1].Resource):sub(1, 8))
    end)
    return ok and r or ("ERROR " .. tostring(r))
end

-- Remove the Dynamic entry for `res` (one we prepended).
function M.RemoveSet(ent, res)
    local ok, r = pcall(function()
        local entries = ent.AnimationSet.Entries
        for i = #entries, 1, -1 do
            if tostring(entries[i].Resource) == res and entries[i].Dynamic then entries[i] = nil; return "removed" end
        end
        return "not present"
    end)
    return ok and r or ("ERROR " .. tostring(r))
end

local function removeNow(why)
    removeAt = nil
    if not added then return end
    local a = added
    added = nil
    local n = 0
    pcall(function()
        local tags = a.ent.DynamicAnimationTags.Tags
        for _, g in ipairs(a.tags) do
            for i = #tags, 1, -1 do
                if tostring(tags[i].Tag) == g and tonumber(tags[i].field_10) == 1 then tags[i] = nil; n = n + 1; break end
            end
        end
    end)
    local setParts = {}
    for _, res in ipairs(a.forced or {}) do setParts[#setParts + 1] = res:sub(1, 8) .. " " .. M.RemoveSet(a.ent, res) end
    Log.Write(string.format("CastTags: removed %d casting tag(s)%s (%s)", n,
        #setParts > 0 and (", forced sets: " .. table.concat(setParts, ", ")) or "", why))
end

-- Add the casting tags. Returns the number added.
function M.Apply(ent)
    if CT.enabled == false or not ent then return 0 end
    if added then removeNow("re-apply") end
    removeAt = nil
    local ok, list = pcall(candidates, ent)
    if not ok then Log.Write("CastTags: ERROR reading tags/waterfall: " .. tostring(list)); return 0 end
    local a = { ent = ent, tags = {}, sets = {} }
    local parts = {}
    for _, c in ipairs(list) do
        local okA, err = pcall(function()
            local tags = ent.DynamicAnimationTags.Tags
            tags[#tags + 1] = { Tag = c.tag, field_10 = 1 }
        end)
        if okA then
            a.tags[#a.tags + 1] = c.tag
            for _, s in ipairs(c.sets) do a.sets[#a.sets + 1] = s end
        end
        parts[#parts + 1] = string.format("%s (%s) -> set %s%s", c.tag:sub(1, 8), tagName(c.tag), table.concat(c.sets, ","),
            okA and "" or (" ERROR " .. tostring(err)))
    end
    if #a.tags > 0 then added = a end
    -- force_set: the engine doesn't rebuild the set list from our tag, so
    -- put the override sets first ourselves.
    if CT.force_set ~= false and #a.sets > 0 then
        a.forced = {}
        for i = #a.sets, 1, -1 do
            local res = a.sets[i]
            local present = false
            pcall(function()
                for _, e in ipairs(ent.AnimationSet.Entries) do if tostring(e.Resource) == res then present = true end end
            end)
            if not present then
                parts[#parts + 1] = "force " .. res:sub(1, 8) .. ": " .. M.PrependSet(ent, res)
                a.forced[#a.forced + 1] = res
            end
        end
    end
    Log.Write(string.format("CastTags: added %d casting tag(s)%s", #a.tags, #parts > 0 and (": " .. table.concat(parts, "; ")) or ""))
    return #a.tags
end

-- True once every set the added tags bring is in the character's AnimationSet.
function M.Ready(ent)
    if not added then return true end
    local ok, r = pcall(function()
        local present = {}
        for _, e in ipairs(ent.AnimationSet.Entries) do present[tostring(e.Resource)] = true end
        for _, s in ipairs(added.sets) do if not present[s] then return false end end
        return true
    end)
    return ok and r
end

-- Remove after the cast / cancel clip ("cast" -> cast_hold_s, else cancel_hold_s).
function M.Release(reason)
    if not added then return end
    local hold = (reason == "cast") and (CT.cast_hold_s or 3.0) or (CT.cancel_hold_s or 1.2)
    removeAt = nowMs() + hold * 1000
end

function M.Register()
    Ext.Events.Tick:Subscribe(function()
        if removeAt and nowMs() >= removeAt then pcall(removeNow, "after clip") end
    end)
    Ext.RegisterConsoleCommand("dag_cast_tags", function(_, a)
        local okE, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
        local me = okE and ents and ents[1] or nil
        if a == "off" then removeNow("command") return end
        M.Apply(me)
    end)
end

return M
