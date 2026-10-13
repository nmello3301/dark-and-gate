-- SPDX-License-Identifier: GPL-3.0-or-later
-- Spell ranges in first person (data/spells.lua shot_range_m / area_range_m,
-- DECISIONS 2026-10-12). Every real spell (SpellFlags IsSpell) with a numeric
-- BG3 range above touch_max_m gets the range of its class:
--   "shot"  a Projectile / ProjectileStrike, or a Target spell on one
--           target: it flies at, or hits, one target -> shot_range_m
--   "area"  an area (AreaRadius > 0), several picked targets (a Target spell
--           with AmountOfTargets > 1: Sleep, Bless) or a Wall -> area_range_m
-- Teleports, cones / zones from the caster, shouts and weapon actions (their
-- range is the weapon's) keep BG3's data. A range is only ever raised. This
-- changes how far a spell is aimed, never what it does (DESIGN: spells stay
-- BG3 data).
--
-- BG3 refuses a cast point beyond the spell's TargetRadius, or walks the
-- caster into range, so the stat itself is raised: on StatsLoaded (client
-- and server, no sync needed while loading) and again when the module
-- registers, for a Lua `reset` mid-session (the server Syncs the entries it
-- changes). BG3's own ranges are kept (M.Vanilla) for Brawl's AI: NPCs and
-- companions still walk to BG3's range before they cast
-- (Server/BrawlAdapter.lua). After a Lua `reset` the stats are already
-- raised, so M.Vanilla has nothing until the game restarts.

local Log    = Ext.Require("Shared/Log.lua")
local spells = Ext.Require("data/spells.lua")

local M = {}

local vanilla = {}   -- spell -> BG3's TargetRadius (the stat's string) before our raise
local classes = {}   -- spell -> "shot" | "area" | false
local SAMPLES = { "Projectile_FireBolt", "Projectile_RayOfFrost", "Target_SacredFlame", "Projectile_Fireball", "Target_Sleep", "Target_Bless" }

local function str(v) return v ~= nil and tostring(v) or "" end

local function isSpell(st)
    local found = false
    pcall(function()
        for _, f in ipairs(st.SpellFlags) do
            if tostring(f) == "IsSpell" then found = true; break end
        end
    end)
    return found
end

-- "shot" | "area" | false, from the spell's BG3 data and BG3 range r.
local function classify(st, r)
    if not r or r <= (spells.touch_max_m or 3) then return false end
    local stype = str(st.SpellType)
    local area = tonumber(str(st.AreaRadius)) or 0
    local amount = tonumber(str(st.AmountOfTargets)) or 1
    if stype == "Wall" then return "area" end
    if stype == "Target" then return (area > 0 or amount > 1) and "area" or "shot" end
    if stype == "Projectile" or stype == "ProjectileStrike" then return area > 0 and "area" or "shot" end
    return false
end

local function classRange(cls)
    if cls == "shot" then return spells.shot_range_m or 70 end
    if cls == "area" then return spells.area_range_m or 30 end
    return nil
end

local function look(id)
    local okS, st = pcall(Ext.Stats.Get, id)
    if not okS or not st or not isSpell(st) then return nil, false end
    return st, classify(st, tonumber(str(st.TargetRadius)))
end

local function apply(why, sync)
    local okL, names = pcall(Ext.Stats.GetStats, "SpellData")
    if not okL or type(names) ~= "table" or #names == 0 then return end
    local n = { shot = 0, area = 0, raised = 0, failed = 0 }
    for _, id in ipairs(names) do
        local st, cls = look(id)
        if st then
            classes[id] = cls
            if cls then
                n[cls] = n[cls] + 1
                local want = classRange(cls)
                local before = str(st.TargetRadius)
                local cur = tonumber(before)
                if cur and cur < want then
                    local okW = pcall(function() st.TargetRadius = tostring(want) end)
                    if not okW or tonumber(str(st.TargetRadius)) ~= want then
                        pcall(function() st.TargetRadius = want end)
                    end
                    if tonumber(str(st.TargetRadius)) == want then
                        vanilla[id] = vanilla[id] or before
                        n.raised = n.raised + 1
                        if sync then pcall(function() st:Sync() end) end
                    else
                        n.failed = n.failed + 1
                    end
                end
            end
        end
    end
    local ex = {}
    for _, id in ipairs(SAMPLES) do
        if classes[id] then
            local okS, st = pcall(Ext.Stats.Get, id)
            ex[#ex + 1] = string.format("%s %s -> %s", id, vanilla[id] or "=", okS and st and str(st.TargetRadius) or "?")
        end
    end
    Log.Write(string.format("SpellRange: %d shot spells (%d m), %d area / multi-target spells (%d m); %d raised%s%s (%s)%s",
        n.shot, classRange("shot"), n.area, classRange("area"), n.raised, n.failed > 0 and string.format(", %d FAILED", n.failed) or "",
        sync and n.raised > 0 and ", synced" or "", why, #ex > 0 and ("; " .. table.concat(ex, ", ")) or ""))
end

-- "shot" | "area" | nil: the spell's range class.
function M.ClassOf(id)
    if not id then return nil end
    if classes[id] == nil then
        local _, cls = look(id)
        classes[id] = cls or false
    end
    return classes[id] or nil
end

-- The spell's first-person range in m: its class range, else nil (the
-- caller keeps BG3's own).
function M.RangeOf(id)
    return classRange(M.ClassOf(id))
end

-- BG3's own TargetRadius before our raise (the stat's string), or nil when
-- we didn't change it.
function M.Vanilla(id) return id and vanilla[id] or nil end

function M.Register(context)
    Ext.Events.StatsLoaded:Subscribe(function() apply("StatsLoaded", false) end)
    -- After a Lua reset the stats are already loaded.
    apply("register", context == "Server")
end

return M
