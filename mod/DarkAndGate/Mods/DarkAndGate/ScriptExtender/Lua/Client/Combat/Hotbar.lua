-- SPDX-License-Identifier: GPL-3.0-or-later
-- Hotbar: 10 slots (keys 1..0). Bound in the Prepare Hotbar menu
-- (Client/HUD/HotbarMenu.lua; H or BG3's I / Tab panels), or with
-- !dag_hotbar <slot> <spellId>.
--
-- Slot value = a spell id (any spell the character has; Shared/SpellDefs.lua).
-- Saved per character in DarkAndGate/hotbar-<uuid>.json (client file, so it
-- survives reloads); a character without a saved layout gets data/spells.lua
-- default_hotbar. (DESIGN: hotbars move into the save, server-owned, with
-- the M4 native tab / multiplayer.)

local Log    = Ext.Require("Shared/Log.lua")
local State  = Ext.Require("Client/Combat/State.lua")
local Spells = Ext.Require("Client/Combat/Spells.lua")
local spells = Ext.Require("data/spells.lua")
local Prepare = Ext.Require("Client/Combat/Prepare.lua")
local Targeting = Ext.Require("Client/Combat/Targeting.lua")
local Net       = Ext.Require("Shared/Net.lua")
local ClientNet = Ext.Require("Client/Net.lua")

local function sendArm(id, castTime)
    ClientNet.Send(Net.Channels.SpellArm, { spell = id, castTime = castTime })
end

local M = {}

local owner = nil   -- uuid the current State.hotbar belongs to

local function path(uuid) return "DarkAndGate/hotbar-" .. tostring(uuid) .. ".json" end

local function save()
    if not owner then return end
    local t = {}
    for i = 1, 10 do t[tostring(i)] = State.hotbar[i] or "" end
    pcall(Ext.IO.SaveFile, path(owner), Ext.Json.Stringify(t))
end

-- Switch State.hotbar to `uuid`'s saved layout (or the defaults).
local function load(uuid)
    owner = uuid
    for i = 1, 10 do State.hotbar[i] = nil end
    local ok, txt = pcall(Ext.IO.LoadFile, path(uuid))
    local okJ, t = false, nil
    if ok and txt and txt ~= "" then okJ, t = pcall(Ext.Json.Parse, txt) end
    if okJ and type(t) == "table" then
        for i = 1, 10 do
            local v = t[tostring(i)]
            if v and v ~= "" then State.hotbar[i] = v end
        end
        Log.Write("Hotbar: loaded the saved layout of " .. tostring(uuid))
    else
        for slot, id in pairs(spells.default_hotbar) do State.hotbar[slot] = id end
        Log.Write("Hotbar: no saved layout for " .. tostring(uuid) .. ", defaults")
    end
end

-- Bind slot i (1..10) to spell id (nil clears). Saved at once.
function M.SetSlot(i, id)
    if not i or i < 1 or i > 10 then return end
    State.hotbar[i] = (id and id ~= "") and id or nil
    save()
end

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
        -- A targeted spell with targets picked: the key again fires early.
        if Targeting.OnSameSlot() then return end
        State.armedSpell = nil
        State.armedAt = nil
        State.armedCastTime = nil
        sendArm(nil)
        Log.Write("Hotbar: UNARMED " .. id .. " (same slot re-pressed)")
        Prepare.Stop("cancel-key")
        return
    end
    -- Channelled casting: arming starts the cast (prepare animation, cast
    -- time counting); LMB releases it once the cast time has passed.
    State.armedSpell = id
    State.armedAt = tonumber(Ext.Timer.MonotonicTime()) or 0
    State.armedCastTime = Spells.CastTime(id)
    sendArm(id, State.armedCastTime)
    Log.Write(string.format("Hotbar: CASTING slot %d = %s (release with LMB after %.1fs; RMB or same slot cancels)",
        slot, id, Spells.CastTime(id)))
    Prepare.Start(id)
end

function M.Reset()
    for i = 1, 10 do State.hotbar[i] = nil end
    ensureDefault()
    save()
end

-- Follow the controlled character (party switch): its own saved layout.
local lastCheck = -1e9
local function tick()
    local t = tonumber(Ext.Timer.MonotonicTime()) or 0
    if t - lastCheck < 500 then return end
    lastCheck = t
    local okE, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    local me = okE and ents and ents[1] or nil
    if not me then return end
    local okU, uuid = pcall(function() return tostring(me.Uuid.EntityUuid) end)
    if okU and uuid and uuid ~= owner then load(uuid) end
end

function M.Register()
    ensureDefault()
    Prepare.Register()
    Spells.Register()
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
    Ext.RegisterConsoleCommand("dag_hotbar", function(_, slotArg, id)
        local slot = tonumber(slotArg)
        if not slot or slot < 1 or slot > 10 then
            Log.Write("Hotbar: usage !dag_hotbar <1-10> <spellId>"); return
        end
        M.SetSlot(slot, id)
        Log.Write(string.format("Hotbar: slot %d = %s", slot, tostring(State.hotbar[slot])))
    end)
    Ext.RegisterConsoleCommand("dag_hotbar_reset", function()
        M.Reset()
        Log.Write("Hotbar: reset to defaults")
    end)
    Log.Write("Hotbar: registered (keys 1-0; layouts saved per character; menu: H, or BG3's I / Tab panels)")
end

return M
