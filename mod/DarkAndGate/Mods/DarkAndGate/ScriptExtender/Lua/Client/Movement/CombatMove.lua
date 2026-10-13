-- SPDX-License-Identifier: GPL-3.0-or-later
-- WASD in real-time fights (DECISIONS 2026-10-12), the fallback path.
--
-- BG3 itself refuses WASD while a character is in a combat; the DLL skips
-- that one check while first person is on (tools/native CombatWasd.cpp), so
-- a fight walks and runs exactly like exploration: same speed, BG3WASD's
-- walk / run toggle, our speed modifiers. If WASD is held in first person and
-- the character doesn't move anyway (the DLL patch missing or not enough),
-- this file hands the movement to the server (Server/Combat/CombatMove.lua):
-- Osi.CharacterMoveToPosition toward a point a few metres ahead in the WASD
-- direction, refreshed on turns, at the walk / run gait you have on. Only in
-- a real-time fight (the server says when one starts / ends), and only until
-- BG3's own WASD has been seen moving you in one: from then on a wall simply
-- stops you, as in exploration.
--
--   !dag_combat_move auto|server|off   auto (default), always the server, never

local Log       = Ext.Require("Shared/Log.lua")
local Net       = Ext.Require("Shared/Net.lua")
local ClientNet = Ext.Require("Client/Net.lua")
local State     = Ext.Require("Client/Combat/State.lua")
local Aim       = Ext.Require("Client/Combat/Aim.lua")
local Movement  = Ext.Require("Client/Movement/Movement.lua")
local Actions   = Ext.Require("Client/Combat/Actions.lua")
local D         = Ext.Require("data/movement.lua").combat_move

local M = {}

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local held = {}            -- W / A / S / D
local mode = D.mode or "auto"
local walking = nil        -- BG3WASD's walk toggle as we last saw it (nil = unknown)
local hold = nil           -- { t0, sent, refused, dx, dz, at, gait } while WASD is held
local stats = { native = 0, server = 0 }
local fight = false            -- the server says a real-time fight is on
local nativeInFight = false    -- BG3's own WASD moved us during a fight (this session)

local function anyHeld() return held.W or held.A or held.S or held.D end

