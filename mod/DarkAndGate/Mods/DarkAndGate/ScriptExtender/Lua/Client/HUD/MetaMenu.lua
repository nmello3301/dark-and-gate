-- SPDX-License-Identifier: GPL-3.0-or-later
-- The Meta-Points menu (docs/DESIGN.md "Meta-Points"; Client/MetaPoints.lua
-- opens it with the hotkey, P by default). An ImGui window like the Prepare
-- Hotbar, in first or third person:
--   * the character (the one you control first; < > for your other party
--     members), their level, points, spent and unspent;
--   * the six stats with what is spent, the pending change and - / +;
--   * every effect: its value now -> after the pending changes (the effects
--     marked * only work while you control that character);
--   * Confirm (sends the pending points; the server checks them) and Reset
--     (drops them); "Reset all points" refunds everything where respec_mode
--     allows it (camp by default), on a second click.
-- In first person it frees the cursor like the hotbar menu (Client/HUD/Hud.lua).
--
--   MetaMenu.Toggle()  MetaMenu.Shown()  MetaMenu.Notice(text, secs)

local Log         = Ext.Require("Shared/Log.lua")
local Net         = Ext.Require("Shared/Net.lua")
local ClientNet   = Ext.Require("Client/Net.lua")
local MetaPoints  = Ext.Require("Shared/MetaPoints.lua")
local MPState     = Ext.Require("Shared/MPState.lua")
local MeleeCooldown = Ext.Require("Shared/MeleeCooldown.lua")
local State       = Ext.Require("Client/Combat/State.lua")
local WindowFlags = Ext.Require("Client/HUD/WindowFlags.lua")
local Me          = Ext.Require("Client/Me.lua")
local spellsData  = Ext.Require("data/spells.lua")
local bowsData    = Ext.Require("data/bows.lua")
local longsword   = Ext.Require("data/weapons/longsword.lua")

local M = {}

local shown = false
local ui = nil              -- { win, body, kids }
local sig = nil
local selected = nil        -- uuid shown
local pending = {}          -- uuid -> { STR = n, ... }
local respecArmedAt = nil
local queryAt = 0
local notice = { ui = nil, untilAt = 0, text = nil }

local GOLD  = { 1.00, 0.78, 0.25, 1.00 }
local GREEN = { 0.45, 0.90, 0.45, 1.00 }
local GREY  = { 0.60, 0.60, 0.60, 1.00 }

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

