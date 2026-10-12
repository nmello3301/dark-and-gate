-- SPDX-License-Identifier: GPL-3.0-or-later
-- Crouch = sneaking, and our detection (DECISIONS 2026-10-12, data/stealth.lua).
--
-- C (Client/Crouch.lua) toggles BG3's own SNEAKING status here
-- (Osi.ApplyStatus / RemoveStatus, as vanilla scripts do); attacks and
-- damage still end it the vanilla way. Every change goes to the clients
-- (CrouchState) for the speed modifier, the eye and the cones.
--
-- Detection, a few times a second, for every player-controlled character
-- against every hostile NPC nearby that isn't fighting yet:
--   in its cone = within its Sight range and half its FOV of its facing,
--   with line of sight (Osi.HasLineOfSight)
--   * not crouched in a cone -> detected at once
--   * crouched in a cone     -> one check per NPC per check_s (6 s):
--     d20 + the player's Stealth vs the NPC's passive Perception
--     (Osi.CalculatePassiveSkill); success = unseen until the next check,
--     failure = detected
-- Detected = Osi.EnterCombat(npc, player); BG3's combat groups bring the
-- rest of the camp. Vanilla's own sneaker spotting is switched off for NPCs
-- we are checking (SetCanSpotSneakers 0, restored after).
--   !dag_stealth on|off   !dag_stealth_debug on|off

local Log         = Ext.Require("Shared/Log.lua")
local Net         = Ext.Require("Shared/Net.lua")
local Shield      = Ext.Require("Shared/Shield.lua")
local TickBudget  = Ext.Require("Shared/TickBudget.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")
local Party       = Ext.Require("Server/Party.lua")
local Damage      = Ext.Require("Server/Combat/Damage.lua")
local Projectiles = Ext.Require("Server/Combat/Projectiles.lua")
local cfg         = Ext.Require("data/stealth.lua")

local M = {}

local debugOn = false
local nextCheck = {}   -- "npc|player" -> ms of its next stealth check
local silenced = {}    -- npc -> original CanSpotSneakers
local losCache = {}    -- "npc|player" -> { v, at }
local lastTick, lastDebug = -1e9, -1e9
local name = Damage.Name

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local function q(fn, ...)
    local args = table.pack(...)
    local ok, v = pcall(function() return Osi[fn](table.unpack(args, 1, args.n)) end)
    return ok and tonumber(v) or nil
end

local function sneaking(u) return q("HasActiveStatus", u, "SNEAKING") == 1 end

local function broadcast(u, on)
    pcall(function() Ext.Net.BroadcastMessage(Net.Channels.CrouchState, Ext.Json.Stringify({ uuid = u, on = on })) end)
end

local function sight(e)
    local range, fov = cfg.default_sight_m, cfg.default_fov_deg
    pcall(function()
        local s = e.Sight
        local r = tonumber(s.Sight)
        if r and r > 0 then range = (r > 100) and r / 100 or r end
        local f = tonumber(s.FOV)
        if f and f > 0 then fov = f end
    end)
    return range, fov
end

local function los(npc, player)
    local k = npc .. "|" .. player
    local c = losCache[k]
    local t = now()
    if c and t - c.at < 500 then return c.v end
    local v = q("HasLineOfSight", npc, player) == 1
    losCache[k] = { v = v, at = t }
    return v
end

local function detect(npc, player, why)
    nextCheck[npc .. "|" .. player] = nil
    local group = nil
    pcall(function() group = Osi.GetCombatGroupID(npc) end)
    local ok, err = pcall(function() Osi.EnterCombat(npc, player) end)
    Log.Write(string.format("Stealth: %s DETECTS %s (%s) -> fight%s%s", name(npc), name(player), why,
        group and (", combat group " .. tostring(group) .. " joins") or "", ok and "" or (" ERROR " .. tostring(err))))
end

local function check(npc, player, d, ang)
    local okS, stealth = pcall(function() return tonumber(Ext.Entity.Get(player).Stats.Skills[cfg.stealth_skill_index]) end)
    stealth = okS and stealth or 0
    local pp = q("CalculatePassiveSkill", npc, "Perception") or 10
    local roll = math.random(1, 20)
    local total = roll + stealth
    local ok = total >= pp
    Log.Write(string.format("Stealth: check %s vs %s: d20 %d + Stealth %d = %d vs passive Perception %d -> %s (%.1f m, %.0f deg off its view)",
        name(player), name(npc), roll, stealth, total, pp, ok and ("HIDDEN for " .. cfg.check_s .. " s") or "SEEN", d, ang))
    if ok then nextCheck[npc .. "|" .. player] = now() + cfg.check_s * 1000 else detect(npc, player, "failed a stealth check") end
end

local function silence(npc)
    if silenced[npc] ~= nil or not cfg.silence_vanilla then return end
    silenced[npc] = q("CanSpotSneakers", npc) or 1
    pcall(function() Osi.SetCanSpotSneakers(npc, 0) end)
