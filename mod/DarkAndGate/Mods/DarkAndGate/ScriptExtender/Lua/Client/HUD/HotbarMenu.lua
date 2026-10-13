-- SPDX-License-Identifier: GPL-3.0-or-later
-- Prepare Hotbar menu: bind the character's spells to our 1..0 hotbar.
--
-- DESIGN wants a "Hotbar" tab inside BG3's own character menu. That means
-- overriding BG3's Noesis pages (conflicts with UI mods, breaks on patches;
-- ROADMAP M4, spike 8), so for now it is our own ImGui window, opened
-- beside BG3's panels (developer, 2026-10-12: "if the vanilla menu is too
-- hard, we can make a custom menu"):
--   * shows by itself while I (inventory / spells / alchemy) or Tab (party
--     view) is open in first person (data/hud.lua hotbar_menu_with);
--   * H pins it open (and frees the cursor) anywhere in first person;
--   * click a slot, then click a spell: it goes into that slot and the
--     selection moves to the next empty slot. "Clear slot" / "Defaults".
-- The list = the character's spell container (what BG3 offers on its own
-- hotbar: cantrips, prepared and always-prepared spells, item spells),
-- spells only (IsSpell), grouped by level, filterable by name. Slots are
-- saved per character (Client/Combat/Hotbar.lua); the server checks the
-- caster really has a bound spell (Server/Combat/SpellCast.lua).
--
--   !dag_hotbar_menu         toggle (same as H)

local Log       = Ext.Require("Shared/Log.lua")
local State     = Ext.Require("Client/Combat/State.lua")
local Hotbar    = Ext.Require("Client/Combat/Hotbar.lua")
local SpellDefs = Ext.Require("Shared/SpellDefs.lua")
local cfg       = Ext.Require("data/hud.lua")
local dataSpells = Ext.Require("data/spells.lua")
local WindowFlags = Ext.Require("Client/HUD/WindowFlags.lua")
local PlayFlag  = Ext.Require("Client/PlayFlag.lua")

local M = {}

local pinned = false
local ui = nil          -- { win, slots (group), list (group), info (text), filterBox }
local shown = false
local selected = 1
local filter = ""
local slotSig, listSig = nil, nil
local lastScan, spells = -1e9, {}

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local function set(e, k, v) if e then pcall(function() e[k] = v end) end end

local function viewport()
    local ok, v = pcall(Ext.IMGUI.GetViewportSize)
    if ok and v then
        local w, h = tonumber(v[1] or v.x), tonumber(v[2] or v.y)
        if w and h and w > 0 then return w, h end
    end
    return 1920, 1080
end

local function player()
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    return ok and ents and ents[1] or nil
end

