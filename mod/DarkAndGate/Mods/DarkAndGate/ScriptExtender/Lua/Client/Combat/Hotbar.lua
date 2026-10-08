-- SPDX-License-Identifier: GPL-3.0-or-later
-- Minimal hotbar: 10 slots (keys 1..0). ImGui "Prepare Hotbar" window
-- toggled with H.
--
-- Slot value is a spell id (from data/spells.lua .spells key). Persist via
-- Ext.Vars / ModVars at session boundaries. For M1b, we also seed from
-- data/spells.lua default_hotbar if no saved layout exists.

local Log    = Ext.Require("Shared/Log.lua")
local State  = Ext.Require("Client/Combat/State.lua")
local Spells = Ext.Require("Client/Combat/Spells.lua")
local spells = Ext.Require("data/spells.lua")

local M = {}

local windowOpen = false

local function ensureDefault()
    local empty = true
    for i = 1, 10 do
        if State.hotbar[i] then empty = false; break end
    end
    if empty then
        for slot, id in pairs(spells.default_hotbar) do
            State.hotbar[slot] = id
        end
        Log.Write("Hotbar: seeded with default DEV-SAVE layout")
    end
end

-- Arm-then-cast HARD mode (user requirement):
--   Number key -> arm this slot's spell. LMB casts it; disarm.
--   Same number again -> disarm (quick cancel).
--   Different number  -> re-arm with the new spell.
--   RMB tap is the general cancel path (handled in Input.lua).
function M.PressSlot(slot)
    ensureDefault()
    local id = State.hotbar[slot]
    if not id then
        Log.Write(string.format("Hotbar: slot %d empty", slot))
        return
    end
    if State.armedSpell == id then
        State.armedSpell = nil
        Log.Write("Hotbar: UNARMED " .. id .. " (same slot re-pressed)")
        return
    end
    State.armedSpell = id
    Log.Write(string.format("Hotbar: ARMED slot %d = %s (LMB to cast, RMB or same slot to cancel)",
        slot, id))
end

function M.ToggleWindow()
    windowOpen = not windowOpen
    Log.Write("Hotbar: window " .. (windowOpen and "open" or "closed"))
end

function M.Reset()
    for i = 1, 10 do State.hotbar[i] = nil end
    ensureDefault()
end

-- ImGui rendering ------------------------------------------------------
local function render()
    if not windowOpen then return end
    if not Ext.IMGUI then return end
    -- SE's ImGui binding wraps a per-frame tree. We can't rely on it being
    -- the only ImGui host; keep it simple.
    local ok = pcall(function()
        local w = Ext.IMGUI.NewWindow("Dark and Gate — Prepare Hotbar")
        if not w then return end
        w:AddText("Click a slot, then click a spell on the right to bind.")
        local ids = {}
        for id, _ in pairs(spells.spells) do table.insert(ids, id) end
        table.sort(ids)
        for slot = 1, 10 do
            local label = string.format("Slot %d: %s", slot, State.hotbar[slot] or "(empty)")
            w:AddText(label)
        end
        w:AddText("Known spells: " .. table.concat(ids, ", "))
        -- M4 adds proper drag-drop. For M1b users assign via console:
        w:AddText("Assign via: !dag_hotbar <slot> <spellId>")
    end)
    if not ok then
        -- Older SE builds don't expose Ext.IMGUI.NewWindow. Fall back to a
        -- log print once per toggle.
        if windowOpen then
            Log.Write("Hotbar: ImGui not available; use !dag_hotbar <slot> <id>")
            windowOpen = false
        end
    end
end

function M.Register()
    ensureDefault()
    Ext.Events.Tick:Subscribe(function() pcall(render) end)
    Ext.RegisterConsoleCommand("dag_hotbar", function(_, slotArg, id)
        local slot = tonumber(slotArg)
        if not slot or slot < 1 or slot > 10 then
            Log.Write("Hotbar: usage !dag_hotbar <1-10> <spellId>"); return
        end
        State.hotbar[slot] = id and id ~= "" and id or nil
        Log.Write(string.format("Hotbar: slot %d = %s", slot, tostring(State.hotbar[slot])))
    end)
    Ext.RegisterConsoleCommand("dag_hotbar_reset", function()
        M.Reset()
        Log.Write("Hotbar: reset to defaults")
    end)
    Log.Write("Hotbar: registered (keys 1-0, H toggles window)")
end

return M
