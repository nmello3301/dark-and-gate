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
--   * control stays on a downed player: when BG3 hands that user's control to
--     another party member (playtest 2026-10-13: Lae'zel, who then counted as
--     "controlled", got no AI and stood still until she went down too), it is
--     handed back (MakePlayerActive, the story's own call; Brawl's portrait
--     re-select as the fallback), so the companion keeps fighting on AI.
--   * BG3's game over waits for the bleed-out. The story (GLO_GameOverLogic)
--     ends the game once every party member is "defeated", and downed counts:
--     the second downing ended the game at once. While a party member is
--     downed, "Downed" is in the story's own list of defeats that don't end
--     the game (DB_GameOver_DefeatCausesNotGameOver, where Larian keeps
--     TempBanished / TempPetrified); only then, so saves without anyone downed
--     don't carry it. A downed character who dies was already "defeated", so
--     the story doesn't check again: its check (PROC_GameOver_CheckGameOver)
--     runs after such a death unless the story ran it itself.
--   * 0 HP always means downed (playtest 2026-10-15: BG3 said "no longer
--     downed" 60 ms after Gale and Shadowheart went down, they stayed at
--     0 HP, hits on them were ignored as "downed" and no bleed-out started:
--     unkillable). A "no longer downed" at 0 HP is not an up (checked again
--     after 500 ms), and a party member alive at 0 HP for zero_hp_s that we
--     don't count as downed gets our downed status again and bleeds out.
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

local MPFeatures = Ext.Require("Shared/MPFeatures.lua")   -- multiplayer kill switches

local M = {}

local PASSIVE = "DAG_BleedOut"
local DOWNED_STATUS = "DAG_BLEEDOUT_DOWNED"   -- what the passive makes BG3 apply at 0 HP
local NULL = "NULL_00000000-0000-0000-0000-000000000000"
local D = cfg.downed

local downed = {}      -- uuid -> { since, left, total, reviver, kind = "player"|"companion", progress, paused, outOfRange }
local pendingDown = {} -- uuid -> ms to confirm at
local upCheck = {}     -- downed uuid -> ms: BG3 said "up" at 0 HP, look at the HP again then
local zeroSince = {}   -- uuid -> ms it was first seen alive at 0 HP without being downed
local graceUntil = {}  -- uuid -> ms: just revived, the 0-HP check waits
local companionGoing = {} -- companion uuid -> downed uuid
local modeSource = nil -- fn(companionUuid) -> "follow"|"wait"|"camp"
local lastBroadcast = -1e9
local holdTries = {}   -- downed uuid -> times control was handed back this down
local holdCheck = {}   -- downed uuid -> { at, user, other }: is control back?
local GAMEOVER_CAUSE = "Downed"
local gameOverHeld = false
local storyCheckAt = -1e9     -- the story's last PROC_GameOver_CheckGameOver
local deathCheck = nil        -- { at, since }: run the game-over check unless the story did
local gaveUp = {}             -- Osiris user id -> true: pressed Give up while nobody stood
local ended = false           -- everyone gave up and BG3's game over is up: nothing runs any more

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

local function hasDownedStatus(u)
    local ok, v = pcall(function() return Osi.HasAppliedStatusOfType(u, "DOWNED") end)
    return ok and tonumber(v) == 1
end

local function downedNow(u)
    if downed[u] or pendingDown[u] then return true end
    return hasDownedStatus(u)
end

local function downedStatusName(u)
    local s = nil
    pcall(function() s = tostring(Ext.Entity.Get(u).Downed.DownedStatus) end)
    return (s and s ~= "" and s ~= "nil") and s or nil
end

local function zeroHp(u)
    local hp = Damage.Hp(u)
    return hp ~= nil and hp <= 0, hp
end

-- ---------------------------------------------------------------------
-- BG3's game over waits while a party member bleeds out (header)
-- ---------------------------------------------------------------------
local function partyDown()
    for u in pairs(downed) do if Party.IsMember(u) then return true end end
    for u in pairs(pendingDown) do if Party.IsMember(u) then return true end end
    return false
end

local function gameOverFact()
    local ok, rows = pcall(function() return Osi.DB_GameOver_DefeatCausesNotGameOver:Get(GAMEOVER_CAUSE) end)
    return ok and type(rows) == "table" and #rows > 0
end