end

local function restore(npc)
    local v = silenced[npc]
    if v == nil then return end
    silenced[npc] = nil
    pcall(function() Osi.SetCanSpotSneakers(npc, v) end)
end

local function tick()
    if not cfg.enabled then return end
    local t = now()
    if t - lastTick < 1000 / cfg.update_hz then return end
    lastTick = t
    local dbg = debugOn and t - lastDebug > 2000
    if dbg then lastDebug = t end
    local seen = {}
    for _, player in ipairs(Party.Members()) do
        if Party.IsControlled(player) and q("IsInCombat", player) ~= 1 and not Damage.IsDowned(player) then
            local okP, pe = pcall(Ext.Entity.Get, player)
            local pp = okP and pe and Projectiles.FeetOf(pe)
            local sneak = sneaking(player)
            for u, c in pairs(Projectiles.Near()) do
                if u ~= player and not Party.IsMember(u) then
                    local f = Projectiles.FeetOf(c.ent)
                    if pp and f then
                        local dx, dy, dz = pp[1] - f[1], pp[2] - f[2], pp[3] - f[3]
                        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                        if d <= cfg.max_range_m and q("IsEnemy", u, player) == 1 and q("IsInCombat", u) ~= 1 and q("IsDead", u) ~= 1 then
                            seen[u] = true
                            if sneak then silence(u) end
                            local range, fov = sight(c.ent)
                            local fwd = Shield.Forward(c.ent)
                            local ang = 0
                            if fwd and d > 0.01 then
                                local hd = math.sqrt(dx * dx + dz * dz)
                                ang = hd > 0.01 and math.deg(math.acos(math.max(-1, math.min(1, (dx * fwd[1] + dz * fwd[3]) / hd)))) or 0
                            end
                            local inCone = d <= range and ang <= fov / 2 and los(u, player)
                            if dbg then
                                Log.Write(string.format("Stealth: %s -> %s %.1f m (sight %.0f m), %.0f deg off (FOV %.0f), LOS %s, %s%s", name(u), name(player),
                                    d, range, ang, fov, tostring(los(u, player)), sneak and "crouched" or "standing", inCone and " -> IN CONE" or ""))
                            end
                            if inCone then
                                if not sneak then detect(u, player, string.format("not crouched, %.1f m, %.0f deg off its view", d, ang))
                                else
                                    local k = u .. "|" .. player
                                    if not nextCheck[k] or t >= nextCheck[k] then check(u, player, d, ang) end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    for npc in pairs(silenced) do if not seen[npc] then restore(npc) end end
end

function M.Register()
    Ext.RegisterNetListener(Net.Channels.CrouchToggle, function(_, _, peer)
        Ext.OnNextTick(function()
            local u = Party.CharacterOfPeer(peer)
            if not u then return end
            local on = not sneaking(u)
            local ok, err
            if on then ok, err = pcall(function() Osi.ApplyStatus(u, "SNEAKING", -1, 1) end)
            else ok, err = pcall(function() Osi.RemoveStatus(u, "SNEAKING") end) end
            Log.Write(string.format("Stealth: C -> %s %s%s", name(u), on and "crouches (SNEAKING)" or "stands up", ok and "" or (" ERROR " .. tostring(err))))
        end)
    end)
    Ext.Osiris.RegisterListener("StatusApplied", 4, "after", function(obj, status)
        if status == "SNEAKING" then broadcast(Party.Norm(obj), true) end
    end)
    Ext.Osiris.RegisterListener("StatusRemoved", 4, "after", function(obj, status)
        if status == "SNEAKING" then
            local u = Party.Norm(obj)
            broadcast(u, false)
            if Party.IsMember(u) then Log.Write("Stealth: " .. name(u) .. " is no longer sneaking") end
        end
    end)
    Ext.Osiris.RegisterListener("EnteredCombat", 2, "after", function(obj) restore(Party.Norm(obj)) end)
    Ext.Events.Tick:Subscribe(TickBudget.Wrap("Stealth", tick))
    ConsoleForward.Server("dag_stealth", function(_, a)
        if a == "on" or a == "off" then cfg.enabled = (a == "on") end
        if not cfg.enabled then for npc in pairs(silenced) do restore(npc) end end
        Log.Write("Stealth: our detection " .. (cfg.enabled and "ON" or "OFF (vanilla detection only)"))
    end)
    ConsoleForward.Server("dag_stealth_debug", function(_, a)
        debugOn = (a ~= "off" and a ~= "0")
        Log.Write("Stealth: debug " .. (debugOn and "ON (every hostile NPC's cone test every 2 s)" or "OFF"))
    end)
    Log.Write(string.format("Stealth: registered (checks every %d s per NPC, %d Hz cone tests, vanilla sneaker spotting %s)", cfg.check_s,
        cfg.update_hz, cfg.silence_vanilla and "silenced near us" or "kept"))
end

return M
