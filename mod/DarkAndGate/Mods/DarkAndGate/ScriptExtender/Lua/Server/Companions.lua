-- SPDX-License-Identifier: GPL-3.0-or-later
-- V cycles the companion mode (DECISIONS 2026-10-12): Follow -> Wait -> Go
-- to camp -> Follow, for every party companion the pressing player owns
-- (reserved for that user, not the one they control). Vanilla calls only:
--   follow  AttachToPartyGroup(c, leader); from camp first PROC_Camp_Leave(c)
--           (vanilla's own return logic), then a TeleportTo the leader if
--           that left it far away
--   wait    DetachFromPartyGroup(c) + PurgeOsirisQueue / FlushOsirisQueue:
--           it stays where it is (in a fight Brawl's AI still fights)
--   camp    QRY_Camp_GetCamperPos(c) -> DB_QRYRTN_Camp_GetCamperPos ->
--           PROC_Camp_TeleportToCamp(c, spot): the game's own safe teleport
-- Reviving downed players stays their top priority except in camp
-- (Server/Combat/Downed.lua asks Mode()). A toast tells the player.
--
-- Follow is BG3's own party follow and nothing else moves a companion out of
-- fights: chained to its player, it walks BG3's nav grid, climbs and takes
-- the long way. Two gaps (playtest 2026-10-14, data/ai.lua follow):
--   * BG3's followers jump after a leader who uses BG3's Jump; our real jump
--     is not that action, so a ledge reached by jumping left Shadowheart on
--     the beach below the cliff for the rest of the session. The follow
--     assist watches each Follow companion out of fights: one that stays far
--     from its player without closing in (no walking path: a few seconds;
--     a path BG3 isn't using: longer) is caught up with BG3's TeleportTo.
--     It leaves alone companions in a fight, a dialogue or camp, and those
--     their player unchained in BG3's party UI.
--   * Wait: BG3 chained Shadowheart and Gale to the party again right after
--     V detached them (Osiris log: AttachedToPartyGroup with no story rule).
--     A re-chain within follow.wait_hold_s of V is undone (a few times).
-- Multiplayer: every player's companions follow (and are caught up to) the
-- character that player controls.
--   !dag_follow [status|on|off]   (server, or the client console)

local Log   = Ext.Require("Shared/Log.lua")
local Net   = Ext.Require("Shared/Net.lua")
local Party = Ext.Require("Server/Party.lua")
local Hitbox = Ext.Require("Shared/Hitbox.lua")
local TickBudget = Ext.Require("Shared/TickBudget.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")
local aiCfg = Ext.Require("data/ai.lua")

local MPFeatures = Ext.Require("Shared/MPFeatures.lua")   -- multiplayer kill switches

local M = {}

local ORDER = { follow = "wait", wait = "camp", camp = "follow" }
local LABEL = { follow = "Follow", wait = "Wait", camp = "Go to camp" }
local modes = {}   -- Osiris user id -> mode
local waitAt = {}  -- Osiris user id -> ms of the V press that set Wait
local waiting = {} -- companion uuid -> { user, n } detached by that press (re-chains undone)
local dialogs = {} -- open dialogue instances (the follow assist waits)
local quietUntil = 0
local track = {}   -- companion uuid -> follow assist state
local noted = {}   -- companion uuid -> { why, at }: the last "left alone" logged
local lastCheck = -1e9

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local function F() return aiCfg.follow or {} end

local function name(u)
    local ok, n = pcall(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(u)) end)
    return (ok and n and n ~= "") and n or tostring(u)
end

local function try(what, fn)
    local ok, err = pcall(fn)
    return ok and what or (what .. " ERROR " .. tostring(err))
end

local function num(fn)
    local ok, v = pcall(fn)
    return ok and tonumber(v) or nil
end

local function toCamp(c)
    local spot = nil
    pcall(function() Osi.QRY_Camp_GetCamperPos(c) end)
    pcall(function()
        for _, row in pairs(Osi.DB_QRYRTN_Camp_GetCamperPos:Get(c, nil) or {}) do spot = row[2] end
    end)
    if not spot then
        pcall(function()
            for _, row in pairs(Osi.DB_QRYRTN_Camp_GetCamperPos:Get(nil, nil) or {}) do
                if Party.Norm(row[1]) == c then spot = row[2] end
            end
        end)
    end
    if not spot then return "no camp spot (DB_QRYRTN_Camp_GetCamperPos empty)" end
    return try("PROC_Camp_TeleportToCamp -> " .. tostring(spot), function() Osi.PROC_Camp_TeleportToCamp(c, spot) end)
end

local function apply(c, mode, prev, leader)
    if mode == "wait" then
        local a = try("DetachFromPartyGroup", function() Osi.DetachFromPartyGroup(c) end)
        pcall(function() Osi.PurgeOsirisQueue(c, 1) end)
        pcall(function() Osi.FlushOsirisQueue(c) end)
        return a
    elseif mode == "camp" then
        return toCamp(c)
    end
    local parts = {}
    if prev == "camp" then
        parts[#parts + 1] = try("PROC_Camp_Leave", function() Osi.PROC_Camp_Leave(c) end)
        Ext.Timer.WaitFor(1500, function()
            local ok, d = pcall(function() return Osi.GetDistanceTo(c, leader) end)
            if not ok or not tonumber(d) or tonumber(d) > 30 then
                local r = try("TeleportTo the leader", function() Osi.TeleportTo(c, leader, "", 0, 0, 0, 0, 1) end)
                Log.Write(string.format("Companions: %s still %s m away after leaving camp -> %s", name(c), tostring(d), r))
            end
            pcall(function() Osi.AttachToPartyGroup(c, leader) end)
        end)
    end
    parts[#parts + 1] = try("AttachToPartyGroup", function() Osi.AttachToPartyGroup(c, leader) end)
    return table.concat(parts, ", ")
end

function M.Mode(companion)
    return modes[Party.UserOf(companion) or -1] or "follow"
end

-- ---------------------------------------------------------------------
-- Follow assist (data/ai.lua follow)
-- ---------------------------------------------------------------------
local function inCampSet()
    local set = {}
    pcall(function()
        for _, row in pairs(Osi.DB_InCamp:Get(nil) or {}) do
            local u = Party.Norm(row[1])
            if u then set[u] = true end
        end
    end)
    return set
end

-- BG3's pathfinder: a walking path (ladders allowed) from c to the leader?
-- Brawl's Movement.findPathToTargetUuid (Ext.Level.BeginPathfindingImmediate
-- + FindPath, SE Docs/API.md). nil = it couldn't tell.
local function hasPath(c, leader)
    local ok, v = pcall(function() return Movement.findPathToTargetUuid(c, leader) end)
    if not ok then return nil end
    return v == true
end

local function downOrDead(c)
    if num(function() return Osi.IsDead(c) end) == 1 then return true end
    return num(function() return Osi.GetHitpoints(c) end) == 0
end

-- Why the assist leaves c alone right now (nil = it may act).
local function leftAlone(c, leader, campSet, t)
    if next(dialogs) then return "a dialogue is running" end
    if t < quietUntil then return "just after a dialogue or a level start" end
    if num(function() return Osi.IsInCombat(c) end) == 1 or num(function() return Osi.IsInCombat(leader) end) == 1 then return "in a fight" end
    if downOrDead(c) then return "down" end
    if campSet[c] or campSet[leader] then return "in camp" end
    local okR, same = pcall(function() return Osi.GetRegion(c) == Osi.GetRegion(leader) end)
    if okR and not same then return "in another region" end
    if num(function() return Osi.IsOnStage(c) end) == 0 then return "off stage (a scene)" end
    local grp = num(function() return Osi.InSamePartyGroup(c, leader) end)
    if grp == nil then return "BG3's party group can't be read (InSamePartyGroup)" end
    if grp ~= 1 then return "not chained to " .. name(leader) .. " (unchained in BG3's party UI)" end
    return nil
end

local function note(c, leader, d, why, t)
    local n = noted[c]
    if n and n.why == why and t - n.at < (F().log_every_s or 20) * 1000 then return end
    noted[c] = { why = why, at = t }
    Log.Write(string.format("Companions: %s is %.1f m from %s, follow assist leaves it alone: %s", name(c), d, name(leader), why))
end

local function catchUp(c, leader, d, st, t, why)
    local r = try("TeleportTo " .. name(leader), function() Osi.TeleportTo(c, leader, "", 0, 0, 0, 0, 1) end)
    Log.Write(string.format("Companions: %s is %.1f m from %s and hasn't closed in for %.0f s (%s) -> caught up: %s",
        name(c), d, name(leader), (t - st.since) / 1000, why, r))
    track[c] = { coolUntil = t + (F().cooldown_s or 10) * 1000 }
end

local function checkOne(c, leader, campSet, t)
    local Fc = F()
    local d = num(function() return Osi.GetDistanceTo(c, leader) end)
    if not d then track[c] = nil; return end
    local st = track[c]
    if d < (Fc.near_m or 12) then
        if st and st.waitLogged then Log.Write(string.format("Companions: %s caught up with %s by BG3's follow (%.1f m)", name(c), name(leader), d)) end
        track[c], noted[c] = nil, nil
        return
    end
    local why = leftAlone(c, leader, campSet, t)
    if why then
        track[c] = nil
        if d >= (Fc.catchup_m or 25) then note(c, leader, d, why, t) end
        return
    end
    if st and st.coolUntil then
        if t < st.coolUntil then return end
        st = nil
    end
    if not st then
        st = { since = t, best = d }
        track[c] = st
        return
    end
    -- Closing in: BG3's follow is doing it.
    if d < st.best - (Fc.progress_m or 2) then
        st.best, st.since, st.noPath = d, t, 0
        return
    end
    if t - st.since < (Fc.stuck_s or 5) * 1000 then return end
    -- In the air (our real jump): its position is no place to path to yet.
    if Hitbox.Airborne(leader, t) then return end
    if not st.pathAt or t - st.pathAt >= (Fc.path_check_s or 2) * 1000 then
        st.pathAt = t
        local p = hasPath(c, leader)
        st.path = p
        st.noPath = (p == false) and (st.noPath or 0) + 1 or 0
    end
    -- No walking path, twice in a row (a ledge reached by jumping).
    if (st.noPath or 0) >= 2 then
        return catchUp(c, leader, d, st, t, "BG3's pathfinder finds no walking path")
    end
    if d < (Fc.catchup_m or 25) then return end
    if t - st.since >= (Fc.path_stuck_s or 20) * 1000 then
        return catchUp(c, leader, d, st, t, st.path and "BG3 has a walking path but its follow isn't using it" or "BG3's pathfinder can't tell")
    end
    if not st.waitLogged and st.path ~= false then
        st.waitLogged = true
        Log.Write(string.format("Companions: %s is %.1f m from %s and hasn't closed in for %.0f s; %s -> BG3's follow gets until %.0f s",
            name(c), d, name(leader), (t - st.since) / 1000,
            st.path and "BG3 finds a walking path (the long way?)" or "BG3's pathfinder can't tell", Fc.path_stuck_s or 20))
    end
end

local function tick()
    local Fc = F()
    if Fc.assist == false then return end
    local t = now()
    if t - lastCheck < (Fc.check_s or 1) * 1000 then return end
    lastCheck = t
    if Party.InCharacterCreation() then return end
    local campSet = nil
    for _, user in ipairs(Party.Users()) do
        if (modes[user] or "follow") == "follow" then
            local leader = Party.Controlled(user)
            if leader then
                for _, c in ipairs(Party.CompanionsOf(user)) do
                    campSet = campSet or inCampSet()
                    local ok, err = pcall(checkOne, c, leader, campSet, t)
                    if not ok then Log.Write("Companions: follow check of " .. name(c) .. " failed: " .. tostring(err)) end
                end
            end
        end
    end
end

local function status()
    local Fc = F()
    Log.Write(string.format("Companions: follow assist %s (near %.0f m, catch-up from %.0f m after %.0f s without closing in, or %.0f s with no walking path)",
        Fc.assist == false and "OFF" or "ON", Fc.near_m or 12, Fc.catchup_m or 25, Fc.path_stuck_s or 20, Fc.stuck_s or 5))
    local campSet, t = inCampSet(), now()
    for _, user in ipairs(Party.Users()) do
        local leader = Party.Controlled(user)
        for _, c in ipairs(Party.CompanionsOf(user)) do
            local d = leader and num(function() return Osi.GetDistanceTo(c, leader) end)
            local grp = leader and num(function() return Osi.InSamePartyGroup(c, leader) end)
            Log.Write(string.format("  user %s: %s, mode %s, %s m from %s, chained %s%s, left alone: %s", tostring(user), name(c),
                LABEL[modes[user] or "follow"], d and string.format("%.1f", d) or "?", leader and name(leader) or "?",
                grp == 1 and "yes" or (grp == 0 and "no" or "?"), campSet[c] and ", in camp" or "",
                leader and (leftAlone(c, leader, campSet, t) or "no") or "no leader"))
        end
    end
end

function M.Register()
    Ext.RegisterNetListener(Net.Channels.CompanionMode, function(_, _, peer)
        if not MPFeatures.On("companion_v") then return end
        Ext.OnNextTick(function()
            local user = Party.UserFromPeer(peer)
            local leader = Party.Controlled(user)
            local prev = modes[user] or "follow"
            local mode = ORDER[prev]
            local comps = Party.CompanionsOf(user)
            local names, text = {}, nil
            if #comps == 0 then
                text = "No companions to command"
            else
                modes[user] = mode
                waitAt[user] = (mode == "wait") and now() or nil
                for _, c in ipairs(comps) do
                    track[c], noted[c] = nil, nil
                    waiting[c] = (mode == "wait") and { user = user, n = 0 } or nil
                    local how = apply(c, mode, prev, leader)
                    names[#names + 1] = name(c)
                    Log.Write(string.format("Companions: %s -> %s (%s)", name(c), LABEL[mode], how))
                end
                text = "Companions: " .. LABEL[mode] .. " (" .. table.concat(names, ", ") .. ")"
            end
            Log.Write("Companions: V by " .. name(leader) .. " -> " .. text)
            pcall(function() Ext.Net.PostMessageToUser(peer, Net.Channels.Toast, Ext.Json.Stringify({ text = text, secs = 2.5 })) end)
        end)
    end)
    -- Wait: BG3 chaining a companion again right after V detached it.
    Ext.Osiris.RegisterListener("AttachedToPartyGroup", 1, "after", function(char)
        local c = Party.Norm(char)
        local w = c and waiting[c]
        if not w or modes[w.user] ~= "wait" or not waitAt[w.user] then return end
        local Fc, t = F(), now()
        if t - waitAt[w.user] > (Fc.wait_hold_s or 5) * 1000 then return end
        w.n = w.n + 1
        local max = Fc.wait_redetach_max or 3
        if w.n > max then
            if w.n == max + 1 then
                Log.Write(string.format("Companions: BG3 keeps chaining %s to the party after Wait (%d times): left chained, Wait doesn't hold", name(c), w.n))
            end
            return
        end
        Ext.OnNextTick(function()
            if modes[w.user] ~= "wait" then return end
            local r = try("DetachFromPartyGroup", function() Osi.DetachFromPartyGroup(c) end)
            Log.Write(string.format("Companions: BG3 chained %s to the party again %.1f s after Wait -> %s (%d/%d)", name(c),
                (now() - waitAt[w.user]) / 1000, r, w.n, max))
        end)
    end)
    -- The follow assist waits during dialogues and just after them.
    Ext.Osiris.RegisterListener("DialogStarted", 2, "after", function(_, inst) dialogs[tostring(inst)] = true end)
    Ext.Osiris.RegisterListener("DialogEnded", 2, "after", function(_, inst)
        dialogs[tostring(inst)] = nil
        quietUntil = now() + (F().after_scene_s or 5) * 1000
    end)
    Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function()
        dialogs, track = {}, {}
        quietUntil = now() + (F().after_scene_s or 5) * 1000
    end)
    Ext.Events.Tick:Subscribe(TickBudget.Wrap("Follow", tick, 3.0))
    ConsoleForward.Server("dag_follow", function(_, a)
        if a == "on" or a == "off" then
            if type(aiCfg.follow) ~= "table" then aiCfg.follow = {} end
            aiCfg.follow.assist = (a == "on")
            track = {}
        end
        status()
    end)
    local Fc = F()
    Log.Write(string.format("Companions: registered (V: Follow -> Wait -> Go to camp; Follow = BG3's party follow, follow assist %s: a companion that can't reach its player is caught up after %.0f s with no walking path, or from %.0f m after %.0f s; !dag_follow)",
        Fc.assist == false and "OFF" or "ON", Fc.stuck_s or 5, Fc.catchup_m or 25, Fc.path_stuck_s or 20))
end

return M
