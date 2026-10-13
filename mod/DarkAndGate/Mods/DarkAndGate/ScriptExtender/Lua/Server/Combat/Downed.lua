-- SPDX-License-Identifier: GPL-3.0-or-later
-- Downed, bleed-out and revive (DECISIONS 2026-10-12, data/combat.lua downed).
--
-- Every party member carries the hidden passive DAG_BleedOut, which makes
-- our DAG_BLEEDOUT_DOWNED (a DOWNED-type status that stabilises itself:
-- Public/DarkAndGate/Stats/Generated/Data/DAG_Combat.txt) the status BG3
-- applies at 0 HP. So failed death saves and hits can't kill a downed
-- player; Relentless Endurance / Death Ward still stand them up as vanilla.
--   * the bleed-out timer starts 500 ms after DownedChanged (vanilla waits
--     too, for Relentless Endurance); after bleedout_s the character dies
--     (Osi.Die). Death is reversed only the vanilla ways.
--   * the timer pauses while someone revives.
--   * revive = a reviver within revive_range_m for revive_s: players hold
--     F (ReviveHold), companions come by themselves (their highest priority
--     except in "Go to camp", data/combat.lua companion_range_m). Letting go
--     of F or another action (cast, swing, jump, potion) cancels it; moving
--     out of range only pauses it. Up at revive_hp: RemoveStatusesWithType
--     DOWNED + SetHitpoints (Larian's own pattern, Shadowheart on the beach).
-- Every state change is logged and broadcast (DownedState) for the client
-- (Client/Downed.lua: orbit camera, banner, revive bar).
--   !dag_bleedout <s>   !dag_revive_time <s>   !dag_downme   (server or client console)
-- God mode (!dag_god): !dag_downme lifts it for its one hit and puts it back;
-- a character in god mode never bleeds out (stood up at revive_hp instead).

local Log         = Ext.Require("Shared/Log.lua")
local Net         = Ext.Require("Shared/Net.lua")
local TickBudget  = Ext.Require("Shared/TickBudget.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")
local Party       = Ext.Require("Server/Party.lua")
local Damage      = Ext.Require("Server/Combat/Damage.lua")
local CastRequest = Ext.Require("Server/Combat/CastRequest.lua")
local cfg         = Ext.Require("data/combat.lua")

local M = {}

local PASSIVE = "DAG_BleedOut"
local NULL = "NULL_00000000-0000-0000-0000-000000000000"
local D = cfg.downed

local downed = {}      -- uuid -> { since, left, total, reviver, kind = "player"|"companion", progress, paused, outOfRange }
local pendingDown = {} -- uuid -> ms to confirm at
local companionGoing = {} -- companion uuid -> downed uuid
local modeSource = nil -- fn(companionUuid) -> "follow"|"wait"|"camp"
local lastBroadcast = -1e9

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local name = Damage.Name

local function pos(uuid)
    local ok, t = pcall(function() return Ext.Entity.Get(uuid).Transform.Transform.Translate end)
    if ok and t then return { t[1], t[2], t[3] } end
    return nil
end

local function dist(a, b)
    local pa, pb = pos(a), pos(b)
    if not pa or not pb then return 1e9 end
    local dx, dy, dz = pa[1] - pb[1], pa[2] - pb[2], pa[3] - pb[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function isDead(uuid)
    local ok, v = pcall(function() return Osi.IsDead(uuid) end)
    return ok and tonumber(v) == 1
end

function M.SetModeSource(fn) modeSource = fn end
function M.IsDowned(uuid) return downed[Party.Norm(uuid)] ~= nil end
function M.Downed() return downed end

-- ---------------------------------------------------------------------
-- Broadcast
-- ---------------------------------------------------------------------
local function send(uuid, st, state)
    local msg = {
        uuid = uuid, name = name(uuid), state = state, left = st and st.left or 0, total = st and st.total or 0,
        paused = st and st.reviver ~= nil or false, reviver = st and st.reviver or nil,
        reviverName = st and st.reviver and name(st.reviver) or nil, progress = st and st.progress or 0,
        outOfRange = st and st.outOfRange or false, reviveS = D.revive_s,
    }
    pcall(function() Ext.Net.BroadcastMessage(Net.Channels.DownedState, Ext.Json.Stringify(msg)) end)
end

local function broadcastAll()
    for u, st in pairs(downed) do send(u, st, "downed") end
end

-- ---------------------------------------------------------------------
-- Passive on every party member
-- ---------------------------------------------------------------------
local function ensurePassives(why)
    local added = {}
    for _, u in ipairs(Party.Members()) do
        local ok, has = pcall(function() return Osi.HasPassive(u, PASSIVE) end)
        if ok and tonumber(has) ~= 1 then
            local okA, err = pcall(function() Osi.AddPassive(u, PASSIVE) end)
            added[#added + 1] = name(u) .. (okA and "" or (" (ERROR " .. tostring(err) .. ")"))
        end
    end
    if #added > 0 then Log.Write("Downed: bleed-out passive added to " .. table.concat(added, ", ") .. " (" .. why .. ")") end
end

-- ---------------------------------------------------------------------
-- Down / up / die
-- ---------------------------------------------------------------------
local function startDown(uuid, why)
    if downed[uuid] then return end
    local status = "?"
    pcall(function() status = tostring(Ext.Entity.Get(uuid).Downed.DownedStatus) end)
    downed[uuid] = { since = now(), left = D.bleedout_s, total = D.bleedout_s, progress = 0 }
    Log.Write(string.format("Downed: %s is DOWNED (%s; downed status %s) -> bleeds out in %d s unless revived", name(uuid), why,
        status, D.bleedout_s))
    send(uuid, downed[uuid], "downed")
end

local function upAgain(uuid, why)
    local st = downed[uuid]
    downed[uuid] = nil
    for c, t in pairs(companionGoing) do if t == uuid then companionGoing[c] = nil end end
    if st then
        Log.Write(string.format("Downed: %s is UP again (%s) after %.1f s downed, HP %s", name(uuid), why, (now() - st.since) / 1000,
            tostring(Damage.Hp(uuid))))
    end
    send(uuid, nil, "up")
end

local function revive(uuid, reviver)
    local st = downed[uuid]
    Log.Write(string.format("Downed: %s REVIVED by %s (%.1f s hold) -> %d HP", name(uuid), name(reviver), D.revive_s, D.revive_hp))
    pcall(function() Osi.RemoveStatusesWithType(uuid, "DOWNED", reviver) end)
    pcall(function() Osi.SetHitpoints(uuid, D.revive_hp, "Guaranteed") end)
    if st then st.reviver = nil end
    upAgain(uuid, "revived by " .. name(reviver))
end

local function bleedOut(uuid)
    if Damage.Invincible(uuid) then
        Log.Write(string.format("Downed: %s would bleed out now, but is in god mode (!dag_god) -> stood up at %d HP", name(uuid), D.revive_hp))
        pcall(function() Osi.RemoveStatusesWithType(uuid, "DOWNED", uuid) end)
        pcall(function() Osi.SetHitpoints(uuid, D.revive_hp, "Guaranteed") end)
        upAgain(uuid, "god mode: no bleed-out")
        return
    end
    downed[uuid] = nil
    local ok, err = pcall(function() Osi.Die(uuid, 3, NULL, 0, 0) end)
    Log.Write(string.format("Downed: %s BLED OUT after %d s -> dead%s (vanilla revives only: Withers, Revivify, scrolls)", name(uuid),
        D.bleedout_s, ok and "" or (" (Osi.Die ERROR " .. tostring(err) .. ")")))
    send(uuid, nil, "dead")
end

-- ---------------------------------------------------------------------
-- Revivers
-- ---------------------------------------------------------------------
local function setReviver(target, reviver, kind)
    local st = downed[target]
    if not st then return false, "not downed" end
    if st.reviver and st.reviver ~= reviver then return false, name(st.reviver) .. " is already reviving" end
    if not st.reviver then
        st.reviver, st.kind, st.progress, st.outOfRange = reviver, kind, 0, false
        Log.Write(string.format("Downed: %s starts reviving %s (%s; %.1f s, timer paused at %.0f s)", name(reviver), name(target), kind,
            D.revive_s, st.left))
        if kind == "companion" then
            pcall(function() CastRequest.AtTarget(reviver, "DAG_V_Target_Help", target, { options = { "IgnoreHasSpell", "NoMovement", "IgnoreTargetChecks" } }) end)
        end
        send(target, st, "downed")
    end
    return true
end

local function cancelBy(reviver, why)
    for t, st in pairs(downed) do
        if st.reviver == reviver then
            Log.Write(string.format("Downed: revive of %s by %s CANCELLED (%s) at %.0f %%", name(t), name(reviver), why, st.progress * 100))
            st.reviver, st.progress, st.outOfRange = nil, 0, false
            send(t, st, "downed")
        end
    end
    companionGoing[reviver] = nil
end
M.CancelBy = cancelBy

local function eligibleCompanion(c, target)
    if not Party.IsMember(c) or Party.IsControlled(c) or c == target then return false end
    if isDead(c) or Damage.IsDowned(c) or downed[c] then return false end
    if modeSource and modeSource(c) == "camp" then return false end
    return dist(c, target) <= (D.companion_range_m or 25)
end

-- Send the nearest free companion to each downed party member nobody revives.
local function dispatchCompanions()
    for target, st in pairs(downed) do
        if not st.reviver then
            local going = false
            for _, t in pairs(companionGoing) do if t == target then going = true end end
            if not going then
                local best, bestD = nil, 1e9
                for _, c in ipairs(Party.Members()) do
                    if not companionGoing[c] and eligibleCompanion(c, target) then
                        local d = dist(c, target)
                        if d < bestD then best, bestD = c, d end
                    end
                end
                if best then
                    companionGoing[best] = target
                    pcall(function() Osi.PurgeOsirisQueue(best, 1) end)
                    pcall(function() Osi.FlushOsirisQueue(best) end)
                    local ok, err = pcall(function() Osi.CharacterMoveTo(best, target, "Sprint", "DAG_ReviveMove", 1) end)
                    Log.Write(string.format("Downed: %s runs to revive %s (%.1f m; highest priority)%s", name(best), name(target), bestD,
                        ok and "" or (" MoveTo ERROR " .. tostring(err))))
                end
            end
        end
    end
end

-- Brawl's pulse for a companion (NpcCombat's AI.act wrapper): true = it is
-- reviving (or running to), so Brawl must not give it another action.
function M.Act(brawler)
    local c = Party.Norm(brawler.uuid)
    if not c or not Party.IsMember(c) or Party.IsControlled(c) then return false end
    if companionGoing[c] then return true end
    for _, st in pairs(downed) do if st.reviver == c then return true end end
    return false
end

-- Brawl picked Target_Help on a downed ally: our revive instead.
function M.Help(helper, target, onSubmitted, onCompleted)
    helper, target = Party.Norm(helper), Party.Norm(target)
    if not downed[target] then return false end
    if not companionGoing[helper] and eligibleCompanion(helper, target) then companionGoing[helper] = target end
    pcall(onSubmitted or function() end, { RequestGuid = "dag-revive" })
    pcall(onCompleted or function() end, "Target_Help")
    return true
end

-- ---------------------------------------------------------------------
-- Tick
-- ---------------------------------------------------------------------
local lastT = nil
local dispatchAt = -1e9
local function tick()
    local t = now()
    for u, at in pairs(pendingDown) do
        if t >= at then
            pendingDown[u] = nil
            local ok, v = pcall(function() return Osi.HasAppliedStatusOfType(u, "DOWNED") end)
            if ok and tonumber(v) == 1 and not isDead(u) then startDown(u, "0 HP") else
                Log.Write(string.format("Downed: %s went down but is up again within 500 ms (Relentless Endurance / Death Ward?)", name(u)))
            end
        end
    end
    local dt = lastT and math.min(0.5, (t - lastT) / 1000) or 0
    lastT = t
    if next(downed) == nil then return end
    for u, st in pairs(downed) do
        if isDead(u) then downed[u] = nil; send(u, nil, "dead")
        else
            local r = st.reviver
            if r and (isDead(r) or Damage.IsDowned(r)) then cancelBy(r, "the reviver went down") ; r = nil end
            if r then
                local inRange = dist(r, u) <= D.revive_range_m + (st.kind == "player" and 0.5 or 0.3)
                if inRange then
                    if st.outOfRange then st.outOfRange = false; Log.Write("Downed: " .. name(r) .. " is back in range, revive continues") end
                    st.progress = st.progress + dt / math.max(0.1, D.revive_s)
                    if st.progress >= 1 then revive(u, r) end
                elseif not st.outOfRange then
                    st.outOfRange = true
                    Log.Write(string.format("Downed: %s moved out of revive range (%.1f m): progress held at %.0f %%", name(r), dist(r, u), st.progress * 100))
                end
            else
                st.left = st.left - dt
                if st.left <= 0 then bleedOut(u) end
            end
        end
    end
    -- Companions on the way: start reviving on arrival.
    for c, target in pairs(companionGoing) do
        if not downed[target] then companionGoing[c] = nil
        elseif dist(c, target) <= D.revive_range_m + 0.3 then
            companionGoing[c] = nil
            local ok, why = setReviver(target, c, "companion")
            if not ok then Log.Write("Downed: " .. name(c) .. " can't revive " .. name(target) .. ": " .. tostring(why)) end
        end
    end
    if t - dispatchAt > 1000 then dispatchAt = t; dispatchCompanions() end
    if t - lastBroadcast > 250 then lastBroadcast = t; broadcastAll() end
end

function M.Register()
    Ext.Osiris.RegisterListener("DownedChanged", 2, "after", function(char, isDowned)
        local u = Party.Norm(char)
        if tonumber(isDowned) == 1 then
            pendingDown[u] = now() + 500
        else
            pendingDown[u] = nil
            if downed[u] then upAgain(u, "BG3: no longer downed (healed?)") end
        end
    end)
    Ext.Osiris.RegisterListener("Died", 1, "after", function(char)
        local u = Party.Norm(char)
        if downed[u] then downed[u] = nil; send(u, nil, "dead") end
        cancelBy(u, "died")
    end)
    Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function()
        ensurePassives("level start")
        -- A save made while downed: the status survived, our timer didn't.
        for _, u in ipairs(Party.Members()) do
            local ok, v = pcall(function() return Osi.HasAppliedStatusOfType(u, "DOWNED") end)
            if ok and tonumber(v) == 1 and not isDead(u) then startDown(u, "still downed after a load: timer restarted") end
        end
    end)
    Ext.Osiris.RegisterListener("CharacterJoinedParty", 1, "after", function() ensurePassives("joined the party") end)
    -- Players hold F (Client/Interact.lua).
    Ext.RegisterNetListener(Net.Channels.ReviveHold, function(_, payload, peer)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" then return end
        Ext.OnNextTick(function()
            local reviver = Party.CharacterOfPeer(peer)
            local target = Party.Norm(p.target)
            if p.hold then
                local d = dist(reviver, target)
                if d > D.revive_range_m + 1.0 then
                    Log.Write(string.format("Downed: %s's revive of %s refused: %.1f m away", name(reviver), name(target), d))
                    return
                end
                local okS, why = setReviver(target, reviver, "player")
                if not okS then Log.Write("Downed: revive refused: " .. tostring(why)) end
            else
                cancelBy(reviver, p.why or "F released")
            end
        end)
    end)
    -- Another action by a reviving player cancels it (the client says so too).
    for _, ch in ipairs({ Net.Channels.CastSpellRequest, Net.Channels.SpellArm, Net.Channels.JumpStart, Net.Channels.UsePotion,
                          Net.Channels.HitClaim, Net.Channels.BowDraw, Net.Channels.BowRelease }) do
        Ext.RegisterNetListener(ch, function(c, payload, peer)
            if next(downed) == nil then return end
            if c == Net.Channels.SpellArm or c == Net.Channels.BowDraw then
                local ok, p = pcall(Ext.Json.Parse, payload)
                -- a disarm / a cancelled draw is not an action
                if ok and type(p) == "table" and ((c == Net.Channels.SpellArm and not p.spell) or (c == Net.Channels.BowDraw and not p.on)) then return end
            end
            Ext.OnNextTick(function() cancelBy(Party.CharacterOfPeer(peer), "another action: " .. tostring(c):gsub("DAG_", "")) end)
        end)
    end
    Ext.Events.Tick:Subscribe(TickBudget.Wrap("Downed", tick))
    ConsoleForward.Server("dag_bleedout", function(_, v)
        if tonumber(v) then D.bleedout_s = math.max(5, tonumber(v)) end
        Log.Write(string.format("Downed: bleed-out %d s (new downs)", D.bleedout_s))
    end)
    ConsoleForward.Server("dag_revive_time", function(_, v)
        if tonumber(v) then D.revive_s = math.max(0.2, tonumber(v)) end
        Log.Write(string.format("Downed: revive takes %.1f s of holding F within %.1f m", D.revive_s, D.revive_range_m))
    end)
    ConsoleForward.Server("dag_downme", function()
        local c = ConsoleForward.Caller()
        local u = (c and Party.CharacterOfPeer(c.peer)) or Party.Controlled(nil)
        local hp = Damage.Hp(u) or 1
        -- God mode would stop the hit: lifted for it, back once down.
        local god = Damage.Invincible(u)
        if god then pcall(function() Osi.RemoveStatus(u, Damage.GOD_STATUS, u) end) end
        Log.Write(string.format("Downed: !dag_downme -> %d damage to %s (BG3's downed flow)%s", hp + 5, name(u),
            god and "; god mode lifted for this hit" or ""))
        pcall(function() Osi.ApplyDamage(u, hp + 5, "Bludgeoning", NULL) end)
        if god then
            Ext.Timer.WaitFor(1500, function()
                local ok = pcall(function() Osi.ApplyStatus(u, Damage.GOD_STATUS, -1, 1, u) end)
                Log.Write(string.format("Downed: god mode back on %s%s", name(u), ok and "" or " (ApplyStatus FAILED)"))
            end)
        end
    end)
    ensurePassives("register")
    Log.Write(string.format("Downed: registered (bleed-out %d s, revive %.1f s within %.1f m, up at %d HP)", D.bleedout_s, D.revive_s,
        D.revive_range_m, D.revive_hp))
end

return M
