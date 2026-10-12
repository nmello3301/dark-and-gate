-- SPDX-License-Identifier: GPL-3.0-or-later
-- Hide / restore BG3's own HUD widgets (docs/spikes/hud-tech.md, lever A):
-- each named widget under Ext.UI.GetRoot():Find("ContentRoot") gets
-- Visibility = "Collapsed"; the value it had is remembered and written back
-- on Restore. Brawl finds the same widgets by name (credited in the spike).
--
--   VanillaHud.Hide()      collapse (and re-apply every reapply_s)
--   VanillaHud.Restore()   put every widget back as it was
--   VanillaHud.MenuOpen()  a menu widget (data/hud.lua menu_widgets) is visible
--   VanillaHud.Names()     "Name=Visibility" for every ContentRoot child (debug)

local Log = Ext.Require("Shared/Log.lua")
local cfg = Ext.Require("data/hud.lua")

local M = {}

local hidden = false
local saved = {}        -- name -> original Visibility string
local lastApply = -1e9
local loggedMissing = {}

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

-- The remembered values also go to a file, so a Lua `reset` (which wipes
-- this table) can't leave BG3's HUD hidden: Recover() at load puts them back.
local SAVE_PATH = "DarkAndGate/vanilla-hud-hidden.json"
local function persist()
    local n = 0
    for _ in pairs(saved) do n = n + 1 end
    pcall(Ext.IO.SaveFile, SAVE_PATH, n > 0 and Ext.Json.Stringify(saved) or "{}")
end

local function contentRoot()
    local ok, r = pcall(function() return Ext.UI.GetRoot():Find("ContentRoot") end)
    return ok and r or nil
end

local function children()
    local root = contentRoot()
    local out = {}
    if not root then return out end
    pcall(function()
        for _, c in ipairs(root.Children) do
            local okN, n = pcall(function() return tostring(c.Name) end)
            if okN and n and n ~= "" then out[n] = c end
        end
    end)
    return out
end

local function vis(w)
    local ok, v = pcall(function() return tostring(w.Visibility) end)
    return ok and v or "?"
end

local function setVis(w, v)
    local ok = pcall(function() w.Visibility = v end)
    if not ok then ok = pcall(function() w:SetProperty("Visibility", v) end) end
    return ok
end

local function apply(why)
    lastApply = now()
    local kids = children()
    local done, missing = {}, {}
    for _, name in ipairs(cfg.hide_vanilla) do
        local w = kids[name]
        if w then
            local v = vis(w)
            if v ~= "Collapsed" then
                if saved[name] == nil then saved[name] = v; persist() end
                if setVis(w, "Collapsed") then done[#done + 1] = name end
            end
        elseif not loggedMissing[name] then
            loggedMissing[name] = true
            missing[#missing + 1] = name
        end
    end
    if #done > 0 or #missing > 0 then
        Log.Write(string.format("VanillaHud: hidden %s (%s)%s", #done > 0 and table.concat(done, ", ") or "nothing new", why,
            #missing > 0 and (" -- not found: " .. table.concat(missing, ", ")) or ""))
    end
end

function M.Hide(why)
    if not hidden then
        hidden = true
        apply(why or "hide")
    end
end

function M.Restore(why)
    if not hidden then return end
    hidden = false
    local kids = children()
    local back = {}
    for name, v in pairs(saved) do
        local w = kids[name]
        if w and setVis(w, (v ~= "?" and v) or "Visible") then back[#back + 1] = name end
    end
    saved = {}
    persist()
    Log.Write(string.format("VanillaHud: restored %s (%s)", #back > 0 and table.concat(back, ", ") or "nothing", why or "restore"))
end

function M.Hidden() return hidden end

-- At load: widgets a previous Lua state hid (and never restored) come back.
function M.Recover()
    local ok, txt = pcall(Ext.IO.LoadFile, SAVE_PATH)
    if not ok or not txt or txt == "" or txt == "{}" then return end
    local okJ, old = pcall(Ext.Json.Parse, txt)
    if not okJ or type(old) ~= "table" then return end
    local kids = children()
    local back = {}
    for name, v in pairs(old) do
        local w = kids[name]
        if w and setVis(w, (v ~= "?" and v) or "Visible") then back[#back + 1] = name end
    end
    pcall(Ext.IO.SaveFile, SAVE_PATH, "{}")
    Log.Write("VanillaHud: recovered after reset: " .. (#back > 0 and table.concat(back, ", ") or "nothing (UI not ready?)"))
end

-- A visible menu widget means the player is in a menu.
local menuCache = { at = -1e9, open = false, name = nil }
function M.MenuOpen()
    local t = now()
    if t - menuCache.at < 250 then return menuCache.open, menuCache.name end
    menuCache.at = t
    local kids = children()
    menuCache.open, menuCache.name = false, nil
    for _, name in ipairs(cfg.menu_widgets) do
        local w = kids[name]
        if w and vis(w) == "Visible" then menuCache.open, menuCache.name = true, name; break end
    end
    return menuCache.open, menuCache.name
end

function M.Names()
    local parts = {}
    for name, w in pairs(children()) do parts[#parts + 1] = name .. "=" .. vis(w) end
    table.sort(parts)
    return table.concat(parts, ", ")
end

-- Call every tick: re-collapse widgets the game made visible again.
function M.Tick()
    if hidden and now() - lastApply > (cfg.reapply_s or 1.0) * 1000 then pcall(apply, "re-apply") end
end

return M
