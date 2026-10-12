-- SPDX-License-Identifier: GPL-3.0-or-later
-- Downed, client side (DECISIONS 2026-10-12): the server owns the truth
-- (Server/Combat/Downed.lua broadcasts DownedState); this draws it.
--   * our character downed -> third-person orbit around the body (the DLL's
--     orbit mode, Pov.cpp: the mouse still turns it; A/D or LMB/RMB spin,
--     W/S tilt), Space cycles to an ally's view and back (spectate);
--     banner "DOWNED / bleeding out 2:41 / X is reviving you".
--   * revived -> first person again; bled out -> "YOU DIED", spectating.
--   * a downed ally within revive range -> Interact shows "Hold F to revive";
--     while anyone revives, the bar shows the progress.

local Log       = Ext.Require("Shared/Log.lua")
local Net       = Ext.Require("Shared/Net.lua")
local State     = Ext.Require("Client/Combat/State.lua")
local Aim       = Ext.Require("Client/Combat/Aim.lua")
local FullPov   = Ext.Require("FullPov.lua")
local Overlay   = Ext.Require("Client/HUD/Overlay.lua")
local Interact  = Ext.Require("Client/Interact.lua")
local TickBudget = Ext.Require("Shared/TickBudget.lua")
local cfg       = Ext.Require("data/combat.lua")

local M = {}

local D = cfg.downed
local states = {}        -- uuid -> last DownedState
local mine = nil         -- "downed" | "dead" | nil
local watch = 1          -- index into the spectate list (1 = own body)
local keys = { A = false, D = false, W = false, S = false }
local mouse = { l = false, r = false }

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function entity(uuid)
    local ok, e = pcall(Ext.Entity.Get, uuid)
    return ok and e or nil
end

local function posOf(e)
    local ok, t = pcall(function() return e.Transform.Transform.Translate end)
    return ok and t and { t[1], t[2], t[3] } or nil
end

