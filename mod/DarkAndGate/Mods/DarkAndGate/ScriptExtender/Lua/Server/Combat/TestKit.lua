-- SPDX-License-Identifier: GPL-3.0-or-later
-- Test kit (data/testkit.lua): console commands for testing real-time
-- combat, typed in either console (Shared/ConsoleForward.lua).
--
--   !dag_chest                   a wooden chest ~2 m ahead of you with one of
--                                every weapon type BG3 has, a shield and stacks
--                                of special arrows (its own random loot removed)
--   !dag_goblins [kind [n] ...] [idle]
--                                goblins 9-14 m ahead that fight you at once.
--                                No kinds: scimitar, greataxe, archer, caster.
--                                Kinds: melee brute shield archer caster warlock
--                                cleric. idle = hostile, but they wait until
--                                they see you (stealth tests).
--   !dag_goblins clear | list    remove the ones spawned / list the kinds
--   !dag_god [on|off|party|status]
--                                god mode: no damage from anything (status
--                                DAG_GODMODE: its Invulnerable() boost stops
--                                BG3's damage, Server/Combat/Damage.lua stops
--                                ours). No argument toggles it for you; party =
--                                every party member; off = everyone.
--   !dag_learn <spell>           your character learns a BG3 spell (Osiris
--                                AddSpell), e.g. Target_MistyStep for the
--                                movement playtest's teleport step.
-- Spawning follows the recipe Brawl's encounters use (reference/Brawl,
-- Server/Encounters/Spawn.lua and Init.lua: CreateAt, temporary hostility
-- to the party, EnterCombat or joining the running fight, the "Evil NPC"
-- faction once they're in it). Goblins are temporary characters, listed in
-- DarkAndGate/testkit-spawned.txt and removed at the next level start, like
-- the animation gallery's copies (Server/AnimLib.lua).

local Log            = Ext.Require("Shared/Log.lua")
local Net            = Ext.Require("Shared/Net.lua")
local Shield         = Ext.Require("Shared/Shield.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")
local Party          = Ext.Require("Server/Party.lua")
local Damage         = Ext.Require("Server/Combat/Damage.lua")
local Brawl          = Ext.Require("Server/BrawlAdapter.lua")
local cfg            = Ext.Require("data/testkit.lua")

local M = {}

local SPAWNED_PATH = "DarkAndGate/testkit-spawned.txt"
local spawned = {}   -- goblin uuid -> { kind, at }

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local name = Damage.Name

local function feetOf(u)
    local ok, t = pcall(function() return Ext.Entity.Get(u).Transform.Transform.Translate end)
    if ok and t then return { t[1], t[2], t[3] } end
    local okP, x, y, z = pcall(function() return Osi.GetPosition(u) end)
    if okP and tonumber(x) then return { tonumber(x), tonumber(y), tonumber(z) } end
    return nil
end

local function alive(u)
    local ok, d = pcall(function() return Osi.IsDead(u) end)
    return not (ok and tonumber(d) == 1)
end

local function combatOf(u)
    local ok, g = pcall(function() return Osi.CombatGetGuidFor(u) end)
    return (ok and g and g ~= "") and tostring(g) or nil
end

-- Who typed the command (its character, view, peer). Server console: the host.
local function caller()
    local c = ConsoleForward.Caller()
    local u = (c and Party.CharacterOfPeer(c.peer)) or Party.Controlled(nil)
    return u, c and c.ctx or nil, c and c.peer or nil
end

-- Horizontal unit vector "ahead": the caller's camera, else the facing.
local function ahead(u, ctx)
    local f = ctx and ctx.fwd
    if type(f) == "table" and tonumber(f[1]) and tonumber(f[3]) then
        local x, z = tonumber(f[1]), tonumber(f[3])
        local l = math.sqrt(x * x + z * z)
        if l > 1e-3 then return { x / l, 0, z / l }, "your view" end
    end
    local okE, e = pcall(Ext.Entity.Get, u)
    local sf = okE and e and Shield.Forward(e) or nil
    if sf then return sf, "your facing" end
    return { 1, 0, 0 }, "+X (no view or facing)"
end

local function validNear(x, y, z, r, anchor)
    local ok, vx, vy, vz = pcall(function() return Osi.FindValidPosition(x, y, z, r, anchor, 1) end)
    if ok and tonumber(vx) and tonumber(vy) and tonumber(vz) then return tonumber(vx), tonumber(vy), tonumber(vz), true end
    return x, y, z, false