local function syncGameOver(why)
    if ended then return end
    local want = partyDown()
    if want == gameOverHeld then return end
    local ok, err = pcall(function()
        if want then Osi.DB_GameOver_DefeatCausesNotGameOver(GAMEOVER_CAUSE)
        else Osi.DB_GameOver_DefeatCausesNotGameOver:Delete(GAMEOVER_CAUSE) end
    end)
    gameOverHeld = want
    Log.Write(string.format("Downed: BG3's game over %s (%s)%s", want and "waits while a party member bleeds out" or "is vanilla again (nobody downed)",
        why, ok and "" or (" ERROR " .. tostring(err))))
end

local function partyCounts()
    local up, down, dead = 0, 0, 0
    for _, u in ipairs(Party.Members()) do
        if isDead(u) then dead = dead + 1 elseif downedNow(u) then down = down + 1 else up = up + 1 end
    end
    return up, down, dead
end

-- A downed party member died: the story won't check for a game over by itself.
local function checkAfterDeath()
    local t = now()
    if not deathCheck then deathCheck = { at = t + 1000, since = t } end
end

-- ---------------------------------------------------------------------
-- Broadcast
-- ---------------------------------------------------------------------
-- standing: party members on their feet (0 = the Give up button shows).
local function send(uuid, st, state, standing)
    local msg = {
        uuid = uuid, name = name(uuid), state = state, left = st and st.left or 0, total = st and st.total or 0,
        paused = st and st.reviver ~= nil or false, reviver = st and st.reviver or nil,
        reviverName = st and st.reviver and name(st.reviver) or nil, progress = st and st.progress or 0,
        outOfRange = st and st.outOfRange or false, reviveS = D.revive_s,
        standing = standing or (partyCounts()),
    }
    pcall(function() Ext.Net.BroadcastMessage(Net.Channels.DownedState, Ext.Json.Stringify(msg)) end)
end

local function broadcastAll()
    local standing = partyCounts()
    for u, st in pairs(downed) do send(u, st, "downed", standing) end
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

-- 0 HP but not downed in BG3's eyes: our downed status again (if it takes),
-- and the bleed-out starts either way, so the character can die.
local function forceDown(uuid, why)
    local had = hasDownedStatus(uuid)
    local res = "had one"
    if not had then
        local ok, err = pcall(function() Osi.ApplyStatus(uuid, DOWNED_STATUS, -1, 1, uuid) end)
        res = ok and ("applied " .. DOWNED_STATUS) or ("ApplyStatus ERROR " .. tostring(err))
    end
    Log.Write(string.format("Downed: %s is alive at 0 HP but BG3 doesn't count it as downed (%s) -> downed by us (downed status: %s)",
        name(uuid), why, res))
    pendingDown[uuid], zeroSince[uuid], graceUntil[uuid] = nil, nil, nil
    startDown(uuid, "0 HP, " .. why)
end

local function upAgain(uuid, why)
    local st = downed[uuid]
    downed[uuid] = nil
    upCheck[uuid] = nil
    holdTries[uuid], holdCheck[uuid] = nil, nil
    gaveUp = {}   -- someone stands again: a give up starts over
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
    graceUntil[uuid] = now() + (D.up_grace_s or 2) * 1000
    upAgain(uuid, "revived by " .. name(reviver))
end

local function bleedOut(uuid)
    if Damage.Invincible(uuid) then
        Log.Write(string.format("Downed: %s would bleed out now, but is in god mode (!dag_god) -> stood up at %d HP", name(uuid), D.revive_hp))
        pcall(function() Osi.RemoveStatusesWithType(uuid, "DOWNED", uuid) end)
        pcall(function() Osi.SetHitpoints(uuid, D.revive_hp, "Guaranteed") end)
        graceUntil[uuid] = now() + (D.up_grace_s or 2) * 1000
        upAgain(uuid, "god mode: no bleed-out")
        return
    end
    downed[uuid] = nil
    holdTries[uuid], holdCheck[uuid] = nil, nil
    local ok, err = pcall(function() Osi.Die(uuid, 3, NULL, 0, 0) end)
    Log.Write(string.format("Downed: %s BLED OUT after %d s -> dead%s (vanilla revives only: Withers, Revivify, scrolls)", name(uuid),
        D.bleedout_s, ok and "" or (" (Osi.Die ERROR " .. tostring(err) .. ")")))
    send(uuid, nil, "dead")
    if Party.IsMember(uuid) then checkAfterDeath() end
end

