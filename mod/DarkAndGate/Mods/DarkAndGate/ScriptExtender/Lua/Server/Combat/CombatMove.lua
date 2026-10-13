-- SPDX-License-Identifier: GPL-3.0-or-later
-- WASD in real-time fights, server side of the fallback
-- (Client/Movement/CombatMove.lua, DECISIONS 2026-10-12).
--
-- The client asks for this only when WASD is held in first person and BG3's
-- own WASD movement didn't move the character. In a fight, the character
-- walks with Osi.CharacterMoveToPosition toward a point ahead_m metres along
-- the WASD direction (a valid spot near it), at the gait the client sent
-- ("Walk" / "Run": BG3WASD's walk or run, the same speeds as exploration).
-- Each request replaces the move before it; key release stops it. Outside a
-- fight the request is refused (exploration WASD is BG3WASD's).

local Log   = Ext.Require("Shared/Log.lua")
local Net   = Ext.Require("Shared/Net.lua")
local Party = Ext.Require("Server/Party.lua")
local Adapter = Ext.Require("Server/BrawlAdapter.lua")
local D     = Ext.Require("data/movement.lua").combat_move

local M = {}

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local moving = {}   -- uuid -> { since = ms, n = requests, gait }

local function name(u)
    local ok, n = pcall(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(u)) end)
    return (ok and n and n ~= "") and n or tostring(u)
end

local function reply(peer, t)
    pcall(function()
        Ext.Net.PostMessageToUser(Party.UserFromPeer(peer), Net.Channels.CombatMoveState, Ext.Json.Stringify(t))
    end)
end

-- Stop the current Osiris move now (Brawl's override: purge + flush the
-- queue and finish the AI movement state).
local function halt(u)
    pcall(function() Osi.PurgeOsirisQueue(u, 1) end)
    pcall(function() Osi.FlushOsirisQueue(u) end)
    pcall(function()
        local st = Ext.Entity.Get(u).ServerCharacter.AiMovementMachine.CachedStates[4]
        if st and not st.Finished then st.Finished = true end
    end)
end

local function start(u, p, peer)
    local x, y, z = Osi.GetPosition(u)
    if not x then return false, "no position" end
    local dx, dz = tonumber(p.dx) or 0, tonumber(p.dz) or 0
    local l = math.sqrt(dx * dx + dz * dz)
    if l < 1e-3 then return false, "no direction" end
    dx, dz = dx / l, dz / l
    local ahead = D.ahead_m or 4.0
    local tx, tz = x + dx * ahead, z + dz * ahead
    local vx, vy, vz = Osi.FindValidPosition(tx, y, tz, D.valid_radius_m or 1.5, u, 1)
    if not vx then vx, vy, vz = tx, y, tz end
    local gait = (p.gait == "Walk") and "Walk" or "Run"
    halt(u)
    Osi.CharacterMoveToPosition(u, vx, vy, vz, gait, "DAG_CombatMove")
    local m = moving[u]
    if not m then
        m = { since = now(), n = 0 }
        moving[u] = m
        Log.Write(string.format("CombatMove: %s walks by WASD in the fight (%s, %.1f m ahead; BG3's own WASD didn't move them)",
            name(u), gait, ahead))
        reply(peer, { why = gait .. " toward the WASD direction" })
    end
    m.n, m.gait = m.n + 1, gait
    return true
end

-- Every client: a real-time fight started / ended (the fallback only acts in one).
local function fightState(on)
    pcall(function() Ext.Net.BroadcastMessage(Net.Channels.CombatMoveState, Ext.Json.Stringify({ fight = on })) end)
    if not on then moving = {} end
end

function M.Register()
    Adapter.Hook("CombatStarted", function() if Adapter.Enabled() then fightState(true) end end)
    Adapter.Hook("CombatEnded", function() fightState(false) end)
    Ext.RegisterNetListener(Net.Channels.CombatMove, function(_, payload, peer)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" then return end
        Ext.OnNextTick(function()
            local u = Party.CharacterOfPeer(peer)
            if not u then return end
            if not p.on then
                local m = moving[u]
                if m then
                    moving[u] = nil
                    halt(u)
                    Log.Write(string.format("CombatMove: %s stops (%s; %d move(s) in %.1f s)", name(u), tostring(p.why), m.n,
                        (now() - m.since) / 1000))
                end
                return
            end
            local okC, inC = pcall(Osi.IsInCombat, u)
            if not okC or tonumber(inC) ~= 1 then
                reply(peer, { refused = true, why = "not in a fight" })
                return
            end
            local okS, res, why = pcall(start, u, p, peer)
            if not okS or not res then
                Log.Write("CombatMove: move FAILED for " .. name(u) .. ": " .. tostring(okS and why or res))
            end
        end)
    end)
    Log.Write("CombatMove: registered (server walks WASD in fights when BG3's own WASD can't)")
end

return M