end

local function toast(peer, text, secs)
    if not peer then return end
    pcall(function() Ext.Net.PostMessageToUser(peer, Net.Channels.Toast, Ext.Json.Stringify({ text = text, secs = secs or 3 })) end)
end

-- ---------------------------------------------------------------------
-- !dag_chest
-- ---------------------------------------------------------------------
local function contents(container)
    local list = {}
    pcall(function()
        for _, inv in pairs(Ext.Entity.Get(container).InventoryOwner.Inventories) do
            for _, slot in pairs(inv.InventoryContainer.Items) do
                local okU, id = pcall(function() return tostring(slot.Item.Uuid.EntityUuid) end)
                if okU and id then list[#list + 1] = id end
            end
        end
    end)
    return list
end

local function shortName(statsName)
    return (statsName:gsub("^WPN_", ""):gsub("^OBJ_", ""):gsub("^ARM_", ""))
end

local function fillChest(chest, flagHow, peer)
    local C = cfg.chest
    local removed = 0
    for _, item in ipairs(contents(chest)) do
        if pcall(function() Osi.RequestDelete(item) end) then removed = removed + 1 end
    end
    local weapons, extras, missing = {}, {}, {}
    local function add(statsName, count, into)
        local okS, st = pcall(Ext.Stats.Get, statsName)
        local rt = ""
        if okS and st then pcall(function() rt = tostring(st.RootTemplate or "") end) end
        if rt == "" or rt == "nil" then missing[#missing + 1] = statsName .. " (no RootTemplate)"; return end
        local ok, err = pcall(function() Osi.TemplateAddTo(rt, chest, count or 1, 0) end)
        if ok then into[#into + 1] = shortName(statsName) .. ((count or 1) > 1 and (" x" .. count) or "")
        else missing[#missing + 1] = statsName .. " (" .. tostring(err) .. ")" end
    end
    for _, w in ipairs(C.weapons) do add(w, 1, weapons) end
    for _, e in ipairs(C.extras) do add(e.stats, e.count, extras) end
    Log.Write(string.format("TestKit: chest %s: %d weapon types (%s); extras: %s%s; its random loot: %s, %d item(s) removed",
        chest, #weapons, table.concat(weapons, ", "), table.concat(extras, ", "),
        #missing > 0 and ("; MISSING " .. table.concat(missing, ", ")) or "", flagHow, removed))
    toast(peer, string.format("Weapon chest: %d weapon types, a shield, special arrows (F to open)", #weapons), 4)
end

local function spawnChest()
    local u, ctx, peer = caller()
    local p = u and feetOf(u)
    if not p then Log.Write("TestKit: !dag_chest: no character / position"); return end
    local C = cfg.chest
    local f, how = ahead(u, ctx)
    local x, y, z, valid = validNear(p[1] + f[1] * C.ahead_m, p[2], p[3] + f[3] * C.ahead_m, 2.0, u)
    local okC, chest = pcall(function() return Osi.CreateAt(C.template, x, y, z, 0, 1, "") end)
    if not okC or not chest or chest == "" then
        Log.Write("TestKit: chest CreateAt FAILED (" .. tostring(chest) .. ")")
        toast(peer, "Weapon chest: spawn failed (see the log)")
        return
    end
    chest = Party.Norm(chest)
    -- Its treasure table would roll random loot when first generated.
    local okT, errT = pcall(function() Ext.Entity.Get(chest).ServerItem.TreasureGenerated = true end)
    local flagHow = okT and "TreasureGenerated set" or ("TreasureGenerated not writable: " .. tostring(errT))
    Log.Write(string.format("TestKit: chest %s spawned %.1f m ahead (%s) at (%.1f, %.1f, %.1f)%s", chest, C.ahead_m, how, x, y, z,
        valid and "" or " (FindValidPosition failed, raw point)"))
    Ext.Timer.WaitFor(C.fill_delay_ms or 300, function()
        local ok, err = pcall(fillChest, chest, flagHow, peer)
        if not ok then Log.Write("TestKit: chest fill error " .. tostring(err)) end
    end)
end

-- ---------------------------------------------------------------------
-- !dag_goblins
-- ---------------------------------------------------------------------
local function saveSpawned()
    local lines = {}
    for g in pairs(spawned) do lines[#lines + 1] = g end
    pcall(Ext.IO.SaveFile, SPAWNED_PATH, table.concat(lines, "\n"))
end

local function removeChar(g)
    for _, fn in ipairs({ "SetOnStage", "SetHasDialog" }) do pcall(function() Osi[fn](g, 0) end) end
    pcall(function() Osi.RequestDeleteTemporary(g) end)
    pcall(function() Osi.RequestDelete(g) end)
end

local function clearGoblins(why)
    local n = 0
    for g in pairs(spawned) do removeChar(g); n = n + 1 end
    spawned = {}
    saveSpawned()
    Log.Write(string.format("TestKit: %d spawned goblin(s) removed (%s)", n, why))
    return n
end

local function removeLeftovers()
    local ok, s = pcall(Ext.IO.LoadFile, SPAWNED_PATH)
    if not ok or not s or s == "" then return end
    local n = 0
    for g in s:gmatch("[^\r\n]+") do removeChar(g); n = n + 1 end
    pcall(Ext.IO.SaveFile, SPAWNED_PATH, "")
    if n > 0 then Log.Write(string.format("TestKit: %d goblin(s) left from an earlier session removed (level start)", n)) end
end

local function resolveKind(a)
    local G = cfg.goblins
    if G.kinds[a] then return a end
    local s = a:gsub("s$", "")
    if G.kinds[s] then return s end
    return G.aliases[a] or G.aliases[s]
end

-- Brawl's precise merge into a running fight (Server/Brawl/Utils.lua joinCombat).
local function joinFight(g, combatGuid)
    if type(Utils) ~= "table" or type(Utils.joinCombat) ~= "function" then return false end
    local ok, r = pcall(Utils.joinCombat, g, combatGuid)
    return ok and r == true
end

local function makeHostile(g, host, idle, fightGuid)
    local G = cfg.goblins
    pcall(function() Osi.SetCanJoinCombat(g, 1) end)
    pcall(function() Osi.SetCanFight(g, 1) end)
    for _, pm in ipairs(Party.Members()) do
        pcall(function() Osi.SetRelationTemporaryHostile(g, pm) end)
        pcall(function() Osi.SetRelationTemporaryHostile(pm, g) end)
    end
    -- Not in a fight yet: the faction at once (nothing to split).
    if idle or not fightGuid then pcall(function() Osi.SetFaction(g, G.faction) end) end
    if idle then return "hostile, waits until it sees you" end
    if fightGuid and joinFight(g, fightGuid) then return "joins your fight" end
    pcall(function() Osi.EnterCombat(host, g) end)
    pcall(function() Osi.EnterCombat(g, host) end)
    return "EnterCombat"
end

-- In a running fight: the faction once they're all in it (or after merge_wait_s).
local function factionWhenMerged(guids, host)
    local G = cfg.goblins
    local deadline = now() + (G.merge_wait_s or 10) * 1000
    local function check()
        local hc = combatOf(host)
        local all = hc ~= nil
        for _, g in ipairs(guids) do if alive(g) and combatOf(g) ~= hc then all = false end end
        if not all and now() < deadline then Ext.Timer.WaitFor(500, check); return end
        local n = 0
        for _, g in ipairs(guids) do
            if alive(g) and pcall(function() Osi.SetFaction(g, G.faction) end) then n = n + 1 end
        end
        Log.Write(string.format("TestKit: Evil NPC faction on %d goblin(s) (%s)", n, all and "they joined your fight" or "timeout"))
    end
    Ext.Timer.WaitFor(500, check)
end

-- Anyone not in the fight a moment later is pulled in again.
local function ensureInCombat(guids, host, tries)
    local G = cfg.goblins
    Ext.Timer.WaitFor(math.floor((G.recheck_s or 2) * 1000), function()
        local out = {}
        for _, g in ipairs(guids) do
            local okC, inC = pcall(function() return Osi.IsInCombat(g) end)
            if alive(g) and not (okC and tonumber(inC) == 1) then out[#out + 1] = g end
        end
        if #out == 0 then
            Log.Write(string.format("TestKit: all %d goblin(s) are in the fight", #guids))
            return
        end
        for _, g in ipairs(out) do
            pcall(function() Osi.SetVisible(g, 1) end)
            makeHostile(g, host, false, combatOf(host))
        end
        Log.Write(string.format("TestKit: %d goblin(s) not in the fight yet, pulled in again (%d tries left)", #out, tries - 1))
        if tries > 1 then ensureInCombat(out, host, tries - 1) end
    end)
end

-- A goblin that can't walk to you (spawned in or behind a wall, playtest
-- 2026-10-12: the fight never ended) is moved near you, on the AI grid.
local function checkReach(guids, kinds, host)
    local G = cfg.goblins
    Ext.Timer.WaitFor(math.floor((G.reach_check_s or 3) * 1000), function()
        local Movement = DAG_BrawlModule and DAG_BrawlModule("Movement")
        local p = feetOf(host)
        if not Movement or not Movement.findPathToTargetUuid or not p then return end
        local moved, ok = {}, 0
        for i, g in ipairs(guids) do
            if alive(g) then
                local okP, reach = pcall(Movement.findPathToTargetUuid, g, host)
                if okP and reach == false then
                    local ranged = G.kinds[kinds[i]] and G.kinds[kinds[i]].row == "back"
                    local r = ranged and (G.relocate_ranged_m or 9) or (G.relocate_m or 4)
                    local a = (i - 1) * 2 * math.pi / math.max(1, #guids)
                    local x, y, z = validNear(p[1] + math.cos(a) * r, p[2], p[3] + math.sin(a) * r, 3, host)
                    pcall(function() Osi.TeleportToPosition(g, x, y, z, "", 0, 0, 0, 0, 0) end)
                    moved[#moved + 1] = string.format("%s (%s) -> %.0f m from you", g, tostring(kinds[i]), r)
                elseif okP then
                    ok = ok + 1
                end
            end
        end
        Log.Write(string.format("TestKit: %d goblin(s) can walk to you%s", ok,
            #moved > 0 and ("; no path, moved near you: " .. table.concat(moved, "; ")) or ""))
    end)
end

local function spawnGoblins(list, idle)
    local G = cfg.goblins
    local u, ctx, peer = caller()
    local p = u and feetOf(u)
    if not p then Log.Write("TestKit: !dag_goblins: no character / position"); return end
    local f, how = ahead(u, ctx)
    local right = { -f[3], 0, f[1] }
    local rows = { front = {}, back = {} }
    for _, k in ipairs(list) do
        local row = rows[G.kinds[k].row] or rows.front
        row[#row + 1] = k
    end
    local fightGuid = combatOf(u)
    local guids, lines, kindOf = {}, {}, {}
    for _, rowName in ipairs({ "front", "back" }) do
        local items = rows[rowName]
        local dist = rowName == "front" and G.front_m or G.back_m
        for j, k in ipairs(items) do
            local off = (j - (#items + 1) / 2) * G.spacing_m
            local x, y, z = validNear(p[1] + f[1] * dist + right[1] * off, p[2], p[3] + f[3] * dist + right[3] * off, 4, u)
            local okC, g = pcall(function() return Osi.CreateAt(G.kinds[k].template, x, y, z, 1, 1, "") end)
            if okC and g and g ~= "" then
                g = Party.Norm(g)
                spawned[g] = { kind = k, at = now() }
                guids[#guids + 1] = g
                kindOf[#guids] = k
                local hostile = makeHostile(g, u, idle, fightGuid)
                lines[#lines + 1] = string.format("%s %s (%s) at %.1f m: %s", k, g, G.kinds[k].note, dist, hostile)
            else
                lines[#lines + 1] = string.format("%s: CreateAt FAILED (%s)", k, tostring(g))
            end
        end
    end
    saveSpawned()
    Log.Write(string.format("TestKit: %d goblin(s) ahead of you (%s)%s:\n    %s", #guids, how, idle and ", idle" or "",
        table.concat(lines, "\n    ")))
    if #guids == 0 then toast(peer, "Goblins: spawn failed (see the log)"); return end
    if not idle then
        if fightGuid then factionWhenMerged(guids, u) end
        ensureInCombat(guids, u, G.recheck_tries or 2)
    end
    checkReach(guids, kindOf, u)
    local rt = ""
    if not idle and not Brawl.Enabled() then
        rt = " -- real time is OFF (!dag_rt on), so this fight is turn-based"
        Log.Write("TestKit: real-time fights are OFF (!dag_rt on): this fight will be BG3's turn-based")
    end
    toast(peer, string.format("Goblins: %s%s%s", table.concat(list, ", "), idle and " (idle)" or "", rt), 4)
end

local function goblins(args)
    local G = cfg.goblins
    local list, idle, unknown = {}, false, {}
    local i = 1
    while i <= #args do
        local a = tostring(args[i]):lower()
        if a == "clear" then
            local n = clearGoblins("!dag_goblins clear")
            toast(select(3, caller()), string.format("Goblins: %d removed", n))
            return
        elseif a == "list" then
            local names = {}
            for k, d in pairs(G.kinds) do names[#names + 1] = k .. " = " .. d.note end
            table.sort(names)
            Log.Write("TestKit: goblin kinds (!dag_goblins <kind> [count] ... [idle]):\n    " .. table.concat(names, "\n    "))
            return
        elseif a == "idle" or a == "calm" or a == "wait" then
            idle = true
        else
            local k = resolveKind(a)
            if k then
                local n = tonumber(args[i + 1])
                if n then i = i + 1 end
                for _ = 1, math.max(1, math.min(G.max, n or 1)) do list[#list + 1] = k end
            else
                unknown[#unknown + 1] = a
            end
        end
        i = i + 1
    end
    if #unknown > 0 then Log.Write("TestKit: unknown goblin kind(s) " .. table.concat(unknown, ", ") .. " (!dag_goblins list)") end
    if #list == 0 then for _, k in ipairs(G.squad) do list[#list + 1] = k end end
    while #list > G.max do table.remove(list) end
    spawnGoblins(list, idle)
end

-- ---------------------------------------------------------------------
-- !dag_god
-- ---------------------------------------------------------------------
local function setGod(u, on)
    local S = Damage.GOD_STATUS
    if on then
        return pcall(function() Osi.ApplyStatus(u, S, -1, 1, u) end)
    end
    local ok = pcall(function() Osi.RemoveStatus(u, S, u) end)
    if not ok then ok = pcall(function() Osi.RemoveStatus(u, S) end) end
    return ok
end

local function godReport(peer, what)
    Ext.Timer.WaitFor(300, function()
        local on = {}
        for _, m in ipairs(Party.Members()) do if Damage.Invincible(m) then on[#on + 1] = name(m) end end
        local text = #on > 0 and ("God mode ON: " .. table.concat(on, ", ")) or "God mode OFF"
        Log.Write(string.format("TestKit: !dag_god %s -> %s", what, text))
        toast(peer, text, 3)
    end)
end

local function god(arg)
    local u, _, peer = caller()
    arg = arg and tostring(arg):lower() or ""
    if arg == "status" then godReport(peer, "status"); return end
    if arg == "off" then
        for _, m in ipairs(Party.Members()) do if Damage.Invincible(m) then setGod(m, false) end end
    elseif arg == "party" or arg == "all" then
        for _, m in ipairs(Party.Members()) do setGod(m, true) end
    elseif not u then
        Log.Write("TestKit: !dag_god: no character")
        return
    elseif arg == "on" then
        setGod(u, true)
    else
        setGod(u, not Damage.Invincible(u))
    end
    godReport(peer, arg ~= "" and arg or "(toggle)")
end

local function learn(spell)
    local u, _, peer = caller()
    if not u or not spell or spell == "" then
        Log.Write("TestKit: !dag_learn <spell>: " .. (u and "no spell named" or "no character"))
        return
    end
    local ok, err = pcall(Osi.AddSpell, u, spell)
    local text = ok and ("Learned " .. spell) or ("Couldn't learn " .. spell .. ": " .. tostring(err))
    Log.Write(string.format("TestKit: !dag_learn %s -> %s (%s)", spell, ok and "ok" or tostring(err), name(u)))
    toast(peer, text, 3)
end

-- ---------------------------------------------------------------------
-- Register
-- ---------------------------------------------------------------------
function M.Register()
    ConsoleForward.Server("dag_chest", function() spawnChest() end)
    ConsoleForward.Server("dag_goblins", function(_, ...) goblins({ ... }) end)
    ConsoleForward.Server("dag_god", function(_, a) god(a) end)
    ConsoleForward.Server("dag_learn", function(_, a) learn(a) end)
    pcall(function()
        Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function()
            spawned = {}
            removeLeftovers()
        end)
    end)
    Ext.Events.GameStateChanged:Subscribe(function(e)
        local to = tostring(e.ToState)
        if to == "UnloadLevel" or to == "UnloadSession" then spawned = {} end
    end)
    Log.Write("TestKit: registered (!dag_chest, !dag_goblins [kind [n]...] [idle] | clear | list, !dag_god [on|off|party|status], !dag_learn <spell>)")
end

return M
