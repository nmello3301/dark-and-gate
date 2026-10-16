-- SPDX-License-Identifier: GPL-3.0-or-later
-- On-screen prompts for the real-time combat pass, in the HUD's style
-- (one full-screen, click-through ImGui window like Client/HUD/Hud.lua):
--   prompt   under the crosshair: "[F] Open Chest", "Hold F to revive Gale"
--   bar      under the prompt: the revive progress (and any timed hold)
--   toast    top centre, fades: "Companions: Wait"
--   banner   centre top: the downed state and bleed-out timer
--   count    under the crosshair while picking spell targets: "Bless 2 / 3"
--   markers  world-anchored labels (projected every frame): "[F]" on the
--            object F would use, the pick count over spell targets
--
--   Overlay.Prompt(text|nil)   Overlay.Bar(frac|nil, label)   Overlay.Toast(text, secs, always)
--   Overlay.Banner(lines|nil)  Overlay.Count(text|nil)         Overlay.Markers(list|nil)
--   Overlay.Project(pos) -> sx, sy | nil

local Log         = Ext.Require("Shared/Log.lua")
local State       = Ext.Require("Client/Combat/State.lua")
local Aim         = Ext.Require("Client/Combat/Aim.lua")
local WindowFlags = Ext.Require("Client/HUD/WindowFlags.lua")
local TickBudget  = Ext.Require("Shared/TickBudget.lua")
local cfg         = Ext.Require("data/hud.lua")

local M = {}

local S = { prompt = nil, bar = nil, barLabel = nil, toast = nil, toastUntil = 0, banner = nil, count = nil, markers = nil,
            force = false }
local ui = nil
local MAX_MARKERS = 12
local FLAGS = { "NoTitleBar", "NoResize", "NoMove", "NoInputs", "NoScrollbar", "NoSavedSettings",
                "NoFocusOnAppearing", "NoNav", "NoBackground", "NoBringToFrontOnFocus" }

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

-- ---------------------------------------------------------------------
-- Public state setters
-- ---------------------------------------------------------------------
function M.Prompt(text) S.prompt = (text and text ~= "") and text or nil end
function M.Bar(frac, label) S.bar = frac and math.max(0, math.min(1, frac)) or nil; S.barLabel = label end
-- always: show it with first person off too.
function M.Toast(text, secs, always)
    S.toast = text
    S.toastAlways = always and true or false
    S.toastUntil = now() + (secs or 2.5) * 1000
    Log.Write("Overlay: toast \"" .. tostring(text) .. "\"")
end
function M.Banner(lines) S.banner = lines end
function M.Count(text) S.count = text end
function M.Markers(list) S.markers = list end
-- Show even with first person off (the downed orbit camera).
function M.Force(on) S.force = on and true or false end

-- mat4 (flat 16, column-major) * vec4 (as Client/AnimLib/Gallery.lua).
local function mul(m, x, y, z, w)
    return m[1] * x + m[5] * y + m[9] * z + m[13] * w,
           m[2] * x + m[6] * y + m[10] * z + m[14] * w,
           m[3] * x + m[7] * y + m[11] * z + m[15] * w,
           m[4] * x + m[8] * y + m[12] * z + m[16] * w
end

function M.Project(p)
    local ctrl = Aim.ActiveCameraController and Aim.ActiveCameraController()
    if not ctrl or not p then return nil end
    local ok, V, P = pcall(function() return ctrl.Camera.ViewMatrix, ctrl.Camera.ProjectionMatrix end)
    if not ok or not V or not P then return nil end
    local vx, vy, vz, vw = mul(V, p[1], p[2], p[3], 1)
    local cx, cy, _, cw = mul(P, vx, vy, vz, vw)
    if cw <= 0.01 then return nil end
    local sw, sh = viewport()
    local nx, ny = cx / cw, cy / cw
    if nx < -1.1 or nx > 1.1 or ny < -1.1 or ny > 1.1 then return nil end
    return (nx * 0.5 + 0.5) * sw, (1 - (ny * 0.5 + 0.5)) * sh
end

-- ---------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------
local function text(win, font, color)
    local t = win:AddText("")
    set(t, "Font", font)
    pcall(function() t:SetColor("Text", color or cfg.text_color) end)
    set(t, "Visible", false)
    return { e = t, font = font, str = nil, shown = false }
end

local function textWidth(str, font) return #str * (cfg.font_px[font] or 28) * (cfg.glyph_w or 0.5) end

local function show(t, on)
    if t.shown ~= on then t.shown = on; set(t.e, "Visible", on) end
end

local function place(t, str, cx, cy)
    if not str then show(t, false); return end
    if t.str ~= str then t.str = str; set(t.e, "Label", str) end
    local px = cfg.font_px[t.font] or 28
    local pos = { math.floor(cx - textWidth(str, t.font) / 2), math.floor(cy - px * 0.55) }
    if not t.pos or t.pos[1] ~= pos[1] or t.pos[2] ~= pos[2] then t.pos = pos; set(t.e, "AbsolutePosition", pos) end
    show(t, true)
end

