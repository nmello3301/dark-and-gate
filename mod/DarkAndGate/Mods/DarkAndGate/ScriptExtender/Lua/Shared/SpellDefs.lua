-- SPDX-License-Identifier: GPL-3.0-or-later
-- How our hotbar treats ANY spell (the Prepare Hotbar menu can bind every
-- spell the character has): data/spells.lua's entry when there is one,
-- otherwise one derived from the spell's own stats --
--   level      stats Level (0 = cantrip)
--   cost       data/spells.lua cost_by_level[level] (DESIGN mana table)
--   kind       from SpellType: Projectile / ProjectileStrike / Target /
--              MultiStrike -> "target" (a character under the crosshair, else
--              the point), Shout -> "self", Teleportation -> "teleport",
--              everything else (Zone, Cone, Wall, Rush, Throw...) -> "point"
--   unlimited_range  false: only data/spells.lua spells fly through our
--              projectile system along the crosshair line
--   range_m    the spell's first-person range (Shared/SpellRange.lua: 70 m
--              shots, 30 m areas and multi-target spells, BG3's own range
--              otherwise), else 18
--   label/icon stats DisplayName / Icon
-- Shared: the server prices and validates casts with the same table.

local spells = Ext.Require("data/spells.lua")
local SpellRange = Ext.Require("Shared/SpellRange.lua")

local M = {}

local memo = {}

local KIND = {
    Projectile = "target", ProjectileStrike = "target", Target = "target", MultiStrike = "target",
    Shout = "self", Teleportation = "teleport",
}

local function str(v) return v ~= nil and tostring(v) or "" end

local function label(st, id)
    local okH, h = pcall(function() return str(st.DisplayName) end)
    if okH and h ~= "" then
        local handle = h:match("^([^;]+)")
        local ok, txt = pcall(Ext.Loca.GetTranslatedString, handle)
        if ok and txt and txt ~= "" then return txt end
    end
    return id
end

local function derive(id)
    local ok, st = pcall(Ext.Stats.Get, id)
    if not ok or not st then return nil end
    local level = tonumber(str(st.Level)) or 0
    local stype = str(st.SpellType)
    local kind = KIND[stype] or "point"
    local isProjectile = (stype == "Projectile" or stype == "ProjectileStrike")
    local flags = {}
    pcall(function() for _, f in ipairs(st.SpellFlags) do flags[tostring(f)] = true end end)
    return {
        derived = true,
        kind = kind,
        level = level,
        cost = spells.cost_by_level[level] or 0,
        cooldown_ms = level == 0 and 400 or 1500,
        range_m = SpellRange.RangeOf(id) or tonumber(str(st.TargetRadius)) or 18,
        unlimited_range = false,
        projectile = isProjectile,
        label = label(st, id),
        icon = str(st.Icon),
        spell_type = stype,
        is_spell = flags.IsSpell == true,
    }
end

-- The def for spell `id`, or nil when it has no stats entry.
function M.Get(id)
    if not id then return nil end
    local d = spells.spells[id]
    if d then
        if d.range_m == nil then d.range_m = SpellRange.RangeOf(id) or 18 end
        if d.label == nil or d.icon == nil then
            local x = memo[id] or derive(id)
            memo[id] = x
            if x then d.icon = d.icon or x.icon; d.label = d.label or x.label end
        end
        return d
    end
    if memo[id] == nil then memo[id] = derive(id) or false end
    return memo[id] or nil
end

function M.Cost(id)
    local d = M.Get(id)
    if not d then return 0 end
    return d.cost or (spells.cost_by_level[d.level or 0] or 0)
end

function M.Forget() memo = {} end

return M