-- The character's spells: { id, def } sorted by level, then name.
local function scanSpells()
    local me = player()
    local out, seen = {}, {}
    local function add(id)
        id = id and tostring(id) or ""
        if id == "" or seen[id] then return end
        seen[id] = true
        local d = SpellDefs.Get(id)
        if d and (d.is_spell ~= false) then out[#out + 1] = { id = id, def = d } end
    end
    if me then
        pcall(function() for _, m in ipairs(me.SpellContainer.Spells) do add(m.SpellId.OriginatorPrototype) end end)
        if #out == 0 then
            pcall(function() for _, sd in ipairs(me.SpellBook.Spells) do add(sd.Id.OriginatorPrototype) end end)
        end
    end
    -- data/spells.lua's slice spells are offered too (the M1b test set),
    -- except in play mode (!dag_play): only the character's own spells.
    if not PlayFlag.On() then
        for id in pairs(dataSpells.spells) do add(id) end
    end
    table.sort(out, function(a, b)
        local la, lb = a.def.level or 0, b.def.level or 0
        if la ~= lb then return la < lb end
        return tostring(a.def.label) < tostring(b.def.label)
    end)
    return out
end

local function slotLabel(i) return cfg.keys[i] or tostring(i) end

local function clearChildren(group, list)
    for _, e in ipairs(list or {}) do pcall(function() e:Destroy() end) end
end

-- Slot frame colours (developer, 2026-10-12: "highlight the slot"): the
-- selected slot gets a gold frame, the slot a spell just went into flashes
-- green for menu_flash_ms. An image button's frame is its "Button" colour
-- around the icon (FramePadding wide); "Background" only shows through
-- transparent icon pixels, which is why the first build's highlight was
-- invisible.
local FRAME = {
    selected = { 1.00, 0.78, 0.25, 1.00 },
    flash    = { 0.35, 0.85, 0.35, 1.00 },
    normal   = { 0.30, 0.26, 0.20, 0.70 },
}
local flash = { slot = nil, untilMs = 0 }

local function frame(e, color)
    for _, c in ipairs({ "Button", "ButtonHovered", "ButtonActive", "Border" }) do
        pcall(function() e:SetColor(c, color) end)
    end
    pcall(function() e:SetStyle("FramePadding", 5, 5) end)
    pcall(function() e:SetStyle("FrameBorderSize", 2) end)
end

local function assign(id)
    Hotbar.SetSlot(selected, id)
    Log.Write(string.format("HotbarMenu: slot %s = %s", slotLabel(selected), tostring(id)))
    flash.slot, flash.untilMs = selected, now() + (cfg.menu_flash_ms or 700)
    -- next empty slot
    for k = 1, 10 do
        local j = ((selected - 1 + k) % 10) + 1
        if not State.hotbar[j] then selected = j; return end
    end
end

local function buildSlots()
    clearChildren(ui.slots, ui.slotKids)
    ui.slotKids = {}
    local kids = ui.slotKids
    local flashing = flash.slot and now() < flash.untilMs
    for i = 1, 10 do
        local id = State.hotbar[i]
        local d = id and SpellDefs.Get(id) or nil
        local e
        if d and d.icon and d.icon ~= "" then
            e = ui.slots:AddImageButton("##dag_slot" .. i, d.icon, { 44, 44 })
        else
            e = ui.slots:AddButton((i == selected and "[" .. slotLabel(i) .. "]" or (" " .. slotLabel(i) .. " ")) .. "##dag_slot" .. i)
            pcall(function() e.Size = { 54, 54 } end)
        end
        frame(e, (flashing and i == flash.slot) and FRAME.flash or (i == selected and FRAME.selected or FRAME.normal))
        set(e, "SameLine", i > 1)
        pcall(function()
            e:Tooltip():AddText(string.format("Key %s: %s%s", slotLabel(i), d and d.label or "empty",
                d and string.format(" (%d mana)", SpellDefs.Cost(id)) or ""))
        end)
        set(e, "OnClick", function()
            selected = i
            slotSig = nil
        end)
        kids[#kids + 1] = e
    end
    local id = State.hotbar[selected]
    local d = id and SpellDefs.Get(id) or nil
    local t = ui.slots:AddText(string.format("Selected: key %s = %s. Click a spell below to put it there.", slotLabel(selected),
        d and d.label or "empty"))
    pcall(function() t:SetColor("Text", FRAME.selected) end)
    kids[#kids + 1] = t
end

local LEVEL_NAME = { [0] = "Cantrips" }

local function buildList()
    clearChildren(ui.list, ui.listKids)
    ui.listKids = {}
    local kids = ui.listKids
    local f = filter:lower()
    local lastLevel, n = nil, 0
    for _, s in ipairs(spells) do
        local d = s.def
        local name = tostring(d.label or s.id)
        if f == "" or name:lower():find(f, 1, true) or s.id:lower():find(f, 1, true) then
            if d.level ~= lastLevel then
                lastLevel = d.level
                kids[#kids + 1] = ui.list:AddSeparatorText(LEVEL_NAME[d.level or 0] or ("Level " .. tostring(d.level)))
            end
            local icon
            if d.icon and d.icon ~= "" then
                icon = ui.list:AddImageButton("##dag_sp_" .. s.id, d.icon, { 36, 36 })
                set(icon, "OnClick", function() assign(s.id); slotSig = nil end)
                kids[#kids + 1] = icon
            end
            local cost = SpellDefs.Cost(s.id)
            local b = ui.list:AddButton(string.format("%s  (%s)##dag_spb_%s", name, cost > 0 and (cost .. " mana") or "free", s.id))
            set(b, "SameLine", icon ~= nil)
            set(b, "OnClick", function() assign(s.id); slotSig = nil end)
            kids[#kids + 1] = b
            n = n + 1
        end
    end
    if n == 0 then kids[#kids + 1] = ui.list:AddText(#spells == 0 and "No spells found for this character." or "No spell matches the filter.") end
end

local function build()
    local vw, vh = viewport()
    local w = Ext.IMGUI.NewWindow("Prepare Hotbar##DAG_HotbarMenu")
    set(w, "Closeable", false)
    local bad = WindowFlags.Set(w, { "NoSavedSettings", "NoCollapse" })
    if #bad > 0 then Log.Write("HotbarMenu: flags not set: " .. table.concat(bad, ", ")) end
    pcall(function() w:SetPos({ vw - 480, 90 }) end)
    pcall(function() w:SetSize({ 460, math.max(420, vh - 260) }) end)
    local u = { win = w }
    u.head = w:AddText("Your first-person hotbar, keys 1-0. Pick a slot, then a spell.")
    u.slots = w:AddGroup("dag_slots")
    u.buttons = w:AddGroup("dag_buttons")
    local clear = u.buttons:AddButton("Clear slot")
    set(clear, "OnClick", function() Hotbar.SetSlot(selected, nil); slotSig = nil end)
    local reset = u.buttons:AddButton("Defaults")
    set(reset, "SameLine", true)
    set(reset, "OnClick", function() Hotbar.Reset(); slotSig = nil end)
    local box = w:AddInputText("##dag_filter", filter)
    set(box, "Hint", "Search spells")
    set(box, "OnChange", function(e)
        local okT, t = pcall(function() return e.Text end)
        filter = okT and tostring(t or "") or ""
        listSig = nil
    end)
    u.list = w:AddGroup("dag_list")
    ui = u
    slotSig, listSig = nil, nil
    Log.Write("HotbarMenu: built")
end

local function setShown(on)
    if shown == on then return end
    shown = on
    if ui then set(ui.win, "Open", on); set(ui.win, "Visible", on) end
end

-- Called every tick by the HUD with whether a BG3 panel that carries the
-- menu is open (menuName).
function M.Update(active, menuName)
    local want = active and (pinned or (menuName ~= nil and (function()
        for _, n in ipairs(cfg.hotbar_menu_with or {}) do if n == menuName then return true end end
        return false
    end)()))
    if not want then setShown(false); return end
    if not ui then
        local ok, err = pcall(build)
        if not ok then Log.Write("HotbarMenu: build failed " .. tostring(err)); pinned = false; return end
    end
    setShown(true)
    local t = now()
    if t - lastScan > 1000 then
        lastScan = t
        local list = scanSpells()
        local ids = {}
        for _, s in ipairs(list) do ids[#ids + 1] = s.id end
        local sig = table.concat(ids, ",")
        if sig ~= M.spellSig then M.spellSig = sig; spells = list; listSig = nil end
    end
    local hs = {}
    for i = 1, 10 do hs[i] = tostring(State.hotbar[i] or "") end
    local fl = (flash.slot and t < flash.untilMs) and flash.slot or 0
    local s1 = selected .. "|" .. table.concat(hs, ",") .. "|" .. fl
    if s1 ~= slotSig then slotSig = s1; pcall(buildSlots) end
    local s2 = filter .. "|" .. (M.spellSig or "")
    if s2 ~= listSig then listSig = s2; pcall(buildList) end
end

function M.TogglePinned()
    pinned = not pinned
    Log.Write("HotbarMenu: " .. (pinned and "pinned open (H again closes)" or "closed"))
end
function M.Pinned() return pinned end
function M.Shown() return shown end
-- The slot the next picked spell goes into (the HUD glows it while the menu is up).
function M.Selected() return shown and selected or nil end

function M.Register()
    Ext.RegisterConsoleCommand("dag_hotbar_menu", function() M.TogglePinned() end)
end

return M
