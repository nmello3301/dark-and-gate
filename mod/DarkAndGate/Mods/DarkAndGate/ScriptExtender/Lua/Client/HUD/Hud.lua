-- SPDX-License-Identifier: GPL-3.0-or-later
-- First-person HUD with the developer's art (docs/design/hud.md), replacing
-- BG3's HUD while first person is on. SE ImGui images (docs/spikes/
-- hud-tech.md): one full-screen, no-input, transparent window; every layer
-- is a sub-rectangle of one texture (DAG_HUD_Atlas, made by
-- tools/hud/slice.py) placed in screen pixels.
--
--   health orb (left)   liquid = HP / max HP, "105/110 HP" under it
--   mana orb (right)    liquid = our mana pool, "60/60 MP" under it
--   hotbar, 10 slots    each spell's own icon (stats Icon), the armed slot
--                       glows, mana-too-low tint, key labels 1..0
--   potion slots        R = best health potion, T = mana potion (counts)
--   XP bar              XP into the level / XP for the next level
--   spell cast bar      blue, fills over the cast time, READY when the loop
--                       starts, drains on cancel, flashes on release
--   bow draw ring       amber arc around the crosshair (Hud.SetBowDraw)
-- Fills: the empty glass, then the full glass clipped from the bottom to the
-- % (UV + size), then a bright meniscus line at the liquid's edge.
--
--   !dag_hud on | off | vanilla   (vanilla = ours AND BG3's, for debugging)
--   !dag_hud widgets              log BG3's HUD widget names + visibility
--   !dag_bow_bar <0..1> | demo | off
--   !dag_cursor                   log BG3's cursor state + whether the DLL holds Camera Rotate

local Log        = Ext.Require("Shared/Log.lua")
local Net        = Ext.Require("Shared/Net.lua")
local ClientNet  = Ext.Require("Client/Net.lua")
local State      = Ext.Require("Client/Combat/State.lua")
local Spells     = Ext.Require("Client/Combat/Spells.lua")
local spells     = Ext.Require("data/spells.lua")
local cfg        = Ext.Require("data/hud.lua")
local L          = Ext.Require("data/hud_layout.lua")
local VanillaHud = Ext.Require("Client/HUD/VanillaHud.lua")
local SpellDefs  = Ext.Require("Shared/SpellDefs.lua")
local FullPov    = Ext.Require("FullPov.lua")
local HotbarMenu = Ext.Require("Client/HUD/HotbarMenu.lua")
local GiveUpButton = Ext.Require("Client/HUD/GiveUpButton.lua")
local MetaMenu = Ext.Require("Client/HUD/MetaMenu.lua")
local WindowFlags = Ext.Require("Client/HUD/WindowFlags.lua")
local Me = Ext.Require("Client/Me.lua")   -- the local player's character (multiplayer)

local M = { menuOpen = false }

local mode = "on"              -- on | off | vanilla
local ui = nil                 -- built window + elements
local atlasOk = nil            -- nil = not checked yet
local clickThrough = nil       -- false = the window would take the mouse: never shown
local stats = { xpCur = 0, xpNext = 0, level = 0, hpPotions = 0, manaPotions = 0 }
local bowDraw = nil            -- nil = hidden, else 0..1
-- A BG3 window our widget list can't see (a chest's loot window, opened with
-- F: Client/Interact.lua): counts as an open menu until cleared.
local externalMenu = nil
local bowDemo = nil
local lastFill, lastText = -1e9, -1e9
local shownState = nil
local cast = { state = "hidden", p = 0, t0 = 0, p0 = 0, prevArmed = nil }

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
    local ok, ents = pcall(Me.All)
    return ok and ents and ents[1] or nil
end

-- The atlas is drawn by icon name (data/hud_layout.lua atlas.prefix .. layer),
-- like Mod Configuration Menu draws its own shipped icons: the icon atlas
-- Public/Shared/GUI/DAG_HUD_Atlas.lsx points at the texture bank entry
-- (Public/Shared/Content/UI/[PAK]_DAG_HUD/merged.lsf). SE only warns when
-- an image can't bind, so build() checks the first layer and falls back to
-- the status line (atlasOk = false) when it didn't bind.
local function checkAtlas()
    if atlasOk == false or clickThrough == false then return false end
    return true
end