-- ---------------------------------------------------------------------
-- Control stays on a downed player (header)
-- ---------------------------------------------------------------------
local function onControl(user, new, prev)
    if not prev or prev == new or not Party.IsMember(prev) or isDead(prev) or not downedNow(prev) then return end
    local n = (holdTries[prev] or 0) + 1
    holdTries[prev] = n
    local most = D.control_back_tries or 3
    if n > most then
        if n == most + 1 then
            Log.Write(string.format("Downed: BG3 keeps moving control off %s (downed): left on %s after %d tries", name(prev), name(new), most))
        end
        return
    end
    Log.Write(string.format("Downed: BG3 moved control from %s (downed) to %s -> back to %s, so %s stays on companion AI",
        name(prev), name(new), name(prev), name(new)))
    Ext.OnNextTick(function()
        if isDead(prev) or not downedNow(prev) then return end
        local ok, err = pcall(function() Osi.MakePlayerActive(prev) end)
        if not ok then Log.Write("Downed: MakePlayerActive ERROR " .. tostring(err)) end
        holdCheck[prev] = { at = now() + 500, user = user, other = new, tries = n }
    end)
end

-- Half a second after MakePlayerActive: back, or Brawl's portrait re-select.
local function checkControl(t)
    for u, h in pairs(holdCheck) do
        if t >= h.at then
            holdCheck[u] = nil
            if Party.Controlled(h.user) == u then
                Log.Write(string.format("Downed: control is back on %s", name(u)))
            elseif not isDead(u) and downedNow(u) then
                local ok = pcall(function() Ext.Net.PostMessageToUser(h.user, "DAG_BrawlSelectCharacter", u) end)
                Log.Write(string.format("Downed: control still on %s after MakePlayerActive -> %s's portrait re-selected on the client%s",
                    name(Party.Controlled(h.user) or h.other), name(u), ok and "" or " (send FAILED)"))
            end
        end
    end
end

-- ---------------------------------------------------------------------
-- Give up (developer 2026-10-13: so nobody waits 3 min when no one is left
-- to revive them). Offered while no party member stands. Each player (each
-- Osiris user with characters in the party) gives up once; when all have,
-- "Downed" leaves the story's not-a-game-over list and the story's own check
-- runs: BG3's party-wipe game over, exactly as vanilla when everyone is
-- down. Nobody is killed for it.
-- ---------------------------------------------------------------------
local function reply(peer, t)
    pcall(function() Ext.Net.PostMessageToUser(peer, Net.Channels.GiveUpReply, Ext.Json.Stringify(t)) end)
end