local function allies()
    local out = { Aim.SelfUuid() }
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "PartyMember")
    if ok and ents then
        for _, e in ipairs(ents) do
            local okU, u = pcall(function() return tostring(e.Uuid.EntityUuid) end)
            local okH, hp = pcall(function() return e.Health.Hp end)
            if okU and u and u ~= out[1] and not (okH and tonumber(hp) and tonumber(hp) <= 0) then out[#out + 1] = u end
        end
    end
    return out
end

local function watched()
    local list = allies()
    if watch > #list then watch = 1 end
    return list[watch], #list
end

local function pushTarget(newTarget)
    local u = watched()
    local e = u and entity(u)
    if not e then return end
    local okV, vis = pcall(function() return e.Visual.Visual end)
    FullPov.SetOrbitTarget(okV and FullPov.AddrOf(vis) or "0", posOf(e), newTarget)
end

local function enter(state)
    mine = state
    State.downed = true
    watch = 1
    FullPov.SetOrbit(true, { dist = D.orbit_distance_m, up = D.orbit_up_m, pmin = D.orbit_pitch_min, pmax = D.orbit_pitch_max,
                             rate = D.orbit_spin_deg_s, tilt_rate = D.orbit_tilt_deg_s })
    pushTarget(true)
    Overlay.Force(true)
    Log.Write("Downed: our character is " .. state .. " -> third-person orbit (mouse / A D / LMB RMB orbit, W S tilt, Space: watch an ally)")
end

local function leave()
    mine = nil
    State.downed = false
    FullPov.SetOrbitInput(0, 0)
    FullPov.SetOrbit(false)
    Overlay.Force(false)
    Overlay.Banner(nil)
    Overlay.Bar(nil)
    Log.Write("Downed: back up -> first person")
end

local function mmss(s) s = math.max(0, math.floor(s + 0.5)); return string.format("%d:%02d", s // 60, s % 60) end

-- Hooks for Client/Combat/Input.lua while downed.
State.downedKey = function(key, down, rep)
    if keys[key] ~= nil then keys[key] = down; return false end
    if key == "SPACE" or key:lower():find("space", 1, true) then
        if down and not rep then
            local _, n = watched()
            watch = (watch % math.max(1, n)) + 1
            local u = watched()
            pushTarget(true)
            Log.Write(string.format("Downed: watching %s (%d of %d)", u == Aim.SelfUuid() and "our own body" or tostring(u), watch, n))
        end
        return true
    end
    return false
end
State.downedMouse = function(lmb, pressed)
    if lmb then mouse.l = pressed else mouse.r = pressed end
end

local function tick()
    local self = Aim.SelfUuid()
    -- Revive bar: we revive someone, or someone revives us.
    local bar, barLabel = nil, nil
    for u, st in pairs(states) do
        if st.state == "downed" and st.reviver then
            if st.reviver == self then
                bar, barLabel = st.progress, string.format("Reviving %s  %.1f / %.1f s%s", st.name or "ally", (st.progress or 0) * (st.reviveS or D.revive_s),
                    st.reviveS or D.revive_s, st.outOfRange and "  (too far)" or "")
            elseif u == self then
                bar, barLabel = st.progress, string.format("%s is reviving you", st.reviverName or "an ally")
            end
        end
    end
    Overlay.Bar(bar, barLabel)
    if not mine then return end
    local spin = ((keys.D or mouse.r) and 1 or 0) - ((keys.A or mouse.l) and 1 or 0)
    local tilt = (keys.W and 1 or 0) - (keys.S and 1 or 0)
    FullPov.SetOrbitInput(spin, tilt)
    pushTarget(false)
    local st = states[self]
    local u = watched()
    local lines
    if mine == "dead" then
        lines = { "YOU DIED", "Withers, Revivify or a scroll can bring you back", "Space: watch an ally" }
    else
        lines = { "DOWNED",
                  st and (st.reviver and string.format("Bleeding out %s (paused)", mmss(st.left or 0)) or string.format("Bleeding out %s", mmss(st.left or 0))) or "",
                  st and st.reviver and (tostring(st.reviverName) .. " is reviving you") or "Allies can revive you: hold F next to you",
                  "Mouse / A D: orbit   W S: tilt   Space: watch " .. (u == self and "an ally" or "your body") }
    end
    Overlay.Banner(lines)
end

function M.Register()
    Ext.RegisterNetListener(Net.Channels.DownedState, function(_, payload)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" or not p.uuid then return end
        local prev = states[p.uuid]
        if p.state == "downed" then states[p.uuid] = p else states[p.uuid] = nil end
        if not prev or prev.state ~= p.state or (prev.reviver ~= p.reviver) then
            Log.Write(string.format("Downed: %s is %s%s", tostring(p.name), tostring(p.state),
                p.reviver and (" (" .. tostring(p.reviverName) .. " reviving)") or ""))
        end
        if p.uuid == Aim.SelfUuid() then
            if p.state == "downed" and mine ~= "downed" then enter("downed")
            elseif p.state == "dead" then if not mine then enter("dead") else mine = "dead" end
            elseif p.state == "up" and mine then leave() end
        end
    end)
    -- Hold F next to a downed ally (Client/Interact.lua asks us).
    Interact.SetReviveSource(function()
        if mine then return nil end
        local me = Aim.SelfFeet()
        local self = Aim.SelfUuid()
        if not me then return nil end
        local best, bestD = nil, nil
        for u, st in pairs(states) do
            if u ~= self and st.state == "downed" then
                local p = posOf(entity(u))
                if p then
                    local dx, dy, dz = p[1] - me[1], p[2] - me[2], p[3] - me[3]
                    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                    if d <= D.revive_range_m and (not bestD or d < bestD) then best, bestD = st, d end
                end
            end
        end
        if not best then return nil end
        return { uuid = best.uuid, name = best.name, by = (best.reviver and best.reviver ~= self) and best.reviverName or nil }
    end)
    Ext.Events.Tick:Subscribe(TickBudget.Wrap("Downed", tick))
    Log.Write("Downed: client registered (orbit camera, spectate, banner, revive bar)")
end

return M