-- Your party members with Meta-Points state: the one you control first.
local function characters()
    local me = Me.Uuid()
    local myUser = MPState.MyOsiUser()
    local list = {}
    for uuid, st in pairs(MetaPoints.States()) do
        if uuid == me or not myUser or not st.owner or st.owner == myUser then list[#list + 1] = uuid end
    end
    table.sort(list, function(a, b)
        if a == me then return true end
        if b == me then return false end
        local sa, sb = MetaPoints.State(a), MetaPoints.State(b)
        return tostring(sa and sa.name or a) < tostring(sb and sb.name or b)
    end)
    return list
end

local function pendingOf(uuid)
    pending[uuid] = pending[uuid] or {}
    return pending[uuid]
end

local function pendingTotal(uuid)
    local n = 0
    for _, v in pairs(pendingOf(uuid)) do n = n + v end
    return n
end

local function after(st, uuid)
    local p = pendingOf(uuid)
    local t = {}
    for _, s in ipairs(MetaPoints.Config().stats) do t[s] = (st.spent and st.spent[s] or 0) + (p[s] or 0) end
    return t
end

-- The base time of a "time" effect, seconds.
local function baseTime(base)
    if base == "cast_time" then return tonumber(spellsData.base_cast_s) or 2.0 end
    if base == "bow_draw" then return tonumber(bowsData.draw_s) or 3.0 end
    if base == "melee_cooldown" then return MeleeCooldown.Seconds(longsword) end
    return 1.0
end

local function fmtValue(e, v, uuid, spent)
    if e.kind == "fraction" then return string.format("%.0f %%", v * 100) end
    if e.kind == "time" then
        local s = MetaPoints.Floor(baseTime(e.base) * v)
        return string.format("%.2f s", s)
    end
    local txt = string.format("x%.2f", v)
    -- Max mana: the pool it gives the character you control.
    if e.id == "max_mana" and uuid == Me.Uuid() and State.mana and tonumber(State.mana.max) then
        local nowMult = MetaPoints.Value(uuid, e.id) or 1
        if nowMult > 0 then txt = txt .. string.format(" (%d)", math.floor(State.mana.max / nowMult * v + 0.5)) end
    end
    return txt
end

local function send(channel, t) ClientNet.Send(channel, t) end

-- ---------------------------------------------------------------------
-- Building
-- ---------------------------------------------------------------------
local function clear()
    for _, e in ipairs(ui.kids or {}) do pcall(function() e:Destroy() end) end
    ui.kids = {}
end

local function add(e) ui.kids[#ui.kids + 1] = e; return e end

local function text(str, color, sameLine)
    local t = add(ui.body:AddText(str))
    if color then pcall(function() t:SetColor("Text", color) end) end
    if sameLine then set(t, "SameLine", true) end
    return t
end

local function button(label, id, onClick, disabled, sameLine)
    local b = add(ui.body:AddButton(label .. "##dag_meta_" .. id))
    set(b, "SameLine", sameLine == true)
    set(b, "Disabled", disabled == true)
    set(b, "OnClick", function() if not disabled then pcall(onClick) end; sig = nil end)
    return b
end

local function build()
    clear()
    local cfg = MetaPoints.Config()
    local list = characters()
    if not selected or not MetaPoints.State(selected) then selected = list[1] end
    local st = selected and MetaPoints.State(selected) or nil
    if not st then
        text("Waiting for the server's Meta-Points...", GREY)
        button("Close", "close0", function() M.Toggle() end)
        return
    end
    local uuid = selected
    local p = pendingOf(uuid)
    local pend = pendingTotal(uuid)
    local left = (tonumber(st.unspent) or 0) - pend
    local maxPer = tonumber(cfg.max_per_stat) or 96

    text(string.format("%s, level %d", tostring(st.name), tonumber(st.level) or 0), GOLD)
    if #list > 1 then
        local idx = 1
        for i, u in ipairs(list) do if u == uuid then idx = i end end
        button("<", "prev", function() selected = list[(idx - 2) % #list + 1] end, false, true)
        button(">", "next", function() selected = list[idx % #list + 1] end, false, true)
    end
    text(string.format("%d points: %d spent, %d unspent%s", tonumber(st.total) or 0, (tonumber(st.total) or 0) - (tonumber(st.unspent) or 0),
        tonumber(st.unspent) or 0, pend > 0 and string.format(" (%d pending, %d left)", pend, left) or ""))
    add(ui.body:AddSeparatorText("Stats"))
    for _, s in ipairs(cfg.stats) do
        local cur = st.spent and st.spent[s] or 0
        local pd = p[s] or 0
        text(string.format("%-3s %-12s %3d", s, tostring(cfg.stat_names and cfg.stat_names[s] or s), cur))
        local d = text(pd > 0 and string.format("+%d", pd) or "   ", pd > 0 and GREEN or nil, true)
        set(d, "SameLine", true)
        button(" - ", "minus_" .. s, function() p[s] = math.max(0, (p[s] or 0) - 1) end, pd <= 0, true)
        button(" + ", "plus_" .. s, function() p[s] = (p[s] or 0) + 1 end, left <= 0 or cur + pd >= maxPer, true)
        button("+5", "plus5_" .. s, function()
            local n = math.min(5, left, maxPer - cur - pd)
            if n > 0 then p[s] = (p[s] or 0) + n end
        end, left <= 0 or cur + pd >= maxPer, true)
    end
    add(ui.body:AddSeparatorText("Effects (now -> after)"))
    local spentNow, spentAfter = st.spent or {}, after(st, uuid)
    local anyControlled = false
    for _, e in ipairs(cfg.effects) do
        local v0 = MetaPoints.Value(uuid, e.id, spentNow) or 0
        local v1 = MetaPoints.Value(uuid, e.id, spentAfter) or 0
        local a, b = fmtValue(e, v0, uuid, spentNow), fmtValue(e, v1, uuid, spentAfter)
        if e.controlled_only then anyControlled = true end
        local label = string.format("%-3s %s%s", e.stat, tostring(e.label or e.id), e.controlled_only and " *" or "")
        if a ~= b then
            text(string.format("%-26s %s -> %s", label, a, b), GREEN)
        else
            text(string.format("%-26s %s", label, a))
        end
    end
    if anyControlled then text("* only while you control this character (companions on AI don't use it)", GREY) end
    add(ui.body:AddSeparator())
    button("Confirm", "confirm", function()
        send(Net.Channels.MetaConfirm, { uuid = uuid, spent = spentAfter })
        pending[uuid] = {}
        Log.Write(string.format("MetaMenu: confirm %s for %s", Ext.Json.Stringify(spentAfter), tostring(st.name)))
    end, pend <= 0)
    button("Reset", "reset", function() pending[uuid] = {} end, pend <= 0, true)
    local armed = respecArmedAt and now() - respecArmedAt < 3000
    local spentAll = (tonumber(st.total) or 0) - (tonumber(st.unspent) or 0)
    local respecLabel = armed and string.format("Click again: refund %d points", spentAll) or "Reset all points"
    button(respecLabel, "respec", function()
        if armed then
            respecArmedAt = nil
            send(Net.Channels.MetaRespec, { uuid = uuid })
            pending[uuid] = {}
            Log.Write("MetaMenu: reset all points for " .. tostring(st.name))
        else
            respecArmedAt = now()
        end
    end, st.respec ~= true or spentAll <= 0, true)
    if st.respec ~= true then text("(" .. tostring(st.respecWhy or "not here") .. ")", GREY, true) end
    button("Close", "close", function() M.Toggle() end, false, true)
end

local function buildWindow()
    local vw, vh = viewport()
    local w = Ext.IMGUI.NewWindow("Meta-Points##DAG_MetaMenu")
    set(w, "Closeable", false)
    local bad = WindowFlags.Set(w, { "NoSavedSettings", "NoCollapse" })
    if #bad > 0 then Log.Write("MetaMenu: flags not set: " .. table.concat(bad, ", ")) end
    pcall(function() w:SetPos({ math.floor(vw * 0.08), 120 }) end)
    pcall(function() w:SetSize({ 520, math.min(760, vh - 200) }) end)
    ui = { win = w, kids = {} }
    ui.body = w:AddGroup("dag_meta_body")
    Log.Write("MetaMenu: built")
end

local function signature()
    local st = selected and MetaPoints.State(selected)
    local parts = { tostring(selected), tostring(respecArmedAt and now() - respecArmedAt < 3000) }
    if st then
        parts[#parts + 1] = Ext.Json.Stringify(st)
        parts[#parts + 1] = Ext.Json.Stringify(pendingOf(selected))
    end
    parts[#parts + 1] = tostring(MetaPoints.Config().version) .. tostring(M.configSeq or 0)
    parts[#parts + 1] = tostring(State.mana and State.mana.max)
    local n = 0
    for _ in pairs(MetaPoints.States()) do n = n + 1 end
    parts[#parts + 1] = tostring(n)
    return table.concat(parts, "|")
end

-- ---------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------
function M.Shown() return shown end

function M.Toggle()
    shown = not shown
    if shown then
        if not ui then
            local ok, err = pcall(buildWindow)
            if not ok then Log.Write("MetaMenu: build failed " .. tostring(err)); shown = false; return end
        end
        selected = Me.Uuid() or selected
        sig = nil
        queryAt = 0
    end
    set(ui.win, "Open", shown)
    set(ui.win, "Visible", shown)
    Log.Write("MetaMenu: " .. (shown and "open" or "closed"))
end

function M.ConfigChanged() M.configSeq = (M.configSeq or 0) + 1 end

-- A small notice in the corner (third person, where the HUD's toasts don't show).
function M.Notice(textStr, secs)
    notice.text = textStr
    notice.untilAt = now() + (secs or 6) * 1000
    if not notice.ui then
        local ok = pcall(function()
            local vw = viewport()
            local w = Ext.IMGUI.NewWindow("##DAG_MetaNotice")
            set(w, "Closeable", false)
            WindowFlags.Set(w, { "NoTitleBar", "NoResize", "NoMove", "NoSavedSettings", "NoFocusOnAppearing", "NoNav",
                                 "NoInputs", "AlwaysAutoResize" })
            pcall(function() w:SetPos({ math.floor(vw / 2 - 220), 90 }) end)
            notice.ui = { win = w, text = w:AddText("") }
            pcall(function() notice.ui.text:SetColor("Text", GOLD) end)
        end)
        if not ok then notice.ui = false end
    end
    if notice.ui then
        set(notice.ui.text, "Label", textStr)
        set(notice.ui.win, "Open", true)
        set(notice.ui.win, "Visible", true)
    end
end

function M.Tick()
    if notice.ui and notice.text and now() > notice.untilAt then
        notice.text = nil
        set(notice.ui.win, "Visible", false)
        set(notice.ui.win, "Open", false)
    end
    if not shown or not ui then return end
    -- Ask for the shown character every second (camp / respec state).
    local t = now()
    if t - queryAt > 1000 then
        queryAt = t
        send(Net.Channels.MetaQuery, { uuid = selected or Me.Uuid() })
    end
    local s = signature()
    if s ~= sig then
        sig = s
        local ok, err = pcall(build)
        if not ok then Log.Write("MetaMenu: build error " .. tostring(err)) end
    end
end

return M
