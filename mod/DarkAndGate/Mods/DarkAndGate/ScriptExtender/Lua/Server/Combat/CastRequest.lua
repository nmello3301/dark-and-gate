-- SPDX-License-Identifier: GPL-3.0-or-later
-- Casting from script through the server's cast request queue
-- (Ext.System.ServerCastRequest.OsirisCastRequests), the way Brawl casts for
-- NPCs in real time (Server/Brawl/Actions.lua queueSpellRequest, tinybike,
-- credited): it works outside the caster's turn, and unlike Osi.UseSpell it
-- takes several targets or a bare position.
--
--   CastRequest.Submit(caster, spellId, targets, opts) -> request | nil, err
--     targets: { { uuid = "<uuid>" } | { pos = { x, y, z } }, ... }
--     opts.options: CastOptions (default: IgnoreHasSpell, NoMovement)
--     opts.front:   queue it first
--   CastRequest.AtPosition(caster, spellId, pos)   (pos {x,y,z} or {x=,y=,z=})
--   CastRequest.AtTarget(caster, spellId, target)
-- The spell source is "Osiris" (like Osi.UseSpell: no action, slot or
-- spellbook check); mana is ours (Server/Combat/Mana.lua).

local Log = Ext.Require("Shared/Log.lua")

local M = {}

local NULL = "00000000-0000-0000-0000-000000000000"
local DEFAULT_OPTIONS = { "IgnoreHasSpell", "NoMovement" }

local function uuid4()
    return (string.gsub("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx", "[xy]", function(c)
        return string.format("%x", c == "x" and math.random(0, 15) or math.random(8, 11))
    end))
end

local function v3(p)
    if not p then return nil end
    local x, y, z = p[1] or p.x, p[2] or p.y, p[3] or p.z
    if x and y and z then return { tonumber(x), tonumber(y), tonumber(z) } end
    return nil
end

local function target(t, spellType)
    if t.uuid then
        local ok, e = pcall(Ext.Entity.Get, t.uuid)
        if not ok or not e then return nil end
        local r = { Target = e, TargetingType = spellType }
        pcall(function()
            local p = e.Transform.Transform.Translate
            r.Position = { p[1], p[2], p[3] }
        end)
        return r
    end
    local p = v3(t.pos)
    if not p then return nil end
    return { TargetingType = spellType, Position = p }
end

local warned = false
function M.Submit(caster, spellId, targets, opts)
    opts = opts or {}
    local okS, stats = pcall(Ext.Stats.Get, spellId)
    if not okS or not stats then return nil, "no stats entry " .. tostring(spellId) end
    local okC, casterEnt = pcall(Ext.Entity.Get, caster)
    if not okC or not casterEnt then return nil, "no caster entity" end
    local spellType = tostring(stats.SpellType)
    local tl = {}
    for _, t in ipairs(targets or {}) do
        local bt = target(t, spellType)
        if bt then tl[#tl + 1] = bt end
    end
    if #tl == 0 then return nil, "no valid target" end
    local root = spellId
    pcall(function() if stats.RootSpellID and stats.RootSpellID ~= "" then root = stats.RootSpellID end end)
    local request = {
        CastOptions = opts.options or DEFAULT_OPTIONS,
        Caster = casterEnt,
        RequestGuid = uuid4(),
        Spell = { OriginatorPrototype = root, ProgressionSource = NULL, Prototype = spellId, Source = NULL, SourceType = "Osiris" },
        Targets = tl,
        field_A8 = 1,
    }
    local ok, err = pcall(function()
        local q = Ext.System.ServerCastRequest.OsirisCastRequests
        if opts.front then
            for i = #q, 1, -1 do q[i + 1] = q[i] end
            q[1] = request
        else
            q[#q + 1] = request
        end
    end)
    if not ok then
        if not warned then warned = true; Log.Write("CastRequest: the cast request queue can't be written: " .. tostring(err)) end
        return nil, tostring(err)
    end
    return request
end

function M.AtPosition(caster, spellId, pos)
    local r, err = M.Submit(caster, spellId, { { pos = pos } })
    if r then return true end
    -- Fallback: Osiris (works on the party's own turn; NPCs may refuse outside theirs).
    local p = v3(pos)
    if not p then return false end
    local ok = pcall(function() Osi.UseSpellAtPosition(caster, spellId, p[1], p[2], p[3], 1) end)
    Log.Write(string.format("CastRequest: %s at a position via the queue failed (%s), Osi.UseSpellAtPosition %s", spellId, tostring(err),
        ok and "ok" or "FAILED"))
    return ok
end

function M.AtTarget(caster, spellId, tgt, opts)
    local r, err = M.Submit(caster, spellId, { { uuid = tgt } }, opts)
    if r then return true end
    local ok = pcall(function() Osi.UseSpell(caster, spellId, tgt) end)
    Log.Write(string.format("CastRequest: %s on %s via the queue failed (%s), Osi.UseSpell %s", spellId, tostring(tgt), tostring(err),
        ok and "ok" or "FAILED"))
    return ok
end

return M
