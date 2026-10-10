-- SPDX-License-Identifier: GPL-3.0-or-later
-- BG3's spell animation events (docs/spikes/genome-capture.md).
--
-- Vanilla casts don't use Osi.PlayAnimation: the client sends gameplay
-- events to the character's animation blueprint, which plays the clips. No
-- Osiris task, so nothing roots the character. Full body (the vanilla graph
-- has no upper body layer): legs hold the cast pose while walking (accepted
-- 2026-10-10).
--
-- Layouts captured natively from a vanilla Fire Bolt (2026-10-10, capture
-- round 2, native-genome-capture.txt):
--   SELECT e8545375-...  9 args, sent when a spell is selected:
--     0 AnimationSimpleName = prepare id (SpellAnimation slot 0)
--     1, 2 AnimationSimpleName = null
--     3 AnimationSimpleName = loop id (slot 4)
--     4, 5 AnimationSimpleName = null
--     6 Bool false, 7 Enum 0, 8 Enum 0
--     The blueprint plays prepare, then holds loop.
--   CANCEL e9db2a81-...  1 arg, sent on right-click cancel:
--     0 AnimationSimpleName = the spell's slot 6 id (the un-prepare clip)
--   CAST ba293d56-...  21 args with cast sets + recover; we don't send it,
--     the engine does when the server's UseSpell runs.
-- An empty Lua string becomes the null FixedString (SE CreateFixedString),
-- the same value vanilla puts in unused slots.
--
--   !dag_genome_events on|off   native capture of every event to the
--                               blueprint -> native-genome-capture.txt

local Log     = Ext.Require("Shared/Log.lua")
local spells  = Ext.Require("data/spells.lua")
local FullPov = Ext.Require("FullPov.lua")

local M = {}

M.SELECT_EVENT = "e8545375-1537-4eba-b045-0cee8a0ad64c"
M.CANCEL_EVENT = "e9db2a81-877d-436f-8a8f-7b17e1d588d1"

local function asn(id) return { Type = "AnimationSimpleName", Value = id or "" } end

local function handleHex(ent)
    local ok, n = pcall(Ext.Utils.HandleToInteger, ent)
    return ok and n and string.format("0x%016X", n) or tostring(ent)
end

local function queue(ent, event, args)
    return pcall(function() Ext.System.AnimationBlueprint:QueueGameplayEventToGenome(ent, event, args) end)
end

-- Play `anims` (SpellAnims.For result): prepare, then the held loop.
-- Returns ok, how.
function M.PlaySpell(ent, anims)
    local prep, loop = anims.prepare and anims.prepare.key, anims.loop and anims.loop.key
    if not prep and not loop then return false, "no prepare or loop id" end
    local args = { asn(prep), asn(), asn(), asn(loop), asn(), asn(),
        { Type = "Bool", Value = false }, { Type = "Enum", Value = 0 }, { Type = "Enum", Value = 0 } }
    local ok, err = queue(ent, M.SELECT_EVENT, args)
    if not ok then return false, tostring(err) end
    return true, "select event to " .. handleHex(ent)
end

-- Leave the prepare / loop with the spell's own un-prepare clip (slot 6,
-- else the fallback family's).
function M.Cancel(ent, anims)
    local fb = spells.spell_anims and spells.spell_anims.fallback or {}
    local id = (anims and anims.slot6) or fb.cancel
    if not id then return false, "no cancel clip id" end
    local ok, err = queue(ent, M.CANCEL_EVENT, { asn(id) })
    if not ok then return false, tostring(err) end
    return true, "cancel event " .. id:sub(1, 8) .. ((anims and anims.slot6) and "" or " (fallback)")
end

function M.Register()
    Ext.RegisterConsoleCommand("dag_genome_events", function(_, a)
        local on = (a == "on" or a == "1")
        FullPov.SetGenomeCapture(on)
        Log.Write("Genome: native capture " .. (on and "ON -> native-genome-capture.txt" or "OFF"))
    end)
end

return M
