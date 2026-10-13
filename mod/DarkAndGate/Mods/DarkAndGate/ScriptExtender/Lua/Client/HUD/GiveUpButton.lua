-- SPDX-License-Identifier: GPL-3.0-or-later
-- The downed screen's "Give up" button (developer 2026-10-13: "so a player
-- can go to the game over screen if all his teammates are down as well").
-- A small ImGui window under the downed banner (Client/HUD/Overlay.lua draws
-- the banner in a click-through window, so the button needs its own). While
-- it shows, the HUD frees the cursor (Client/HUD/Hud.lua); SE gives a click on
-- it to ImGui alone, so it never reaches the orbit camera or BG3.
-- Client/Downed.lua decides when it shows and what clicking does.
--
--   GiveUpButton.Show(label, onClick, armed)   GiveUpButton.Hide()   GiveUpButton.Shown()

local Log         = Ext.Require("Shared/Log.lua")
local WindowFlags = Ext.Require("Client/HUD/WindowFlags.lua")
local cfg         = Ext.Require("data/hud.lua")

local M = {}

local ui = nil
local shown = false
local handler = nil
local W, H = 300, 56

local function set(e, k, v) if e then pcall(function() e[k] = v end) end end

local function viewport()
    local ok, v = pcall(Ext.IMGUI.GetViewportSize)
    if ok and v then
        local w, h = tonumber(v[1] or v.x), tonumber(v[2] or v.y)
        if w and h and w > 0 then return w, h end
    end
    return 1920, 1080
end

local function colours(btn, armed)
    local base = armed and { 0.80, 0.16, 0.12, 0.95 } or { 0.45, 0.10, 0.09, 0.90 }
    pcall(function() btn:SetColor("Button", base) end)
    pcall(function() btn:SetColor("ButtonHovered", { math.min(1, base[1] + 0.15), base[2] + 0.06, base[3] + 0.05, 1.0 }) end)
    pcall(function() btn:SetColor("ButtonActive", { 0.95, 0.25, 0.18, 1.0 }) end)
end

local function build()
    local win = Ext.IMGUI.NewWindow("##DAG_GiveUp")
    set(win, "Closeable", false)
    local bad = WindowFlags.Set(win, { "NoTitleBar", "NoResize", "NoMove", "NoScrollbar", "NoSavedSettings", "NoCollapse",
        "NoFocusOnAppearing", "NoNav", "NoBackground" })
    if #bad > 0 then Log.Write("GiveUpButton: flags not set: " .. table.concat(bad, ", ")) end
    pcall(function() win.Scaling = "Absolute" end)
    pcall(function() win:SetStyle("WindowPadding", 0, 0) end)
    pcall(function() win:SetStyle("WindowBorderSize", 0) end)
    pcall(function() win:SetStyle("FrameRounding", 6) end)
    pcall(function() win:SetSize({ W, H }) end)
    local btn = win:AddButton("Give up##dag_giveup")
    set(btn, "Size", { W, H })
    set(btn, "Font", "Medium")
    pcall(function() btn:SetColor("Text", cfg.numbers_color) end)
    colours(btn, false)
    set(btn, "OnClick", function()
        Log.Write("GiveUpButton: clicked")
        if handler then pcall(handler) end
    end)
    ui = { win = win, btn = btn, label = nil, armed = nil, vw = nil, vh = nil }
    Log.Write("GiveUpButton: built")
end

-- Under the banner's four lines (Overlay: vh * 0.24, 38 px apart).
local function place()
    local vw, vh = viewport()
    if ui.vw == vw and ui.vh == vh then return end
    ui.vw, ui.vh = vw, vh
    pcall(function() ui.win:SetPos({ math.floor(vw / 2 - W / 2), math.floor(vh * 0.24 + 4 * 38 + 34) }) end)
end

function M.Show(label, onClick, armed)
    handler = onClick
    if not ui then
        local ok, err = pcall(build)
        if not ok then Log.Write("GiveUpButton: build failed " .. tostring(err)); ui = false end
    end
    if not ui then return end
    place()
    if ui.label ~= label then ui.label = label; set(ui.btn, "Label", label .. "##dag_giveup") end
    if ui.armed ~= (armed == true) then ui.armed = (armed == true); colours(ui.btn, ui.armed) end
    if not shown then
        shown = true
        set(ui.win, "Open", true)
        set(ui.win, "Visible", true)
        Log.Write("GiveUpButton: shown (the cursor is free to click it)")
    end
end

function M.Hide()
    if not shown then return end
    shown = false
    if ui then set(ui.win, "Visible", false); set(ui.win, "Open", false) end
    Log.Write("GiveUpButton: hidden")
end

function M.Shown() return shown end

return M
