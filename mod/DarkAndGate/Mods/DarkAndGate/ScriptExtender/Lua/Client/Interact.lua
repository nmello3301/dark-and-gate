-- SPDX-License-Identifier: GPL-3.0-or-later
-- The F key in first person (DECISIONS 2026-10-12,
-- docs/design/interaction-and-world.md):
--   * a downed ally within revive range wins: HOLD F to revive
--     (Server/Combat/Downed.lua runs the 3 s timer; letting go of F or
--     another action -- swing, cast, jump, potion -- cancels it; moving or
--     being hit doesn't);
--   * otherwise a TAP of F starts the interaction with the thing under the
--     crosshair at once, as a click would (Client/LookAt.lua finds it, the
--     server classifies and starts it: Server/Combat/Interact.lua).
-- Only interactive things are highlighted: BG3's highlight circle under it
-- (Client/WorldFx.lua), "[F]" on it and "[F] Open Chest" under the crosshair
-- (Client/HUD/Overlay.lua). F replaces BG3's ToggleWeaponSet in first person.

local Log       = Ext.Require("Shared/Log.lua")
local Net       = Ext.Require("Shared/Net.lua")
local ClientNet = Ext.Require("Client/Net.lua")
local State     = Ext.Require("Client/Combat/State.lua")
local LookAt    = Ext.Require("Client/LookAt.lua")
local WorldFx   = Ext.Require("Client/WorldFx.lua")
local Overlay   = Ext.Require("Client/HUD/Overlay.lua")
local Hud       = Ext.Require("Client/HUD/Hud.lua")
local TickBudget = Ext.Require("Shared/TickBudget.lua")
local cfg       = Ext.Require("data/interact.lua")
local Me = Ext.Require("Client/Me.lua")   -- the local player's character (multiplayer)

local M = {}

local KEY = "F"
local reviveSource = nil     -- fn() -> { uuid, name, progress?, by? } | nil (Client/Downed.lua)
local holding = nil          -- uuid being revived while F is held
local shownUuid = nil
local lastAt = -1e9

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

function M.SetReviveSource(fn) reviveSource = fn end

-- A chest / corpse loot window opened with F: the cursor is free (Hud counts
-- it as an open menu) until the server says it closed, Esc, or we walk away.
local lootOpen = nil   -- { target, name, at }
local function lootClose(why)
    if not lootOpen then return end
    Log.Write(string.format("Interact: %s window closed (%s) -> first person back", tostring(lootOpen.name), tostring(why)))
    lootOpen = nil
    Hud.SetExternalMenu(nil)
end
function M.OnEscape() if lootOpen then lootClose("Esc") end end

local function distTo(uuid)
    local ok, d = pcall(function()
        local a = Me.All()[1].Transform.Transform.Translate
        local b = Ext.Entity.Get(uuid).Transform.Transform.Translate
        local dx, dz = a[1] - b[1], a[3] - b[3]
        return math.sqrt(dx * dx + dz * dz)
    end)
    return ok and d or nil
end
function M.Holding() return holding end

local function stopHold(why)
    if not holding then return end
    ClientNet.Send(Net.Channels.ReviveHold, { target = holding, hold = false, why = why })
    Log.Write(string.format("Interact: revive of %s let go (%s)", tostring(holding), tostring(why)))
    holding = nil
end
-- Another action (swing, cast, jump, potion) cancels a revive in progress.
function M.CancelRevive(why) stopHold(why or "another action") end

local function clearHighlight()
    if shownUuid then WorldFx.Clear("interact"); shownUuid = nil end
    Overlay.Markers(nil)
end

local function update()
    local t = now()
    if t - lastAt < 66 then return end
    lastAt = t
    if lootOpen and t - lootOpen.at > 1500 then
        local d = distTo(lootOpen.target)
        if d and d > (cfg.server_reach_m or 6) + 1 then lootClose(string.format("walked away, %.1f m", d)) end
    end
    -- A spell is armed: the crosshair belongs to targeting (Targeting.lua
    -- draws its own markers); F still works, nothing is highlighted here.
    if State.armedSpell then
        if shownUuid or not M.armedQuiet then
            M.armedQuiet = true
            if shownUuid then WorldFx.Clear("interact"); shownUuid = nil end
            Overlay.Prompt(nil)
        end
        return
    end
    M.armedQuiet = false
    if not State.IsCombatActive() or State.uiPaused or State.downed then
        clearHighlight()
        if not State.downed then Overlay.Prompt(nil) end
        if holding and not State.IsCombatActive() then stopHold("first person paused") end
        return
    end
    local rv = reviveSource and reviveSource() or nil
    if rv then
        clearHighlight()
        if holding then
            Overlay.Prompt("Reviving " .. tostring(rv.name or "ally") .. "... keep holding F")
        elseif rv.by then
            Overlay.Prompt(tostring(rv.by) .. " is reviving " .. tostring(rv.name or "ally"))
        else
            Overlay.Prompt("Hold F to revive " .. tostring(rv.name or "ally"))
        end
        return
    end
    if holding then stopHold("out of range") end
    local r = LookAt.Get()
    local o = r and r.object or nil
    if o and not o.pending and o.kind then
        local verb = o.verb or cfg.verbs[o.kind] or "Use"
        Overlay.Prompt(string.format("[F] %s %s", verb, o.name or ""))
        if cfg.marker ~= false then
            if shownUuid ~= o.uuid then
                shownUuid = o.uuid
                if o.ent then WorldFx.OnEntity("interact", "hover", o.ent) end
            end
            local p = nil
            pcall(function()
                local tr = o.ent.Transform.Transform.Translate
                p = { tr[1], tr[2] + (o.kind == "talk" and 2.0 or 0.6), tr[3] }
            end)
            Overlay.Markers(p and { { pos = p, text = "[F]" } } or nil)
        end
    else
        clearHighlight()
        Overlay.Prompt(nil)
    end
end

-- KeyInput from Input.lua (only while first person is live and no panel is open).
function M.OnKey(event, evt)
    local down = evt == "KeyDown"
    if down and event.Repeat then return true end
    if down then
        local rv = reviveSource and reviveSource() or nil
        if rv and not rv.by then
            holding = rv.uuid
            ClientNet.Send(Net.Channels.ReviveHold, { target = rv.uuid, hold = true })
            Log.Write("Interact: F held -> revive " .. tostring(rv.name or rv.uuid))
            return true
        end
        local r = LookAt.Get()
        local o = r and r.object or nil
        if o and not o.pending and o.kind then
            ClientNet.Send(Net.Channels.InteractRequest, { target = o.uuid })
            Log.Write(string.format("Interact: F -> %s %s (%s, %.1f m, via %s)", tostring(o.verb), tostring(o.name), o.uuid, o.dist or 0,
                tostring(o.how)))
        else
            Log.Write("Interact: F pressed, nothing interactive under the crosshair" .. (o and o.pending and " (still asking the server)" or ""))
        end
    else
        if holding then stopHold("F released") end
    end
    return true
end
M.KEY = KEY

function M.Register()
    Ext.RegisterNetListener(Net.Channels.InteractResult, function(_, payload)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" then return end
        Log.Write(string.format("Interact: server %s %s (%s)", p.ok and "started" or "refused", tostring(p.target), tostring(p.how)))
        if p.target then LookAt.Forget(p.target) end
        if not p.ok and p.how then Overlay.Toast(tostring(p.how), 2) end
    end)
    Ext.RegisterNetListener(Net.Channels.ContainerUI, function(_, payload)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" then return end
        if p.open then
            lootOpen = { target = p.target, name = p.name or "container", at = now() }
            Hud.SetExternalMenu("Loot " .. tostring(p.name or ""))
            Log.Write(string.format("Interact: %s window open -> cursor free until it closes", tostring(p.name)))
        elseif lootOpen and (not p.target or p.target == lootOpen.target) then
            lootClose(p.why or "closed")
        end
    end)
    Ext.Events.Tick:Subscribe(TickBudget.Wrap("Interact", update))
    Log.Write("Interact: registered (F: tap = interact, hold = revive a downed ally)")
end

return M
