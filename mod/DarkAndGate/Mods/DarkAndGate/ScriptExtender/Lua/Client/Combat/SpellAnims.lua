-- SPDX-License-Identifier: GPL-3.0-or-later
-- Which clips a spell plays, for any spell and any character
-- (docs/spikes/spell-anims.md).
--
-- Source: the spell's own stats, SpellAnimation = 9 slots of "mappingId,,".
-- Slot order, confirmed 2026-10-10 by recording a vanilla Fire Bolt
-- (docs/anim-record-2026-10-10.txt) against its stats:
--   0 prepare   (HUM_M_Rig_VIO_SPL_Bard_01_Prepare)
--   2 cast      (..._Bard_Damage_01_Cast)
--   3 recover   (..._Bard_Damage_01_Recover)
--   4 loop      (..._Bard_01_Loop, the held prepare)
--   6 cancel    (sent with the cancel event; genome capture 2026-10-10)
--   1, 5, 7, 8 empty on the spells checked
-- The ids are animation MAPPING ids: each character resolves them through
-- its own AnimationSets (rig, weapon stance), so the same ids serve custom
-- characters. A slot the character can't resolve falls back to the
-- spell_anims.fallback family (data/spells.lua); logged as a coverage line.
--
--   SpellAnims.For(spellId, ent) -> { prepare = {key,dur,file}|nil, loop, cast,
--                                     recover, rig, coverage = "...", fallback = bool }
--   !dag_spell_anims [spellId]     print it for the controlled character

local Log    = Ext.Require("Shared/Log.lua")
local spells = Ext.Require("data/spells.lua")

local M = {}

M.SLOTS = { prepare = 0, cast = 2, recover = 3, loop = 4 }
local PHASES = { "prepare", "loop", "cast", "recover" }

local function isGuid(x)
    return type(x) == "string" and x:match("^%x+%-%x+%-%x+%-%x+%-%x+$") ~= nil
end

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
    return okI and r or nil
end

-- slots[0..8] = first mapping id of each SpellAnimation slot.
function M.Slots(spell)
    local slots, src = {}, "none"
    local okS, st = pcall(Ext.Stats.Get, spell)
    if okS and st then
        local okA, raw = pcall(function() return st.SpellAnimation end)
        if okA and type(raw) == "string" then
            local i = 0
            for group in (raw .. ";"):gmatch("([^;]*);") do slots[i] = firstGuid(group); i = i + 1 end
            src = "stats string"
        elseif okA and raw ~= nil then
            pcall(function() for i, g in ipairs(raw) do slots[i - 1] = firstGuid(g) end end)
            src = "stats table"
        end
    end
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
    return slots, src
end

-- The character's rig (most common "<RACE>_<BODY>" of its clip names).
local function rigOf(file) return file and file:match("^(%a+_%a+)_[Rr]ig_") end