local function partyUsers()
    local seen, list = {}, {}
    for _, u in ipairs(Party.Members()) do
        local user = Party.UserOf(u)
        if user and not seen[user] then seen[user] = true; list[#list + 1] = user end
    end
    return list
end

local function endGame(why)
    ended = true
    pcall(function() Osi.DB_GameOver_DefeatCausesNotGameOver:Delete(GAMEOVER_CAUSE) end)
    gameOverHeld = false
    local okC, err = pcall(function() Osi.PROC_GameOver_CheckGameOver() end)
    -- User queries answer true / false (SE Docs/API.md).
    local okA, alive = pcall(function() return Osi.QRY_GameOver_AliveCharactersLeft() end)
    local okB, blocked = pcall(function() return Osi.QRY_GameOver_BlockGameOver() end)
    if (okA and alive == true) or (okB and blocked == true) then
        ended, gaveUp = false, {}
        Log.Write(string.format("Downed: everyone gave up (%s), but BG3 shows no game over now (%s) -> the bleed-out goes on", why,
            (okB and blocked == true) and "the story blocks it here" or "the story still counts someone as standing"))
        pcall(function() Ext.Net.BroadcastMessage(Net.Channels.Toast, Ext.Json.Stringify({ text = "BG3 doesn't allow a game over right now", secs = 4 })) end)
        return
    end
    Log.Write(string.format("Downed: GAME OVER (%s): BG3's party-wipe game over%s", why, okC and "" or (" ERROR " .. tostring(err))))
    pcall(function() Ext.Net.BroadcastMessage(Net.Channels.GameOver, Ext.Json.Stringify({ by = why })) end)
end

local function giveUp(peer, uuid)
    if ended then return end
    local user = Party.UserFromPeer(peer)
    if not uuid or not Party.IsMember(uuid) or Party.UserOf(uuid) ~= user or not (isDead(uuid) or downedNow(uuid)) then
        Log.Write(string.format("Downed: give up refused: %s isn't this player's downed or dead character", name(uuid)))
        reply(peer, { ok = false, text = "You can only give up while you are down" })
        return
    end
    local up = partyCounts()
    if up > 0 then
        Log.Write(string.format("Downed: %s's give up refused: %d party member(s) still standing", name(uuid), up))
        reply(peer, { ok = false, text = "Someone in your party is still standing" })
        return
    end
    gaveUp[user] = true
    local waiting = {}
    for _, u in ipairs(partyUsers()) do
        if not gaveUp[u] then waiting[#waiting + 1] = name(Party.Controlled(u) or "?") end
    end
    if #waiting > 0 then
        Log.Write(string.format("Downed: %s gave up; waiting for %s", name(uuid), table.concat(waiting, ", ")))
        reply(peer, { ok = true, waiting = true, text = "Waiting for " .. table.concat(waiting, ", ") .. " to give up" })
        return
    end
    reply(peer, { ok = true })
    endGame(name(uuid) .. " gave up")
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
    if not MPFeatures.On("revive") then return end   -- host switch: only players revive
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
local zeroCheckAt = -1e9
local ZERO_CHECK_MS = 250   -- how often party HP is looked at for the 0-HP rule
local function tick()
    if ended then return end
    local t = now()
    for u, at in pairs(pendingDown) do
        if t >= at then
            pendingDown[u] = nil
            if not isDead(u) then
                local zero, hp = zeroHp(u)
                if hasDownedStatus(u) then startDown(u, "0 HP")
                elseif zero then forceDown(u, "BG3 dropped its downed state within 500 ms")
                else
                    Log.Write(string.format("Downed: %s went down but is up again within 500 ms at %s HP (Relentless Endurance / Death Ward / healed?)",
                        name(u), tostring(hp)))
                end
            end
        end
    end
    -- BG3 said "up" while the HP was 0: up only if the HP came back meanwhile.
    for u, at in pairs(upCheck) do
        if t >= at then
            upCheck[u] = nil
            local zero, hp = zeroHp(u)
            if downed[u] and not isDead(u) then
                if not zero then upAgain(u, "BG3: no longer downed, HP " .. tostring(hp))
                else
                    -- The status once more at most (BG3 may drop it again: no
                    -- re-apply loop); the bleed-out runs on our timer anyway.
                    local st = downed[u]
                    st.flips = (st.flips or 0) + 1
                    local res = "kept"
                    if not hasDownedStatus(u) then
                        if st.flips <= 1 then
                            local ok = pcall(function() Osi.ApplyStatus(u, DOWNED_STATUS, -1, 1, u) end)
                            res = ok and ("re-applied " .. DOWNED_STATUS) or "re-apply FAILED"
                        else
                            res = "gone, not re-applied again"
                        end
                    end
                    if st.flips <= 3 then
                        Log.Write(string.format("Downed: %s still at 0 HP 500 ms after BG3's \"no longer downed\" -> stays downed, bleed-out goes on (downed status %s)",
                            name(u), res))
                    end
                end
            end
        end
    end
    -- Alive at 0 HP and not downed: downed by us (header).
    if t >= zeroCheckAt then
        zeroCheckAt = t + ZERO_CHECK_MS
        if not Party.InCharacterCreation() then
            for _, u in ipairs(Party.Members()) do
                if downed[u] or pendingDown[u] or (graceUntil[u] or 0) > t or isDead(u) or not zeroHp(u) then
                    zeroSince[u] = nil
                else
                    zeroSince[u] = zeroSince[u] or t
                    local held = (t - zeroSince[u]) / 1000
                    if held >= (D.zero_hp_s or 0.5) then
                        forceDown(u, string.format("0 HP for %.1f s, BG3's downed status %s", held, downedStatusName(u) or "none"))
                    end
                end
            end
        end
    end
    if next(holdCheck) then checkControl(t) end
    if deathCheck and t >= deathCheck.at then
        local since = deathCheck.since
        deathCheck = nil
        syncGameOver("a downed party member died")
        if storyCheckAt < since then
            local up, down, dead = partyCounts()
            local ok, err = pcall(function() Osi.PROC_GameOver_CheckGameOver() end)
            Log.Write(string.format("Downed: BG3's game-over check after the death (party: %d standing, %d downed, %d dead%s)%s", up, down, dead,
                (up == 0 and down == 0) and ": nobody left, game over" or "", ok and "" or (" ERROR " .. tostring(err))))
        end
    end
    syncGameOver("the downed list changed")
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
        local zero, hp = zeroHp(u)
        if tonumber(isDowned) == 1 then
            Log.Write(string.format("Downed: BG3 says %s is downed (HP %s, downed status %s)", name(u), tostring(hp), downedStatusName(u) or "none"))
            pendingDown[u] = now() + 500
            -- Now, before the story's own 500 ms check marks them defeated.
            syncGameOver(name(u) .. " went down")
        else
            Log.Write(string.format("Downed: BG3 says %s is no longer downed (HP %s, downed status %s, %s)", name(u), tostring(hp),
                downedStatusName(u) or "none", downed[u] and "downed for us" or pendingDown[u] and "down not confirmed yet" or "not downed for us"))
            -- At 0 HP that's no up (header): a pending down is confirmed by the
            -- HP in its 500 ms check, a running one looks again in 500 ms.
            if zero and not isDead(u) and (downed[u] or pendingDown[u]) then
                if downed[u] then upCheck[u] = now() + 500 end
                return
            end
            pendingDown[u] = nil
            if downed[u] then upAgain(u, "BG3: no longer downed (healed?)") end
        end
    end)
    Ext.Osiris.RegisterListener("Died", 1, "after", function(char)
        local u = Party.Norm(char)
        local wasDown = downed[u] ~= nil or pendingDown[u] ~= nil
        if downed[u] then downed[u] = nil; send(u, nil, "dead") end
        pendingDown[u], holdTries[u], holdCheck[u] = nil, nil, nil
        upCheck[u], zeroSince[u], graceUntil[u] = nil, nil, nil
        cancelBy(u, "died")
        if wasDown and Party.IsMember(u) then checkAfterDeath() end
    end)
    -- Brought back the vanilla ways (Withers, Revivify, a scroll): the client
    -- leaves the "YOU DIED" camera.
    Ext.Osiris.RegisterListener("Resurrected", 1, "after", function(char)
        local u = Party.Norm(char)
        if Party.IsMember(u) then
            Log.Write("Downed: " .. name(u) .. " was resurrected -> first person again")
            gaveUp = {}
            send(u, nil, "up")
        end
    end)
    -- The downed screen's Give up button / G (Client/Downed.lua).
    Ext.RegisterNetListener(Net.Channels.GiveUp, function(_, payload, peer)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" then return end
        Ext.OnNextTick(function() giveUp(peer, Party.Norm(p.uuid)) end)
    end)
    Ext.Osiris.RegisterListener("PROC_GameOver_CheckGameOver", 0, "after", function() storyCheckAt = now() end)
    Party.OnControl(onControl)
    Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function()
        ensurePassives("level start")
        -- A save made while downed: the status survived, our timer didn't.
        for _, u in ipairs(Party.Members()) do
            local ok, v = pcall(function() return Osi.HasAppliedStatusOfType(u, "DOWNED") end)
            if ok and tonumber(v) == 1 and not isDead(u) then startDown(u, "still downed after a load: timer restarted") end
        end
        -- The story's game-over list as the save has it (a save made while downed carries our fact).
        gameOverHeld = gameOverFact()
        syncGameOver("level start")
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
    -- !dag_downme [all]: you, or every party member still standing (to test
    -- the game over waiting and the Give up button).
    ConsoleForward.Server("dag_downme", function(_, a)
        local c = ConsoleForward.Caller()
        local me = (c and Party.CharacterOfPeer(c.peer)) or Party.Controlled(nil)
        local list = { me }
        if a == "all" then
            list = {}
            for _, u in ipairs(Party.Members()) do
                if not isDead(u) and not downedNow(u) then list[#list + 1] = u end
            end
        end
        for _, u in ipairs(list) do
            local hp = Damage.Hp(u) or 1
            -- God mode would stop the hit: lifted for it, back once down.
            local god = Damage.Invincible(u)
            if god then pcall(function() Osi.RemoveStatus(u, Damage.GOD_STATUS, u) end) end
            Log.Write(string.format("Downed: !dag_downme%s -> %d damage to %s (BG3's downed flow)%s", a == "all" and " all" or "", hp + 5,
                name(u), god and "; god mode lifted for this hit" or ""))
            pcall(function() Osi.ApplyDamage(u, hp + 5, "Bludgeoning", NULL) end)
            if god then
                Ext.Timer.WaitFor(1500, function()
                    local ok = pcall(function() Osi.ApplyStatus(u, Damage.GOD_STATUS, -1, 1, u) end)
                    Log.Write(string.format("Downed: god mode back on %s%s", name(u), ok and "" or " (ApplyStatus FAILED)"))
                end)
            end
        end
    end)
    ensurePassives("register")
    Log.Write(string.format("Downed: registered (bleed-out %d s, revive %.1f s within %.1f m, up at %d HP)", D.bleedout_s, D.revive_s,
        D.revive_range_m, D.revive_hp))
end

return M
