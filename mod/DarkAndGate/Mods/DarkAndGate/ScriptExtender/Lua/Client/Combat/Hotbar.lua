-- SPDX-License-Identifier: GPL-3.0-or-later
-- Hotbar: 10 slots (keys 1..0). Bound in the Prepare Hotbar menu
-- (Client/HUD/HotbarMenu.lua; H or BG3's I / Tab panels), or with
-- !dag_hotbar <slot> <spellId>.
--
-- Slot value = a spell id (any spell the character has; Shared/SpellDefs.lua).
-- Saved per character in DarkAndGate/hotbar-<uuid>.json (client file, so it
-- survives reloads); a character without a saved layout gets data/spells.lua
-- default_hotbar (the M1b test set), or in play mode (!dag_play,
-- Client/PlayFlag.lua) its own spells: cantrips first, then by level, damage
-- spells first within a level, re-read each session until you bind a slot.
-- (DESIGN: hotbars move into the save, server-owned, with the M4 native tab /
-- multiplayer.)

local Log    = Ext.Require("Shared/Log.lua")
local State  = Ext.Require("Client/Combat/State.lua")
local Spells = Ext.Require("Client/Combat/Spells.lua")
local spells = Ext.Require("data/spells.lua")
local Prepare = Ext.Require("Client/Combat/Prepare.lua")
local Targeting = Ext.Require("Client/Combat/Targeting.lua")
local Net       = Ext.Require("Shared/Net.lua")
local ClientNet = Ext.Require("Client/Net.lua")
local SpellDefs = Ext.Require("Shared/SpellDefs.lua")
local PlayFlag  = Ext.Require("Client/PlayFlag.lua")
local Me = Ext.Require("Client/Me.lua")   -- the local player's character (multiplayer)

local function sendArm(id, castTime)
    ClientNet.Send(Net.Channels.SpellArm, { spell = id, castTime = castTime })
end

local M = {}

local owner = nil   -- uuid the current State.hotbar belongs to
local needOwn = false   -- play mode, no saved layout, no spells read yet: try again

local function path(uuid) return "DarkAndGate/hotbar-" .. tostring(uuid) .. ".json" end

local function save()
    if not owner then return end
    local t = {}
    for i = 1, 10 do t[tostring(i)] = State.hotbar[i] or "" end
    pcall(Ext.IO.SaveFile, path(owner), Ext.Json.Stringify(t))
end

local function hasSaved(uuid)
    local ok, txt = pcall(Ext.IO.LoadFile, path(uuid))
    return ok and txt ~= nil and txt ~= ""
end

-- The controlled character's own spells for a fresh layout (play mode): what
-- BG3 offers on its own hotbar (spell container, else the spellbook), spells
-- only, by level, damage spells first within a level, at most 10.
local function ownSpells()
    local me = nil
    pcall(function() me = Me.All()[1] end)
    if not me then return nil end
    local list, seen = {}, {}
    local function add(id)
        id = id and tostring(id) or ""
        if id == "" or seen[id] then return end
        seen[id] = true
        local d = SpellDefs.Get(id)
        if not d or d.is_spell == false then return end
        local dmg = false
        pcall(function()
            local st = Ext.Stats.Get(id)
            local tdl = tostring(st.TooltipDamageList or "")
            local dt = tostring(st.DamageType or "")
            dmg = (tdl ~= "" and tdl ~= "nil") or (dt ~= "" and dt ~= "None" and dt ~= "nil")
        end)
        list[#list + 1] = { id = id, level = d.level or 0, dmg = dmg, label = tostring(d.label or id) }
    end
    pcall(function() for _, m in ipairs(me.SpellContainer.Spells) do add(m.SpellId.OriginatorPrototype) end end)
    if #list == 0 then
        pcall(function() for _, sd in ipairs(me.SpellBook.Spells) do add(sd.Id.OriginatorPrototype) end end)
    end
    table.sort(list, function(a, b)
        if a.level ~= b.level then return a.level < b.level end
        if a.dmg ~= b.dmg then return a.dmg end
        return a.label < b.label
    end)
    local out = {}
    for i = 1, math.min(10, #list) do out[i] = list[i].id end
    return out
end

-- The layout of a character with none saved: its own spells in play mode,
-- else data/spells.lua default_hotbar (the M1b test set).
local function seedDefaults(why)
    for i = 1, 10 do State.hotbar[i] = nil end
    needOwn = false
    if PlayFlag.On() then
        local own = ownSpells()
        if own and #own > 0 then
            for i, id in ipairs(own) do State.hotbar[i] = id end
            Log.Write(string.format("Hotbar: %s -> your own spells (!dag_play): %s", why, table.concat(own, ", ")))
            return
        end
        needOwn = true
        Log.Write("Hotbar: " .. why .. " -> no spells on the character yet, trying again (play mode)")
        return
    end
    for slot, id in pairs(spells.default_hotbar) do State.hotbar[slot] = id end
    Log.Write("Hotbar: " .. why .. " -> default DEV-SAVE layout")
end

-- Switch State.hotbar to `uuid`'s saved layout (or the defaults).
local function load(uuid)
    owner = uuid
    -- A retry left over from before the character was known (Register seeds
    -- with no owner) must not overwrite the saved layout loaded here.
    needOwn = false
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
        seedDefaults("no saved layout for " .. tostring(uuid))
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
    if empty and not needOwn then seedDefaults("empty hotbar") end
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
    seedDefaults("reset")
    save()
end

-- Follow the controlled character (party switch): its own saved layout.
local lastCheck = -1e9
local function tick()
    local t = tonumber(Ext.Timer.MonotonicTime()) or 0
    if t - lastCheck < 500 then return end
    lastCheck = t
    local okE, ents = pcall(Me.All)
    local me = okE and ents and ents[1] or nil
    if not me then return end
    local okU, uuid = pcall(function() return tostring(me.Uuid.EntityUuid) end)
    if okU and uuid and uuid ~= owner then load(uuid)
    elseif needOwn and owner and not PlayFlag.InCC() and t % 2000 < 500 then seedDefaults("spells read again") end
end

function M.Register()
    ensureDefault()
    -- !dag_play turned on / off: a character with no saved layout follows it.
    PlayFlag.OnChange(function()
        if owner and not hasSaved(owner) then seedDefaults("play mode " .. (PlayFlag.On() and "on" or "off")) end
    end)
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