-- WASD direction on the ground, from the camera's forward (flattened).
local function wasdDir()
    local _, fwd = Aim.ReadInvView()
    if not fwd then return nil end
    local fx, fz = fwd[1], fwd[3]
    local l = math.sqrt(fx * fx + fz * fz)
    if l < 1e-3 then return nil end
    fx, fz = fx / l, fz / l
    -- Right of forward on the XZ plane (BG3: +Y up; the strafe sign is the
    -- DLL's, checked in-game for the real jump: data strafe_sign).
    local s = D.strafe_sign or -1
    local rx, rz = -fz * s, fx * s
    local x, z = 0, 0
    if held.W then x, z = x + fx, z + fz end
    if held.S then x, z = x - fx, z - fz end
    if held.D then x, z = x + rx, z + rz end
    if held.A then x, z = x - rx, z - rz end
    local n = math.sqrt(x * x + z * z)
    if n < 1e-3 then return nil end
    return x / n, z / n
end

local function gait()
    local g = Movement.Gait and Movement.Gait()
    if g == "walk" then walking = true elseif g == "run" then walking = false end
    local w = walking
    if w == nil then w = D.default_walk ~= false end
    if not w then
        -- A slowing modifier (bow draw, casting, crouch) brings a run down to a walk.
        local _, run = Movement.Mults()
        if run and run < (D.walk_below_mult or 0.8) then return "Walk" end
        return "Run"
    end
    return "Walk"
end

local function stop(why)
    if hold and hold.sent then
        ClientNet.Send(Net.Channels.CombatMove, { on = false, why = why })
    end
    hold = nil
end

local function blocked()
    return not State.IsCombatActive() or State.uiPaused or State.downed or State.jumping
        or Actions.TimedBusy()
end

local function tick()
    if mode == "off" then if hold then stop("off") end return end
    if not anyHeld() then if hold then stop("keys up") end return end
    local t = now()
    if blocked() then if hold then stop("paused") end return end
    if not hold then hold = { t0 = t, sent = false, refused = false } end
    local v = Movement.Speed() or 0
    if fight and not nativeInFight and not hold.sent and v >= (D.native_mps or 0.8) then
        nativeInFight = true
        Log.Write(string.format("CombatMove: BG3's own WASD moves you in this fight (%.1f m/s; the DLL's combat-check skip works) -> no fallback", v))
    end
    if hold.refused then return end
    if not hold.sent then
        if mode ~= "server" then
            if not fight or nativeInFight then return end
            if v >= (D.native_mps or 0.8) then
                -- BG3's own WASD is moving us: nothing to do this hold.
                hold.refused = true
                stats.native = stats.native + 1
                return
            end
            if t - hold.t0 < (D.fallback_after_s or 0.35) * 1000 or v > (D.still_mps or 0.25) then return end
        end
    end
    local dx, dz = wasdDir()
    if not dx then return end
    local g = gait()
    local turned = true
    if hold.dx then
        local dot = dx * hold.dx + dz * hold.dz
        turned = dot < math.cos(math.rad(D.turn_deg or 12))
    end
    local due = not hold.at or (t - hold.at) >= (D.refresh_s or 0.6) * 1000
    if hold.sent and not turned and not due and g == hold.gait then return end
    hold.dx, hold.dz, hold.at, hold.gait = dx, dz, t, g
    if not hold.sent then
        hold.sent = true
        stats.server = stats.server + 1
        Log.Write(string.format("CombatMove: WASD held %.2f s at %.2f m/s -> the server walks you (%s, mode %s)",
            (t - hold.t0) / 1000, v, g, mode))
    end
    ClientNet.Send(Net.Channels.CombatMove, { on = true, dx = dx, dz = dz, gait = g })
end

function M.Register()
    Ext.Events.KeyInput:Subscribe(function(e)
        local k = tostring(e.Key or "")
        local down = tostring(e.Event or "") == "KeyDown"
        if k == "W" or k == "A" or k == "S" or k == "D" then
            held[k] = down
        elseif (k == "LSHIFT" or k == "LShift") and down and walking ~= nil then
            -- BG3WASD's walk / run toggle (Left Shift, NativeMods\BG3WASD.toml);
            -- a held key's repeats don't toggle.
            local okR, rep = pcall(function() return e.Repeat end)
            if not (okR and rep == true) then walking = not walking end
        end
    end)
    Ext.RegisterNetListener(Net.Channels.CombatMoveState, function(_, payload)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" then return end
        if p.fight ~= nil then
            fight = p.fight == true
            Log.Write("CombatMove: real-time fight " .. (fight and "ON" or "over"))
            if not fight and hold then stop("fight over") end
            return
        end
        if p.refused and hold then hold.refused = true end
        Log.Write("CombatMove: server " .. (p.refused and ("refused (" .. tostring(p.why) .. ")") or ("moves you (" .. tostring(p.why) .. ")")))
    end)
    Ext.Events.Tick:Subscribe(function() local ok, err = pcall(tick); if not ok then Log.Write("CombatMove: tick error " .. tostring(err)) end end)
    Ext.RegisterConsoleCommand("dag_combat_move", function(_, a)
        if a == "auto" or a == "server" or a == "off" then
            mode = a
            nativeInFight = false
            if hold then stop("mode " .. a) end
        end
        Log.Write(string.format("CombatMove: mode %s, fight %s, BG3's own WASD seen in a fight %s (holds moved by BG3's WASD %d, by the server %d; walk toggle %s)",
            mode, fight and "on" or "off", nativeInFight and "yes" or "no", stats.native, stats.server,
            walking == nil and "unknown" or (walking and "walk" or "run")))
    end)
    Log.Write("CombatMove: registered (WASD in fights: BG3's own via the DLL, server fallback; !dag_combat_move auto|server|off)")
end

return M
