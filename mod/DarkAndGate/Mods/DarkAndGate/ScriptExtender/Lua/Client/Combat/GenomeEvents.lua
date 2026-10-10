-- SPDX-License-Identifier: GPL-3.0-or-later
-- BG3's spell animation event (docs/spikes/spell-anims-native.md).
--
-- Vanilla casts don't use Osi.PlayAnimation: the client sends a gameplay
-- event to the character's animation blueprint (main spell event
-- ba293d56-..., 21 args: 6 animation mapping ids, 3 cast sets, 3 ids,
-- bools, enums, cast uuid, animation set). The blueprint copies the args
-- into SPELL_Prepare / SPELL_Loop / ... and plays them. No Osiris task, so
-- nothing roots the character. Full body (the vanilla graph has no upper
-- body layer): legs hold the cast pose while walking (accepted 2026-10-10).
--
-- The arg order isn't decoded statically, so it is captured from a real
-- vanilla cast:
--   !dag_genome_events on   log every gameplay event for the player
--   ... cast Fire Bolt the vanilla way (POV off), then select it again and
--       cancel with right-click ...
--   !dag_genome_events off  saves DarkAndGate/genome-spell-template.txt:
--       the Fire Bolt event (args with their types) and the first other
--       event seen after it ended = cancel candidate.
-- Replay (Prepare.lua): the template with each arg that held one of Fire
-- Bolt's SpellAnimation ids swapped for the new spell's id of the same role.

local Log       = Ext.Require("Shared/Log.lua")
local SpellAnims = Ext.Require("Client/Combat/SpellAnims.lua")

local M = {}

M.SPELL_EVENT = "ba293d56-e14d-4d62-8151-4d63f1257bcd"
local SIDE = { ["0df4bd9f-9a34-4714-a7be-3bb6b7c6844d"] = true, ["96516143-3fb4-4838-aa83-654a6a3e76d9"] = true,
               ["43b4462a-cdc9-478f-9f09-897127f39985"] = true }
local TEMPLATE_PATH = "DarkAndGate/genome-spell-template.txt"
local TEMPLATE_SPELL = "Projectile_FireBolt"

local logging = false
local seen = {}          -- { t, name, args = { {Type, Value} } }
local template = nil     -- { args = {...}, roles = { [argIndex] = "prepare"|... }, cancel = name|nil }

local function player()
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    return ok and ents and ents[1] or nil
end

local function str(v)
    local ok, s = pcall(tostring, v)
    return ok and s or "?"
end