local function iconName(layerName) return (L.atlas.prefix or "DAG_HUD_") .. layerName end

-- ---------------------------------------------------------------------
-- Layout: canvas (art pixels) -> screen
-- ---------------------------------------------------------------------
local geo = {}
local function computeGeo(vw, vh)
    local top, bottom = 1e9, -1e9
    for _, r in pairs(L.pieces) do
        top = math.min(top, r[2]); bottom = math.max(bottom, r[2] + r[4])
    end
    local s = vw * cfg.width_frac / L.canvas[1]
    local numbersH = (cfg.font_px[cfg.font_numbers] or 28) * 1.2
    geo = { vw = vw, vh = vh, s = s, top = top, bottom = bottom,
            ox = (vw - L.canvas[1] * s) / 2,
            oy = vh - cfg.bottom_px - numbersH - (bottom - top) * s - top * s }
end
local function sx(x) return geo.ox + x * geo.s end
local function sy(y) return geo.oy + y * geo.s end

-- ---------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------
local FLAGS = { "NoTitleBar", "NoResize", "NoMove", "NoInputs", "NoScrollbar", "NoSavedSettings",
                "NoFocusOnAppearing", "NoNav", "NoBackground", "NoBringToFrontOnFocus" }

-- An atlas layer at canvas rect (x, y, w, h).
local function layer(win, name, x, y, w, h)
    local uv = L.atlas.uv[name]
    if not uv then return nil end
    w, h = w or uv[5], h or uv[6]
    local e = win:AddImage(iconName(name), { w * geo.s, h * geo.s }, { uv[1], uv[2] }, { uv[3], uv[4] })
    set(e, "AbsolutePosition", { sx(x), sy(y) })
    return { e = e, uv = uv, x = x, y = y, w = w, h = h, last = nil }
end

local function text(win, str, font, color)
    local t = win:AddText(str or "")
    set(t, "Font", font)
    pcall(function() t:SetColor("Text", color or cfg.text_color) end)
    return { e = t, str = str, font = font }
end

local function textWidth(str, font)
    return #str * (cfg.font_px[font] or 28) * (cfg.glyph_w or 0.5)
end

-- Place text centred on screen point (cx, cy).
local function placeCentered(t, str, cx, cy)
    if t.str ~= str then t.str = str; set(t.e, "Label", str) end
    local px = cfg.font_px[t.font] or 28
    local pos = { math.floor(cx - textWidth(str, t.font) / 2), math.floor(cy - px * 0.55) }
    if not t.pos or t.pos[1] ~= pos[1] or t.pos[2] ~= pos[2] then t.pos = pos; set(t.e, "AbsolutePosition", pos) end
end

local function slotIcon(id)
    if not id then return nil end
    local ok, st = pcall(Ext.Stats.Get, id)
    local icon = ok and st and st.Icon or nil
    return icon and tostring(icon) ~= "" and tostring(icon) or nil
end

local function hotbarSignature()
    local parts = {}
    for i = 1, 10 do parts[i] = tostring(State.hotbar[i] or "") end
    return table.concat(parts, "|")
end

local function destroy()
    if not ui then return end
    pcall(function() ui.win:Destroy() end)
    pcall(function() ui.win.Open = false end)
    ui = nil
end