local function build()
    local vw, vh = viewport()
    local win = Ext.IMGUI.NewWindow("##DAG_Overlay")
    set(win, "Closeable", false)
    WindowFlags.Set(win, FLAGS)
    if not WindowFlags.ClickThrough(win) then
        Log.Write("Overlay: the window could not be made click-through -> prompts go to the log only")
        pcall(function() win:Destroy() end)
        ui = false
        return
    end
    pcall(function() win.Scaling = "Absolute" end)
    pcall(function() win:SetStyle("WindowPadding", 0, 0) end)
    pcall(function() win:SetStyle("WindowBorderSize", 0) end)
    pcall(function() win:SetColor("WindowBg", { 0, 0, 0, 0 }) end)
    pcall(function() win:SetPos({ 0, 0 }) end)
    pcall(function() win:SetSize({ vw, vh }) end)
    local u = { win = win, vw = vw, vh = vh, markers = {} }
    u.prompt = text(win, "Medium", cfg.numbers_color)
    u.count = text(win, "Small", cfg.text_color)
    u.toast = text(win, "Large", cfg.numbers_color)
    u.banner = { text(win, "Big", { 0.92, 0.35, 0.30, 1.0 }), text(win, "Medium", cfg.numbers_color), text(win, "Small", cfg.text_color),
                 text(win, "Small", cfg.text_color) }
    local okB, bar = pcall(function() return win:AddProgressBar() end)
    if okB and bar then
        u.bar = bar
        set(bar, "Size", { 300, 20 })
        pcall(function() bar:SetColor("PlotHistogram", { 0.85, 0.70, 0.30, 0.95 }) end)
        pcall(function() bar:SetColor("FrameBg", { 0.05, 0.05, 0.05, 0.75 }) end)
        set(bar, "Visible", false)
    end
    for i = 1, MAX_MARKERS do u.markers[i] = text(win, "Small", cfg.numbers_color) end
    ui = u
    set(win, "Open", true)
    set(win, "Visible", true)
    Log.Write(string.format("Overlay: built %dx%d (prompts, revive bar, toasts, downed banner, markers)", vw, vh))
end

local winShown = nil
local offView = {}   -- what shows with first person off
local function tick()
    local t = now()
    if S.toast and t > S.toastUntil then S.toast = nil end
    -- First person off: only a toast given with Toast(..., always) shows
    -- (Client/PlayMode.lua's "Dark and Gate: OFF").
    local V = S
    if not (State.povOn or S.force) then
        offView.toast = S.toastAlways and S.toast or nil
        V = offView
    end
    local want = V.prompt or V.bar or V.toast or V.banner or V.count or (V.markers and #V.markers > 0)
    if not want then
        if ui and winShown then winShown = false; set(ui.win, "Visible", false); set(ui.win, "Open", false) end
        return
    end
    if ui == nil then build() end
    if not ui then return end
    local vw, vh = viewport()
    if ui.vw ~= vw or ui.vh ~= vh then
        pcall(function() ui.win:SetSize({ vw, vh }) end)
        ui.vw, ui.vh = vw, vh
    end
    if not winShown then winShown = true; set(ui.win, "Open", true); set(ui.win, "Visible", true) end
    local cx, cy = vw / 2, vh / 2
    place(ui.prompt, V.prompt, cx, cy + 46)
    place(ui.count, V.count, cx, cy + (V.prompt and 76 or 46))
    if ui.bar then
        if V.bar then
            set(ui.bar, "Value", V.bar)
            set(ui.bar, "Overlay", V.barLabel or "")
            set(ui.bar, "AbsolutePosition", { math.floor(cx - 150), math.floor(cy + 70) })
            if not ui.barShown then ui.barShown = true; set(ui.bar, "Visible", true) end
        elseif ui.barShown then
            ui.barShown = false
            set(ui.bar, "Visible", false)
        end
    end
    place(ui.toast, V.toast, cx, vh * 0.17)
    for i, line in ipairs(ui.banner) do
        place(line, V.banner and V.banner[i] or nil, cx, vh * 0.24 + (i - 1) * 38 + (i > 1 and 12 or 0))
    end
    local list = V.markers or {}
    for i = 1, MAX_MARKERS do
        local m = list[i]
        local sx, sy = nil, nil
        if m and m.pos then sx, sy = M.Project(m.pos) end
        if sx then place(ui.markers[i], m.text or "[ ]", sx, sy) else show(ui.markers[i], false) end
    end
end

function M.Register()
    Ext.Events.Tick:Subscribe(TickBudget.Wrap("Overlay", tick))
    Ext.RegisterConsoleCommand("dag_overlay_test", function()
        M.Toast("Overlay test: toast", 3)
        M.Prompt("[F] Overlay test prompt")
        M.Bar(0.4, "Reviving 1.2 / 3.0 s")
        M.Banner({ "DOWNED", "Bleeding out 2:47", "Shadowheart is reviving you (timer paused)" })
        Ext.Timer.WaitFor(3000, function() M.Prompt(nil); M.Bar(nil); M.Banner(nil) end)
    end)
end

return M