-- mapping id -> { res, file, dur } through the character's AnimationSets.
local function resolver(ent)
    local sets = {}
    pcall(function()
        for _, e in ipairs(ent.AnimationSet.Entries) do
            local okR, res = pcall(Ext.Resource.Get, tostring(e.Resource), "AnimationSet")
            if okR and res then sets[#sets + 1] = res end
        end
    end)
    local cache = {}
    return function(id)
        if not id then return nil end
        if cache[id] ~= nil then return cache[id] or nil end
        local r = false
        for _, res in ipairs(sets) do
            pcall(function()
                for _, sub in pairs(res.AnimationBank.AnimationSubSets) do
                    local okD, desc = pcall(function() return sub.Animation[id] end)
                    if okD and desc then
                        local rid = tostring(desc.ID)
                        local okA, ar = pcall(Ext.Resource.Get, rid, "Animation")
                        if okA and ar then
                            local f = tostring(ar.SourceFile or ""):gsub("^.*[/\\]", ""):gsub("%.[Gg][Rr]2$", "")
                            r = { key = id, res = rid, file = f, dur = tonumber(ar.Duration) or 0 }
                            return
                        end
                    end
                end
            end)
            if r then break end
        end
        cache[id] = r
        return r or nil
    end, #sets
end

-- Every clip `id` maps to, per animation set / subset (diagnostic: the
-- blueprint picks the one of the ACTIVE subset, which follows the weapon).
function M.AllMatches(ent, id)
    local out = {}
    pcall(function()
        for _, e in ipairs(ent.AnimationSet.Entries) do
            local okR, res = pcall(Ext.Resource.Get, tostring(e.Resource), "AnimationSet")
            if okR and res then
                for subKey, sub in pairs(res.AnimationBank.AnimationSubSets) do
                    local okD, desc = pcall(function() return sub.Animation[id] end)
                    if okD and desc then
                        local okA, ar = pcall(Ext.Resource.Get, tostring(desc.ID), "Animation")
                        local f = (okA and ar) and tostring(ar.SourceFile or ""):gsub("^.*[/\\]", ""):gsub("%.[Gg][Rr]2$", "") or "?"
                        out[#out + 1] = string.format("%s/%s: %s (%.2fs)", tostring(e.Resource):sub(1, 8), tostring(subKey), f,
                            (okA and ar) and tonumber(ar.Duration) or 0)
                    end
                end
            end
        end
    end)
    return out
end

local memo = {}   -- spell .. "|" .. entity -> result

-- fresh: ignore the memo (the active sets changed, e.g. CastTags).
function M.For(spell, ent, fresh)
    if not spell or not ent then return nil end
    local mk = spell .. "|" .. tostring(ent)
    if memo[mk] and not fresh then return memo[mk] end
    local slots, src = M.Slots(spell)
    local resolve, nsets = resolver(ent)
    local fb = spells.spell_anims and spells.spell_anims.fallback or {}
    local out = { spell = spell, src = src, coverage = {}, fallback = false }
    local rig
    for _, ph in ipairs(PHASES) do
        local id = slots[M.SLOTS[ph]]
        local c = resolve(id)
        local how = "ok"
        if not c then
            c = resolve(fb[ph])
            how = c and ("fallback" .. (id and "" or " (slot empty)")) or ((id and "MISSING" or "none"))
            if c then out.fallback = true end
        end
        out[ph] = c
        rig = rig or (c and rigOf(c.file))
        out.coverage[#out.coverage + 1] = ph .. " " .. how
    end
    out.rig = rig or "?"
    out.slot6 = slots[6]
    memo[mk] = out
    Log.Write(string.format("SpellAnims: %s rig=%s sets=%d (%s) %s%s", spell, out.rig, nsets, src,
        table.concat(out.coverage, " / "), out.fallback and "  [spell " .. spell .. ": fallback anims]" or ""))
    return out
end

function M.Describe(a)
    local parts = {}
    for _, ph in ipairs(PHASES) do
        local c = a[ph]
        parts[#parts + 1] = string.format("%s=%s", ph, c and string.format("%s %s (%.2fs)", c.key, c.file, c.dur or 0) or "none")
    end
    return table.concat(parts, "\n    ")
end

function M.Forget() memo = {} end

function M.Register()
    Ext.RegisterConsoleCommand("dag_spell_anims", function(_, spell)
        spell = spell or "Projectile_FireBolt"
        local okE, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
        local ent = okE and ents and ents[1] or nil
        if not ent then Log.Write("SpellAnims: no controlled character"); return end
        memo = {}
        local a = M.For(spell, ent)
        local slots = M.Slots(spell)
        local raw = {}
        for i = 0, 8 do raw[#raw + 1] = string.format("%d=%s", i, slots[i] and slots[i]:sub(1, 8) or "-") end
        Log.Write(string.format("SpellAnims: %s slots %s\n    %s", spell, table.concat(raw, " "), M.Describe(a)))
        for _, ph in ipairs(PHASES) do
            local id = slots[M.SLOTS[ph]]
            if id then
                Log.Write(string.format("SpellAnims: %s %s %s in every set:\n    %s", spell, ph, id:sub(1, 8),
                    table.concat(M.AllMatches(ent, id), "\n    ")))
            end
        end
        pcall(function()
            Log.Write(string.format("SpellAnims: stance %s, weapon set %s", tostring(ent.Unsheath.State),
                tostring(ent.WeaponSet and ent.WeaponSet.WeaponSet)))
        end)
    end)
end

return M