local function build()
    destroy()
    local vw, vh = viewport()
    computeGeo(vw, vh)
    local win = Ext.IMGUI.NewWindow("##DAG_FirstPersonHUD")
    set(win, "Closeable", false)
    local badFlags = WindowFlags.Set(win, FLAGS)
    -- A full-screen window that takes the mouse blocks BG3's camera and MMB
    -- (SE hands ImGui every mouse event over a hoverable window): never show one.
    if not WindowFlags.ClickThrough(win) then
        clickThrough = false
        Log.Write("Hud: the HUD window could not be made click-through (flags not set: " .. table.concat(badFlags, ", ")
            .. ") -> not shown, status line instead (!dag_hud_status): it would block the camera")
        pcall(function() win:Destroy() end)
        return
    end
    clickThrough = true
    pcall(function() win.Scaling = "Absolute" end)
    pcall(function() win:SetStyle("WindowPadding", 0, 0) end)
    pcall(function() win:SetStyle("WindowBorderSize", 0) end)
    pcall(function() win:SetColor("WindowBg", { 0, 0, 0, 0 }) end)
    pcall(function() win:SetPos({ 0, 0 }) end)
    pcall(function() win:SetSize({ vw, vh }) end)
    local u = { win = win, vw = vw, vh = vh, sig = hotbarSignature(), orbs = {}, slots = {}, keys = {} }
    local P = L.pieces

    -- Did the atlas bind? (ImageData.Icon is only set when the icon AND its
    -- texture loaded.)
    do
        local probe = layer(win, "bar", 0, 0, 1, 1)
        local okI, icon = pcall(function() return tostring(probe.e.ImageData.Icon) end)
        local okT, tex = pcall(function() return tostring(probe.e.ImageData.TextureResource) end)
        local bound = okI and icon == iconName("bar")
        pcall(function() probe.e:Destroy() end)
        set(probe.e, "Visible", false)
        if not bound then
            atlasOk = false
            Log.Write(string.format("Hud: atlas icon %s did NOT bind (Icon=%s, Texture=%s): the icon atlas or texture bank"
                .. " wasn't loaded -> status line instead (!dag_hud_status). SE's console shows the reason as a warning.",
                iconName("bar"), okI and icon or "?", okT and tex or "?"))
            pcall(function() win:Destroy() end)
            return
        end
        if atlasOk == nil then
            atlasOk = true
            Log.Write(string.format("Hud: atlas icon %s bound (texture %s)", iconName("bar"), okT and tex or "?"))
        end
    end

    for _, k in ipairs({ "h", "m" }) do
        local r = P["orb_" .. k .. "_full"]
        local o = { cfg = L.orbs[k] }
        o.empty = layer(win, "orb_" .. k .. "_empty", r[1], r[2], r[3], r[4])
        o.full = layer(win, "orb_" .. k .. "_full", r[1], r[2], r[3], r[4])
        o.men = cfg.meniscus and layer(win, "meniscus_" .. k, r[1], r[2], 10, 9) or nil
        local f = P["orb_" .. k .. "_frame"]
        o.frame = layer(win, "orb_" .. k .. "_frame", f[1], f[2], f[3], f[4])
        u.orbs[k] = o
    end
    local b = P.bar
    u.bar = layer(win, "bar", b[1], b[2], b[3], b[4])
    local tr = L.xp.track
    u.xp = layer(win, "xp_fill", tr[1], tr[2], tr[3], tr[4])
    u.xpCap = layer(win, "xp_cap", tr[1], tr[2])

    local inset = cfg.icon_inset or 9
    for i = 1, 10 do
        local r = L.slots[i]
        local id = State.hotbar[i]
        local icon = slotIcon(id)
        local s = { id = id, icon = icon, r = r }
        if icon then
            local okI, e = pcall(function()
                return win:AddImage(icon, { (r[3] - 2 * inset) * geo.s, (r[4] - 2 * inset) * geo.s })
            end)
            if okI and e then
                s.e = e
                set(e, "AbsolutePosition", { sx(r[1] + inset), sy(r[2] + inset) })
            else
                Log.Write(string.format("Hud: slot %d icon %s for %s failed: %s", i, icon, tostring(id), tostring(e)))
            end
        end
        u.slots[i] = s
    end
    for _, k in ipairs({ "h", "m" }) do
        local fl = L.potions[k].flask
        u["potion_" .. k] = layer(win, k == "h" and "potion_health" or "potion_mana", fl[1], fl[2], fl[3], fl[4])
    end
    local r1 = L.slots[1]
    local selUv = L.atlas.uv.slot_selected
    u.glow = layer(win, "slot_selected", r1[1] - 7, r1[2] - 7, selUv[5], selUv[6])
    set(u.glow and u.glow.e, "Visible", false)

    for i = 1, 10 do u.keys[i] = text(win, cfg.keys[i], cfg.font_keys) end
    u.keyR = text(win, cfg.potion_keys.health, cfg.font_keys)
    u.keyT = text(win, cfg.potion_keys.mana, cfg.font_keys)
    u.cntH = text(win, "", cfg.font_keys, cfg.numbers_color)
    u.cntM = text(win, "", cfg.font_keys, cfg.numbers_color)
    u.hpText = text(win, "", cfg.font_numbers, cfg.numbers_color)
    u.mpText = text(win, "", cfg.font_numbers, cfg.numbers_color)

    -- Spell cast bar, above the hotbar centre.
    local cb = L.castbar
    local cw = L.canvas[1] * cfg.castbar_width_frac
    local k = cw / cb.size[1]
    local ch = cb.size[2] * k
    local cx0 = L.canvas[1] / 2 - cw / 2
    local cy0 = b[2] - cfg.castbar_gap - ch
    u.cb = { x = cx0, y = cy0, k = k,
             frame = layer(win, "castbar_frame", cx0, cy0, cw, ch),
             tx = cx0 + cb.track[1] * k, ty = cy0 + cb.track[2] * k, tw = cb.track[3] * k, th = cb.track[4] * k }
    u.cb.fill = layer(win, "castbar_fill", u.cb.tx, u.cb.ty, u.cb.tw, u.cb.th)
    u.cb.ready = layer(win, "castbar_ready", u.cb.tx, u.cb.ty, u.cb.tw, u.cb.th)
    u.cb.label = text(win, "", cfg.font_keys, cfg.numbers_color)
    for _, x in ipairs({ u.cb.frame, u.cb.fill, u.cb.ready }) do set(x and x.e, "Visible", false) end

    -- Bow ring around the screen centre (screen px, not the canvas).
    local bs = cfg.bow_ring_px
    local buv = L.atlas.uv.bow_00
    local okB, be = pcall(function() return win:AddImage(iconName("bow_00"), { bs, bs }, { buv[1], buv[2] }, { buv[3], buv[4] }) end)
    if okB and be then
        u.bow = be
        set(be, "AbsolutePosition", { vw / 2 - bs / 2, vh / 2 - bs / 2 })
        set(be, "Visible", false)
    end

    ui = u
    shownState = nil
    lastFill, lastText = -1e9, -1e9
    Log.Write(string.format("Hud: built %dx%d scale %.3f (art canvas %dx%d), %d slot icons, click-through%s", vw, vh, geo.s,
        L.canvas[1], L.canvas[2], (function() local n = 0 for i = 1, 10 do if u.slots[i].e then n = n + 1 end end return n end)(),
        #badFlags > 0 and (" (flags not set: " .. table.concat(badFlags, ", ") .. ")") or ""))
end

-- ---------------------------------------------------------------------
-- Per-frame updates
-- ---------------------------------------------------------------------
-- Vertical clip from the bottom: show the lower fraction p of layer l.
local function clipBottom(l, p)
    if not l then return end
    p = math.max(0, math.min(1, p))
    local key = math.floor(p * 1000)
    if l.last == key then return end
    l.last = key
    if p <= 0.002 then set(l.e, "Visible", false); return end
    set(l.e, "Visible", true)
    local u0, v0, u1, v1 = l.uv[1], l.uv[2], l.uv[3], l.uv[4]
    local cut = l.h * (1 - p)
    pcall(function()
        l.e.ImageData.UV0 = { u0, v0 + (v1 - v0) * (1 - p) }
        l.e.ImageData.UV1 = { u1, v1 }
        l.e.ImageData.Size = { l.w * geo.s, (l.h - cut) * geo.s }
    end)
    set(l.e, "AbsolutePosition", { sx(l.x), sy(l.y + cut) })
end

-- Horizontal clip from the left: show the left fraction p of layer l.
local function clipLeft(l, p)
    if not l then return end
    p = math.max(0, math.min(1, p))
    local key = math.floor(p * 1000)
    if l.last == key then return end
    l.last = key
    if p <= 0.002 then set(l.e, "Visible", false); return end
    set(l.e, "Visible", true)
    pcall(function()
        l.e.ImageData.UV1 = { l.uv[1] + (l.uv[3] - l.uv[1]) * p, l.uv[4] }
        l.e.ImageData.Size = { l.w * p * geo.s, l.h * geo.s }
    end)
end

local function orb(o, p, pulse)
    clipBottom(o.full, p)
    if o.full then
        local a = 1.0
        if pulse and p < (cfg.low_pulse_below or 0.25) then a = 0.72 + 0.28 * math.sin(now() / 1000 * 6.0) end
        local ka = math.floor(a * 50)
        if o.full.lastTint ~= ka then o.full.lastTint = ka; set(o.full.e, "Tint", { 1, 1, 1, a }) end
    end
    if o.men then
        local c = o.cfg
        local show = p > 0.01 and p < 0.99
        local key = show and math.floor(p * 1000) or -1
        if o.men.last ~= key then
            o.men.last = key
            set(o.men.e, "Visible", show)
            if show then
                local y = c.cy + c.r - 2 * c.r * p             -- liquid surface (canvas)
                local dy = y - c.cy
                local chord = 2 * math.sqrt(math.max(c.r * c.r - dy * dy, 0))
                pcall(function() o.men.e.ImageData.Size = { chord * geo.s, 9 * geo.s } end)
                set(o.men.e, "AbsolutePosition", { sx(c.cx - chord / 2), sy(y - 4.5) })
            end
        end
    end
end

local function readHp()
    local me = player()
    if not me then return nil end
    local ok, hp, max = pcall(function() return me.Health.Hp, me.Health.MaxHp end)
    if ok and tonumber(max) and tonumber(max) > 0 then return tonumber(hp), tonumber(max) end
    return nil
end

local function spellCost(id) return SpellDefs.Cost(id) end

local function armedSlot()
    if not State.armedSpell then return nil end
    for i = 1, 10 do if State.hotbar[i] == State.armedSpell then return i end end
    return nil
end

local function updateCast(u)
    local t = now()
    local armed = State.armedSpell
    if armed then
        local total = State.armedCastTime or Spells.CastTime(armed)
        local left = Spells.ReadyIn(armed)
        cast.p = total > 0 and math.max(0, math.min(1, 1 - left / total)) or 1
        cast.state = left <= 0 and "ready" or "casting"
        cast.left = left
    elseif cast.prevArmed then
        if State.lastCastAt and t - State.lastCastAt < 400 then
            cast.state, cast.t0 = "flash", t
        else
            cast.state, cast.t0, cast.p0 = "drain", t, cast.p
        end
    end
    cast.prevArmed = armed
    local cb = u.cb
    local showFrame, fillP, readyA, fillA = false, 0, 0, 1
    if cast.state == "casting" then
        showFrame, fillP = true, cast.p
    elseif cast.state == "ready" then
        showFrame, fillP = true, 1
        readyA = 0.7 + 0.3 * math.sin(t / 1000 * math.pi * 2 * (cfg.ready_pulse_hz or 1.6))
    elseif cast.state == "drain" then
        local f = (t - cast.t0) / 1000 / (cfg.castbar_drain_s or 0.35)
        if f >= 1 then cast.state = "hidden" else showFrame, fillP = true, cast.p0 * (1 - f) end
    elseif cast.state == "flash" then
        local f = (t - cast.t0) / 1000 / (cfg.castbar_flash_s or 0.2)
        if f >= 1 then cast.state = "hidden" else showFrame, fillP, readyA = true, 1, 1 - f end
    end
    if cb.shown ~= showFrame then
        cb.shown = showFrame
        set(cb.frame and cb.frame.e, "Visible", showFrame)
        set(cb.label.e, "Visible", showFrame)
    end
    if not showFrame then
        set(cb.fill and cb.fill.e, "Visible", false); if cb.fill then cb.fill.last = nil end
        set(cb.ready and cb.ready.e, "Visible", false); if cb.ready then cb.ready.last = nil end
        return
    end
    if readyA > 0 then
        clipLeft(cb.ready, 1)
        set(cb.ready.e, "Tint", { 1, 1, 1, readyA })
        set(cb.fill and cb.fill.e, "Visible", false); if cb.fill then cb.fill.last = nil end
    else
        set(cb.ready and cb.ready.e, "Visible", false); if cb.ready then cb.ready.last = nil end
        clipLeft(cb.fill, fillP)
    end
    local name = armed and ((SpellDefs.Get(armed) or {}).label or armed) or ""
    local label = cast.state == "ready" and ("READY " .. name) or (cast.state == "casting" and string.format("%s %.1fs", name, cast.left or 0) or "")
    placeCentered(cb.label, label, sx(L.canvas[1] / 2), sy(cb.y) - 4)
end

local function updateBow(u)
    if not u.bow then return end
    local d = bowDraw
    if bowDemo then
        local e = (now() - bowDemo) / 1000
        if e < 1.0 then d = e elseif e < 2.0 then d = 1 else d = nil; bowDemo = nil end
    end
    if d == nil then
        if u.bowShown then u.bowShown = false; set(u.bow, "Visible", false) end
        return
    end
    if not u.bowShown then u.bowShown = true; set(u.bow, "Visible", true) end
    local n = (L.bow.frames or 21) - 1
    local i = math.max(0, math.min(n, math.floor(d * n + 0.5)))
    if u.bowFrame ~= i then
        u.bowFrame = i
        local uv = L.atlas.uv[string.format("bow_%02d", i)]
        pcall(function() u.bow.ImageData.UV0 = { uv[1], uv[2] }; u.bow.ImageData.UV1 = { uv[3], uv[4] } end)
    end
end

local function updateFills(u)
    local hp, maxHp = readHp()
    u.hp, u.maxHp = hp, maxHp
    orb(u.orbs.h, maxHp and hp / maxHp or 0, true)
    local mm = State.mana.max or 0
    orb(u.orbs.m, mm > 0 and (State.mana.current or 0) / mm or 0, true)
    clipLeft(u.xp, stats.xpNext > 0 and stats.xpCur / stats.xpNext or 0)
    if u.xpCap then
        local p = stats.xpNext > 0 and math.min(1, stats.xpCur / stats.xpNext) or 0
        local tr = L.xp.track
        local key = math.floor(p * 1000)
        if u.xpCap.last ~= key then
            u.xpCap.last = key
            set(u.xpCap.e, "Visible", p > 0.01)
            set(u.xpCap.e, "AbsolutePosition", { sx(tr[1] + tr[3] * p - u.xpCap.w), sy(tr[2]) })
        end
    end
    updateCast(u)
    updateBow(u)
end

local function updateText(u)
    -- Numbers under the orbs.
    local oh, om = L.orbs.h, L.orbs.m
    local yNum = sy(geo.bottom) + (cfg.font_px[cfg.font_numbers] or 28) * 0.55
    placeCentered(u.hpText, u.hp and string.format("%d/%d HP", u.hp, u.maxHp) or "", sx(oh.cx), yNum)
    placeCentered(u.mpText, string.format("%d/%d MP", math.floor(State.mana.current or 0), math.floor(State.mana.max or 0)),
        sx(om.cx), yNum)
    -- Key labels.
    for i = 1, 10 do
        local r = L.slots[i]
        local cx, cy
        if cfg.key_labels == "above" then cx, cy = sx(r[1] + r[3] / 2), sy(r[2]) - 10
        else cx, cy = sx(L.digits[i][1]), sy(L.digits[i][2]) end
        placeCentered(u.keys[i], cfg.keys[i], cx, cy)
    end
    for k, t in pairs({ h = u.keyR, m = u.keyT }) do
        local pl = L.potions[k].plate
        placeCentered(t, k == "h" and cfg.potion_keys.health or cfg.potion_keys.mana, sx((pl[1] + pl[3]) / 2), sy((pl[2] + pl[4]) / 2))
    end
    -- Potion counts (top right of each potion slot) + dim flask when none.
    for k, t in pairs({ h = u.cntH, m = u.cntM }) do
        local n = (k == "h") and stats.hpPotions or stats.manaPotions
        local sl = L.potions[k].slot
        placeCentered(t, n > 0 and ("x" .. n) or "", sx(sl[3] - 20), sy(sl[2] + 18))
        local fl = u["potion_" .. k]
        local key = n > 0 and 1 or 0
        if fl and fl.lastTint ~= key then fl.lastTint = key; set(fl.e, "Tint", n > 0 and { 1, 1, 1, 1 } or cfg.no_potion_tint) end
    end
    -- Armed glow + mana tint. While the Prepare Hotbar menu is up (pinned with
    -- H, so our HUD is visible) the glow marks the slot it is filling instead.
    local a = HotbarMenu.Selected() or armedSlot()
    if u.glowSlot ~= a then
        u.glowSlot = a
        set(u.glow.e, "Visible", a ~= nil)
        if a then
            local r = L.slots[a]
            set(u.glow.e, "AbsolutePosition", { sx(r[1] - 7), sy(r[2] - 7) })
        end
    end
    local cur = State.mana.current or 0
    for i = 1, 10 do
        local s = u.slots[i]
        if s.e then
            local low = spellCost(s.id) > cur
            if s.low ~= low then s.low = low; set(s.e, "Tint", low and cfg.no_mana_tint or { 1, 1, 1, 1 }) end
        end
    end
end

-- ---------------------------------------------------------------------
-- Visibility + tick
-- ---------------------------------------------------------------------
local function setShown(on)
    if shownState == on then return end
    shownState = on
    if ui then set(ui.win, "Open", on); set(ui.win, "Visible", on) end
end

-- BG3's cursor (Ext.UI.GetCursorControl) + whether the DLL holds Camera
-- Rotate, for the log: shows if a menu really freed the cursor.
local function cursorState()
    local parts = {}
    local ok, cc = pcall(Ext.UI.GetCursorControl)
    if ok and cc then
        pcall(function() parts[#parts + 1] = "BG3 ShowCursor=" .. tostring(cc.ShowCursor) end)
        pcall(function() parts[#parts + 1] = "cursor=" .. tostring(cc.RequestedCursor) end)
    else
        parts[#parts + 1] = "no cursor control"
    end
    parts[#parts + 1] = "DLL holds rotate=" .. tostring(State.MouseLookOn())
    return table.concat(parts, " ")
end

local function tick()
    VanillaHud.Tick()
    local active = State.IsCombatActive()
    local menu, menuName = false, nil
    if active then menu, menuName = VanillaHud.MenuOpen() end
    if active and not menu and externalMenu then menu, menuName = true, externalMenu end
    -- Our Prepare Hotbar menu: beside BG3's I / Tab panels, or pinned (H).
    pcall(HotbarMenu.Update, active, menu and menuName or nil)
    -- A BG3 panel (or our pinned menu) is open: the cursor is freed
    -- (mouse-look off) until it closes. Mouse-look comes back
    -- menu_release_ms after our menu window is gone: the DLL's synthetic MMB
    -- press must not land on an ImGui window still under the cursor (SE would
    -- give it to ImGui and the camera would stay stuck until MMB twice).
    -- (and while the downed screen's Give up button shows: Client/Downed.lua)
    local free = active and (menu or HotbarMenu.Pinned() or GiveUpButton.Shown() or MetaMenu.Shown())
    local t0 = now()
    -- Our input capture pauses while a BG3 panel is open and for the same
    -- release tail as mouse-look (Client/Combat/Input.lua; our own pinned
    -- Prepare Hotbar menu keeps the keys).
    if active and menu then M.vanillaAt = t0 end
    local paused = active and (menu or (M.vanillaAt ~= nil and t0 - M.vanillaAt < (cfg.menu_release_ms or 200)))
    if paused ~= (State.uiPaused == true) then
        State.uiPaused = paused
        Log.Write("Hud: our input capture " .. (paused and ("PAUSED (" .. tostring(menuName) .. " open)") or "back on"))
    end
    if free then
        M.releaseAt = nil
        if not M.menuOpen then
            M.menuOpen = true
            FullPov.SetMenuOpen(true)
            Log.Write("Hud: " .. (menu and ("menu " .. tostring(menuName)) or (GiveUpButton.Shown() and "Give up button" or (MetaMenu.Shown() and "Meta-Points menu" or "Prepare Hotbar menu")))
                .. " open -> cursor free (mouse-look off)"
                .. (menu and ", BG3 HUD back" or ""))
            M.probeAt, M.probeWhy = t0 + (cfg.cursor_probe_ms or 400), "menu open"
        end
    elseif M.menuOpen then
        M.releaseAt = M.releaseAt or (t0 + (cfg.menu_release_ms or 200))
        if t0 >= M.releaseAt then
            M.releaseAt = nil
            M.menuOpen = false
            FullPov.SetMenuOpen(false)
            Log.Write("Hud: menus closed -> mouse-look back on")
            M.probeAt, M.probeWhy = t0 + (cfg.cursor_probe_ms or 400), "menus closed"
        end
    end
    if M.probeAt and t0 >= M.probeAt then
        M.probeAt = nil
        Log.Write("Hud: cursor after " .. tostring(M.probeWhy) .. ": " .. cursorState())
    end
    local want = active and not menu and mode ~= "off"
    -- BG3's HUD: hidden only while ours is up in "on" mode.
    if want and mode == "on" then VanillaHud.Hide("first person") else
        VanillaHud.Restore(not active and "first person off / dialogue / cutscene" or
            (menu and ("menu " .. tostring(menuName)) or ("mode " .. mode)))
    end
    if not want or not checkAtlas() then setShown(false); return end
    local vw, vh = viewport()
    if not ui or ui.vw ~= vw or ui.vh ~= vh or ui.sig ~= hotbarSignature() then build() end
    if not ui then return end
    setShown(true)
    local t = now()
    if t - lastFill >= 1000 / (cfg.fill_hz or 30) then lastFill = t; updateFills(ui) end
    if t - lastText >= 1000 / (cfg.text_hz or 8) then lastText = t; updateText(ui) end
end

-- ---------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------
-- Bow draw ring: frac 0..1 while drawing, nil to hide (Part C bows).
function M.SetBowDraw(frac) bowDraw = frac end
function M.SetExternalMenu(name) externalMenu = name end
function M.Mode() return mode end
-- on | off | vanilla, like !dag_hud (!dag_play sets "on").
function M.SetMode(m)
    if m ~= "on" and m ~= "off" and m ~= "vanilla" then return end
    if m == mode then return end
    mode = m
    if m ~= "on" then VanillaHud.Restore("SetMode " .. m) end
    Log.Write("Hud: mode " .. mode)
end
function M.AtlasOk() return atlasOk end
-- false = the art HUD can't be shown (atlas didn't bind, or its window
-- couldn't be made click-through): the status line stands in.
function M.Available()
    if atlasOk == false or clickThrough == false then return false end
    if atlasOk == nil then return nil end
    return true
end

function M.UsePotion(kind)
    ClientNet.Send(Net.Channels.UsePotion, { kind = kind })
    Log.Write("Hud: potion key -> " .. kind)
end

function M.Register()
    Ext.RegisterNetListener(Net.Channels.HudStats, function(_, payload)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or not p then return end
        stats.xpCur = tonumber(p.xpCur) or stats.xpCur
        stats.xpNext = tonumber(p.xpNext) or stats.xpNext
        stats.level = tonumber(p.level) or stats.level
        stats.hpPotions = tonumber(p.hpPotions) or 0
        stats.manaPotions = tonumber(p.manaPotions) or 0
        if not M.statsLogged then
            M.statsLogged = true
            Log.Write(string.format("Hud: stats from server: XP %d/%d (level %d), potions health %d mana %d",
                stats.xpCur, stats.xpNext, stats.level, stats.hpPotions, stats.manaPotions))
        end
    end)
    Ext.RegisterConsoleCommand("dag_hud", function(_, a)
        if a == "off" or a == "on" or a == "vanilla" then
            mode = a
            if a ~= "on" then VanillaHud.Restore("!dag_hud " .. a) end
            Log.Write("Hud: mode " .. mode)
        elseif a == "retry" then
            atlasOk, clickThrough = nil, nil
            destroy()
            Log.Write("Hud: atlas bind will be retried")
        elseif a == "widgets" then
            Log.Write("Hud: BG3 HUD widgets: " .. VanillaHud.Names())
        else
            Log.Write("Hud: usage !dag_hud on|off|vanilla|widgets|retry (now " .. mode .. ")")
        end
    end)
    Ext.RegisterConsoleCommand("dag_cursor", function()
        Log.Write("Hud: cursor now: " .. cursorState() .. (M.menuOpen and " (menu open)" or ""))
    end)
    Ext.RegisterConsoleCommand("dag_bow_bar", function(_, a)
        if a == "demo" then bowDemo = now(); bowDraw = nil
        elseif a == "off" or not a then bowDraw, bowDemo = nil, nil
        else bowDraw = math.max(0, math.min(1, tonumber(a) or 0)) end
        Log.Write("Hud: bow ring " .. tostring(a))
    end)
    local lastErr = -1e9
    Ext.Events.Tick:Subscribe(function()
        local ok, err = pcall(tick)
        if not ok and now() - lastErr > 5000 then
            lastErr = now()
            Log.Write("Hud: tick error: " .. tostring(err))
        end
    end)
    -- A previous Lua state (before a `reset`) may have left BG3's HUD hidden.
    pcall(VanillaHud.Recover)
    pcall(function() Ext.Events.SessionLoaded:Subscribe(function() pcall(VanillaHud.Recover) end) end)
    Log.Write("Hud: registered (art HUD, !dag_hud on|off|vanilla|widgets, !dag_bow_bar, !dag_cursor)")
end

return M