-- Read this frame's queued events (best effort; fields logged once).
local shapeLogged = false
local function poll()
    local okS, sing = pcall(Ext.Entity.GetAllEntitiesWithComponent, "AnimationGameplayEventsSingleton")
    if not okS or not sing or not sing[1] then return end
    local me = player()
    local meKey = me and str(me) or nil
    pcall(function()
        local comp = sing[1].AnimationGameplayEventsSingleton
        for _, e in pairs(comp.Events or comp) do
            local ent = e.Entity
            if not meKey or str(ent) == meKey then
                local name = str(e.Event or e.Name)
                local args = {}
                pcall(function()
                    for i, a in ipairs(e.Args or e.Parameters or {}) do
                        args[i] = { Type = str(a.Type), Value = str(a.Value) }
                    end
                end)
                seen[#seen + 1] = { t = tonumber(Ext.Timer.MonotonicTime()) or 0, name = name, args = args }
                local parts = {}
                for i, a in ipairs(args) do parts[#parts + 1] = string.format("%d:%s=%s", i - 1, a.Type, a.Value) end
                Log.Write(string.format("Genome event %s args(%d) %s", name, #args, table.concat(parts, " ")))
                if not shapeLogged then shapeLogged = true; Log.Write("Genome: event record fields read OK") end
            end
        end
    end)
end

local function saveTemplate()
    local fb = nil
    for _, e in ipairs(seen) do if e.name == M.SPELL_EVENT and #e.args > 0 then fb = e; break end end
    if not fb then Log.Write("Genome: no " .. M.SPELL_EVENT .. " event captured (cast Fire Bolt the vanilla way while logging)"); return end
    -- Roles: which arg held which of Fire Bolt's SpellAnimation ids.
    local slots = SpellAnims.Slots(TEMPLATE_SPELL)
    local idRole = {}
    for role, slot in pairs(SpellAnims.SLOTS) do if slots[slot] then idRole[slots[slot]:lower()] = role end end
    local lines = { "# genome spell event template (captured from " .. TEMPLATE_SPELL .. ")" }
    for i, a in ipairs(fb.args) do
        local role = idRole[a.Value:lower()] or "-"
        lines[#lines + 1] = string.format("arg|%d|%s|%s|%s", i - 1, a.Type, a.Value, role)
    end
    -- Cancel candidate: the first non-spell, non-side event after the last
    -- spell event of the capture.
    local lastSpell = 0
    for i, e in ipairs(seen) do if e.name == M.SPELL_EVENT then lastSpell = i end end
    local cancel = nil
    for i = lastSpell + 1, #seen do
        local n = seen[i].name
        if n ~= M.SPELL_EVENT and not SIDE[n] then cancel = n; break end
    end
    lines[#lines + 1] = "cancel|" .. (cancel or "-")
    pcall(Ext.IO.SaveFile, TEMPLATE_PATH, table.concat(lines, "\n") .. "\n")
    Log.Write(string.format("Genome: template saved (%d args, cancel=%s) -> %s", #fb.args, tostring(cancel), TEMPLATE_PATH))
    template = nil
end

local function loadTemplate()
    if template ~= nil then return template or nil end
    template = false
    local ok, s = pcall(Ext.IO.LoadFile, TEMPLATE_PATH)
    if not ok or not s then return nil end
    local t = { args = {}, roles = {}, cancel = nil }
    for line in s:gmatch("[^\r\n]+") do
        local i, ty, val, role = line:match("^arg|(%d+)|([^|]*)|([^|]*)|(.*)$")
        if i then
            t.args[tonumber(i) + 1] = { Type = ty, Value = val }
            if role ~= "-" then t.roles[tonumber(i) + 1] = role end
        end
        local c = line:match("^cancel|(.*)$")
        if c and c ~= "-" then t.cancel = c end
    end
    if #t.args > 0 then template = t end
    return template or nil
end
function M.Template() return loadTemplate() end

-- Coerce a logged value back to what the Lua setter expects.
local function value(a)
    if a.Type == "Bool" then return a.Value == "true" end
    local n = tonumber(a.Value)
    if n and (a.Type == "Enum" or a.Type == "Int" or a.Type == "Float") then return n end
    return a.Value
end

-- Queue the spell event for `anims` (SpellAnims.For result). Returns ok, why.
function M.PlaySpell(ent, anims)
    local t = loadTemplate()
    if not t then return false, "no template (run the !dag_genome_events capture once)" end
    local args = {}
    for i, a in ipairs(t.args) do
        local v = value(a)
        local role = t.roles[i]
        if role and anims[role] then v = anims[role].key end
        args[i] = { Type = a.Type, Value = v }
    end
    local ok, err = pcall(function()
        Ext.System.AnimationBlueprint:QueueGameplayEventToGenome(ent, M.SPELL_EVENT, args)
    end)
    if not ok then return false, tostring(err) end
    return true, "genome event"
end

function M.Cancel(ent)
    local t = loadTemplate()
    if not t or not t.cancel then return false, "no cancel event captured" end
    local ok, err = pcall(function() Ext.System.AnimationBlueprint:QueueGameplayEventToGenome(ent, t.cancel, {}) end)
    return ok, ok and ("event " .. t.cancel) or tostring(err)
end

function M.Register()
    Ext.Events.Tick:Subscribe(function() if logging then pcall(poll) end end)
    Ext.RegisterConsoleCommand("dag_genome_events", function(_, a)
        if a == "on" or a == "1" then
            logging, seen = true, {}
            Log.Write("Genome: logging the player's animation gameplay events. Cast Fire Bolt vanilla, then select + right-click cancel, then !dag_genome_events off")
        else
            logging = false
            Log.Write(string.format("Genome: logging off, %d events", #seen))
            saveTemplate()
        end
    end)
end

return M
