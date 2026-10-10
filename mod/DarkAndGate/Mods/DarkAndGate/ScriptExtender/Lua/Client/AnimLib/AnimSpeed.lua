-- SPDX-License-Identifier: GPL-3.0-or-later
-- Animation play rate through the character's AnimationBlueprint (Genome)
-- variables -- docs/spikes/anim-speed.md.
--
-- Credit: the approach was learned from QSAT (Quick Small Animation
-- Thingy, Nexus 17737), which drives its play-rate slider by writing the
-- Genome variable named "PlayRate" on photo-mode dummies. Our own code;
-- nothing of QSAT's is copied.
--
--   names:  ent.AnimationBlueprint.Resource.Blueprints[1].Variables[i].Name
--           (fallback: ent.AnimationBlueprint.Instance.Parent.Variables)
--   values: ent.AnimationBlueprint.Instance.Variables[i] = { Type, Value }
-- Client-side and per entity (each client sets it for what it renders).
--
-- Whether a GAMEPLAY character's blueprint has a PlayRate variable at all
-- is not known yet (QSAT only uses photo-mode dummies); Set() returns
-- false plus a reason when it hasn't, and callers show that instead of
-- pretending.

local Log = Ext.Require("Shared/Log.lua")
local FullPov = Ext.Require("FullPov.lua")

local M = {}

M.VAR = "PlayRate"

-- 2026-10-09 probe on Gale: the gameplay blueprint has NO general
-- "PlayRate" (1794 variables), but has JumpFlightAscendPlayRate,
-- JumpFlightDescendPlayRate, LOCO_CharacterScalePlayRate,
-- ATT_AdditiveStillPlayRate and a few STAT_Incapacitated_* rates. Each
-- variable reads as a gn::GenomeVariant userdata with .Type / .Value.

local indexCache = {}   -- tostring(entity) .. name -> index | false

local function findIndex(ent, name)
    name = name or M.VAR
    local key = tostring(ent) .. "|" .. name
    local c = indexCache[key]
    if c ~= nil then return c or nil end
    local idx = false
    pcall(function()
        for i, v in ipairs(ent.AnimationBlueprint.Resource.Blueprints[1].Variables) do
            if tostring(v.Name) == name then idx = i; return end
        end
    end)
    if not idx then
        pcall(function()
            for _, v in ipairs(ent.AnimationBlueprint.Instance.Parent.Variables) do
                if tostring(v.Name) == name then idx = v.Index + 1; return end
            end
        end)
    end
    indexCache[key] = idx
    return idx or nil
end

local function field(v, k)
    local ok, x = pcall(function() return v[k] end)
    return ok and x or nil
end

-- Returns true, or false + reason. name defaults to "PlayRate".
function M.Set(ent, rate, name)
    name = name or M.VAR
    if not ent then return false, "no entity" end
    local idx = findIndex(ent, name)
    if not idx then return false, "no " .. name .. " variable on this character's blueprint" end
    local ok, err = pcall(function()
        local vars = ent.AnimationBlueprint.Instance.Variables
        vars[idx] = { Type = field(vars[idx], "Type"), Value = rate }
    end)
    if not ok then return false, tostring(err) end
    return true
end

function M.Get(ent, name)
    local idx = ent and findIndex(ent, name)
    if not idx then return nil end
    local ok, v = pcall(function() return ent.AnimationBlueprint.Instance.Variables[idx] end)
    if not ok then return nil end
    return tonumber(field(v, "Value")) or tonumber(v)
end

function M.Available(ent, name) return ent ~= nil and findIndex(ent, name) ~= nil end

function M.Forget() indexCache = {} end

-- Whole-character play rate (0 = freeze). The entry point the browser
-- slider and the jump use. Routes to the native per-character animation
-- clock when the DLL provides it (docs/spikes/anim-clock.md); until then
-- tries the blueprint "PlayRate" variable. Returns ok, how-or-reason.
-- Native: the DLL hooks the shared PlayAnimation-node Execute and scales
-- the PlayRate input for this character's GenomeBlueprintInstance
-- (docs/spikes/anim-clock.md). One target at a time.
M.Native = function(ent, rate)
    local okI, inst = pcall(function() return ent.AnimationBlueprint.Instance end)
    local addr = okI and inst and FullPov.AddrOf(inst) or nil
    if not addr then return false, "no AnimationBlueprint.Instance on this character" end
    if rate == 1 then FullPov.SetAnimRate(nil, 1.0) else FullPov.SetAnimRate(addr, rate) end
    return true, "native PlayAnimation hook (native.log RATE lines confirm)"
end
function M.SetCharacter(ent, rate)
    if M.Native then
        local ok, how = M.Native(ent, rate)
        if ok then return true, how end
    end
    local ok, why = M.Set(ent, rate)
    if ok then return true, "blueprint PlayRate variable" end
    return false, M.Native and "native lever failed and " .. tostring(why) or ("no native lever yet; " .. tostring(why))
end

return M
