-- SPDX-License-Identifier: GPL-3.0-or-later
-- Real-time play: no reactions and no Sneak Attack (DECISIONS 2026-10-12,
-- docs/rework-list.md has a rework note for each). Two layers:
--
-- 1. Everyone in a real-time fight gets the hidden status DAG_NO_REACTIONS
--    (Public/DarkAndGate/Stats/Generated/Data/DAG_Combat.txt):
--      ActionResourceBlock(ReactionActionPoint)  BG3's own "can't take
--          reactions" lever (Shocking Grasp uses it). It covers every interrupt
--          that costs a reaction: opportunity attacks, Shield, Counterspell,
--          Hellish Rebuke, Riposte, Uncanny Dodge... NPCs included.
--      ActionResourceBlock(SneakAttack_Charge)   the Sneak Attack interrupt and
--          both Sneak Attack spells cost this charge.
--    Applied when a character enters a real-time fight (again after it left
--    and came back) and to everyone already fighting when real time is
--    switched on; removed when it leaves combat and on !dag_rt off.
--
-- 2. Interrupts that cost no reaction (Tides of Chaos, Divine Smite, Lucky,
--    Portent, Bardic Inspiration...) slip past the status, and an enemy's BG3
--    spell makes you roll (a saving throw, an attack roll against you), so
--    they still asked (playtest 2026-10-14: Tides of Chaos on a goblin's Acid
--    Splash, status on). So every interrupt is also switched off in BG3's own
--    reaction settings, the Reactions panel's switches (component
--    InterruptPreferences: interrupt -> flags Ask = 1 | Enabled = 2; 0 = off,
--    never used and never asked), as Brawl's summon "all off" mode does
--    (reference/Brawl Loadouts.applyAllReactionsTo):
--      party members (every player's)   the whole time real time is on, in
--          and out of fights (an opener that starts a fight can ask too);
--          data/combat.lua reactions.party_always = false: real-time fights only
--      everyone else in a real-time fight   while they fight
--    The original switches go into the save (mod variable ReactionPrefs:
--    uuid -> { interrupt -> flags, -1 = had no entry }) and come back on
--    !dag_rt off, when a fighter outside the party leaves the fight or dies,
--    and when a character leaves the party. Interrupts that turn up later (a
--    level up, an item, a status) are switched off on Osiris
--    ReactionInterruptAdded and by a guard every reactions.guard_s.
--    If BG3 asks anyway (ReactionInterruptActionNeeded) a "PROMPT" line is
--    logged and the switches are set again; an interrupt used in real-time
--    play is logged too.
--
-- At level start a sliced sweep removes leftover statuses from a save made
-- mid-fight, and settings saved for characters that no longer qualify are
-- put back.
--   !dag_reactions   (server console) every party member and saved
--                    character: its interrupts and their switches

local Log   = Ext.Require("Shared/Log.lua")
local Brawl = Ext.Require("Server/BrawlAdapter.lua")
local Party = Ext.Require("Server/Party.lua")
local TickBudget = Ext.Require("Shared/TickBudget.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")
local cfg   = Ext.Require("data/combat.lua")

local STATUS = "DAG_NO_REACTIONS"
local VAR    = "ReactionPrefs"   -- mod variable (saved): uuid -> { interrupt -> original flags }
local ABSENT = -1                -- the interrupt had no entry in the character's settings
local ASK, ENABLED = 1, 2        -- InterruptInteractionTypes (bg3se Enumerations/ECS.inl)
local LOG_NAMES = 12             -- interrupt names listed per log line
local USED_LOG_MS = 5000         -- one "used interrupt" line per character and interrupt this often

local R = cfg.reactions or {}

local M = {}

local applied = {}   -- uuid -> combat guid (or true): has the status from us
local sweep = nil    -- { handles, idx } while the level-start sweep runs
local dirty = {}     -- uuid -> why: re-check its switches next tick
local nextGuard = 0  -- ms
local usedAt = {}    -- uuid .. interrupt -> ms of the last "used" line

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function has(uuid)
    local ok, v = pcall(function() return Osi.HasActiveStatus(uuid, STATUS) end)
    return ok and tonumber(v) == 1
end

local function inCombat(uuid)
    local ok, v = pcall(function() return Osi.IsInCombat(uuid) end)
    return ok and tonumber(v) == 1
end

local function partyAlways() return R.party_always ~= false end

-- A party member's switches stay off between fights while real time is on.
local function keepForParty(uuid)
    return Brawl.Enabled() and partyAlways() and Party.IsMember(uuid)
end

-- Should this character's interrupts be off right now?
local function wantOff(uuid)
    if not Brawl.Enabled() then return false end
    if keepForParty(uuid) then return true end
    return applied[uuid] ~= nil or inCombat(uuid)
end

-- ---------------------------------------------------------------------
-- BG3's reaction switches (InterruptPreferences)
-- ---------------------------------------------------------------------
local function flagsOf(v)
    if type(v) == "number" then return math.tointeger(v) or v end
    local ok, n = pcall(function() return v.__Value end)
    if ok and tonumber(n) then return math.tointeger(tonumber(n)) or tonumber(n) end
    local s, f = tostring(v), 0   -- "InterruptInteractionTypes(Ask,Enabled)"
    if s:find("Ask") then f = f | ASK end
    if s:find("Enabled") then f = f | ENABLED end
    return f
end

local function describe(f)
    f = math.tointeger(f) or f
    if f == ABSENT then return "no entry" end
    if f == 0 then return "off" end
    return ((f & ENABLED) ~= 0 and "on" or "off") .. ((f & ASK) ~= 0 and "+ask" or "")
end

local function loadStore()
    local ok, v = pcall(function() return Ext.Vars.GetModVariables(ModuleUUID)[VAR] end)
    return (ok and type(v) == "table") and v or {}
end

local function saveStore(t)
    local ok, err = pcall(function() Ext.Vars.GetModVariables(ModuleUUID)[VAR] = t end)
    if not ok then Log.Write("NoReactions: saving the original reaction switches FAILED: " .. tostring(err)) end
end

local function prefsOf(uuid)
    local ok, ent = pcall(Ext.Entity.Get, uuid)
    if not ok or not ent then return nil end
    local okP, prefs = pcall(function() return ent.InterruptPreferences and ent.InterruptPreferences.Preferences end)
    if not okP or not prefs then return nil end
    return prefs, ent
end

-- Every interrupt the character has: its switches plus its interrupt
-- container (an interrupt can have no switch yet). name -> flags or ABSENT.
local function interruptsOf(ent, prefs)
    local list, nPrefs, nCont = {}, 0, 0
    pcall(function()
        for k, v in pairs(prefs) do list[tostring(k)] = flagsOf(v); nPrefs = nPrefs + 1 end
    end)
    pcall(function()
        for _, ie in pairs(ent.InterruptContainer.Interrupts) do
            local okN, n = pcall(function() return ie.InterruptData.Interrupt end)
            if okN and n and tostring(n) ~= "" then
                nCont = nCont + 1
                n = tostring(n)
                if list[n] == nil then list[n] = ABSENT end
            end
        end
    end)
    return list, nPrefs, nCont
end

local function replicate(ent)
    pcall(function() ent:Replicate("InterruptPreferences") end)
end

local function nameList(names)
    local shown = {}
    for i = 1, math.min(#names, LOG_NAMES) do shown[i] = names[i] end
    return table.concat(shown, ", ") .. (#names > LOG_NAMES and string.format(" (+%d more)", #names - LOG_NAMES) or "")
end

-- Switches every interrupt of uuid off. The first time an interrupt is
-- switched off, its original flags go into the saved store.
local function switchOff(uuid, why)
    local prefs, ent = prefsOf(uuid)
    if not prefs then return 0 end
    local list, nPrefs, nCont = interruptsOf(ent, prefs)
    local todo = {}
    for n, f in pairs(list) do if f ~= 0 then todo[#todo + 1] = n end end
    if #todo == 0 then return 0 end
    table.sort(todo)
    local store = loadStore()
    local snap = store[uuid] or {}
    local done, failed = {}, {}
    for _, n in ipairs(todo) do
        local ok = pcall(function() prefs[n] = 0 end)
        if ok then
            if snap[n] == nil then snap[n] = list[n] end
            done[#done + 1] = string.format("%s (was %s)", n, describe(list[n]))
        else
            failed[#failed + 1] = n
        end
    end
    if #done > 0 then
        store[uuid] = snap
        saveStore(store)
        replicate(ent)
    end
    Log.Write(string.format("NoReactions: %s -> %d interrupt(s) switched off (%s): %s [switches %d, container %d]%s",
        Brawl.Name(uuid), #done, why, nameList(done), nPrefs, nCont,
        #failed > 0 and (" ERROR could not switch off " .. table.concat(failed, ", ")) or ""))
    return #done
end

-- Puts the original switches back (nothing saved for uuid: nothing to do).
local function restore(uuid, why)
    local store = loadStore()
    local snap = store[uuid]
    if not snap then return end
    store[uuid] = nil
    saveStore(store)
    local prefs, ent = prefsOf(uuid)
    if not prefs then
        Log.Write(string.format("NoReactions: %s -> saved reaction switches dropped, no settings to put them in (%s)", Brawl.Name(uuid), why))
        return
    end
    local n, failed = 0, {}
    for name, f in pairs(snap) do
        f = math.tointeger(f) or f
        local ok = pcall(function()
            if f == ABSENT then prefs[name] = nil else prefs[name] = f end
        end)
        if ok then n = n + 1 else failed[#failed + 1] = tostring(name) end
    end
    replicate(ent)
    Log.Write(string.format("NoReactions: %s -> %d interrupt(s) back to their own switches (%s)%s", Brawl.Name(uuid), n, why,
        #failed > 0 and (" ERROR " .. table.concat(failed, ", ")) or ""))
end

local function restoreAll(why)
    local list = {}
    for uuid in pairs(loadStore()) do list[#list + 1] = uuid end
    for _, uuid in ipairs(list) do restore(uuid, why) end
    return #list
end

-- ---------------------------------------------------------------------
-- The status
-- ---------------------------------------------------------------------
local function apply(uuid, combat, why)
    uuid = Party.Norm(uuid)
    if not uuid then return end
    if not applied[uuid] then
        local ok, err = pcall(function() Osi.ApplyStatus(uuid, STATUS, -1, 1, uuid) end)
        if ok then applied[uuid] = combat or true end
        Log.Write(string.format("NoReactions: %s -> reactions and Sneak Attack blocked (%s)%s", Brawl.Name(uuid), why,
            ok and "" or (" ERROR " .. tostring(err))))
    end
    switchOff(uuid, why)
end

local function remove(uuid, why)
    uuid = Party.Norm(uuid)
    if not uuid then return end
    local was = applied[uuid]
    applied[uuid] = nil
    if was or has(uuid) then
        local ok, err = pcall(function() Osi.RemoveStatus(uuid, STATUS, uuid) end)
        if not ok then ok, err = pcall(function() Osi.RemoveStatus(uuid, STATUS) end) end
        Log.Write(string.format("NoReactions: %s -> reactions back (%s)%s", Brawl.Name(uuid), why, ok and "" or (" ERROR " .. tostring(err))))
    end
    if not keepForParty(uuid) then restore(uuid, why) end
end

function M.Applied() return applied end

local function applyToFight(why)
    local n = 0
    for uuid in pairs(Roster.getBrawlers() or {}) do
        if inCombat(uuid) then apply(uuid, true, why); n = n + 1 end
    end
    return n
end

local function sweepTick()
    if not sweep then return end
    local last = math.min(#sweep.handles, sweep.idx + 59)
    for i = sweep.idx, last do
        local e = sweep.handles[i]
        local okU, u = pcall(function() return tostring(e.Uuid.EntityUuid) end)
        if okU and u and has(u) then
            if Brawl.Enabled() and inCombat(u) then
                applied[u] = applied[u] or true   -- still fighting: removed when it leaves combat
            else
                sweep.removed = sweep.removed + 1
                remove(u, "left over from a save made mid-fight")
            end
        end
    end
    sweep.idx = last + 1
    if sweep.idx > #sweep.handles then
        Log.Write(string.format("NoReactions: level-start sweep done (%d characters checked, %d leftovers removed)", #sweep.handles, sweep.removed))
        sweep = nil
    end
end

-- ---------------------------------------------------------------------
-- Per tick: the sweep, re-checks, the party guard
-- ---------------------------------------------------------------------
local function tick()
    if sweep then sweepTick() end
    if next(dirty) then
        local list = dirty
        dirty = {}
        for uuid, why in pairs(list) do
            if wantOff(uuid) then switchOff(uuid, why) end
        end
    end
    local t = now()
    if t < nextGuard then return end
    nextGuard = t + (tonumber(R.guard_s) or 1.0) * 1000
    if not Brawl.Enabled() or Party.InCharacterCreation() then return end
    local store = loadStore()
    for _, uuid in ipairs(Party.Members()) do
        if partyAlways() or applied[uuid] then
            switchOff(uuid, store[uuid] and "turned up again (level up, item, status...)"
                or (partyAlways() and "party member, real time on" or "joined a real-time fight"))
        end
    end
end

local function report()
    local store = loadStore()
    local seen, list = {}, {}
    for _, u in ipairs(Party.Members()) do if not seen[u] then seen[u] = true; list[#list + 1] = u end end
    for u in pairs(store) do if not seen[u] then seen[u] = true; list[#list + 1] = u end end
    Log.Write(string.format("NoReactions: real time %s, party switches off %s; %d character(s) listed (party + saved switches)",
        Brawl.Enabled() and "ON" or "OFF", partyAlways() and "whenever real time is on" or "in real-time fights", #list))
    for _, u in ipairs(list) do
        local prefs, ent = prefsOf(u)
        local parts = {}
        if prefs then
            local ints = interruptsOf(ent, prefs)
            local names = {}
            for n in pairs(ints) do names[#names + 1] = n end
            table.sort(names)
            for _, n in ipairs(names) do
                local orig = store[u] and store[u][n]
                parts[#parts + 1] = n .. " " .. describe(ints[n]) .. (orig and (" (own: " .. describe(orig) .. ")") or "")
            end
        end
        Log.Write(string.format("  %s (%s)%s%s%s: %s", Brawl.Name(u), u, Party.IsMember(u) and " party" or "",
            has(u) and ", status on" or "", inCombat(u) and ", in combat" or "",
            prefs and (#parts > 0 and table.concat(parts, "; ") or "no interrupts") or "no reaction settings"))
    end
end

local function listen(event, arity, fn)
    local ok, err = pcall(Ext.Osiris.RegisterListener, event, arity, "after", function(...)
        local okF, errF = pcall(fn, ...)
        if not okF then Log.Write("NoReactions: " .. event .. " handler failed: " .. tostring(errF)) end
    end)
    if not ok then Log.Write("NoReactions: could not listen to " .. event .. ": " .. tostring(err)) end
end

function M.Register()
    local okV, errV = pcall(Ext.Vars.RegisterModVariable, ModuleUUID, VAR, { Server = true, Client = false, SyncToClient = false })
    if not okV then Log.Write("NoReactions: mod variable " .. VAR .. " not registered: " .. tostring(errV)) end

    -- Straight from Osiris, not Brawl's hook: that one fires once per
    -- character per fight, so a fighter who left combat and came back
    -- (Wyll, 2026-10-14) stayed unblocked.
    listen("EnteredCombat", 2, function(obj, combat)
        if Brawl.Enabled() then apply(obj, combat, "joined a real-time fight") end
    end)
    Brawl.Hook("Enabled", function()
        local n = applyToFight("real time switched on mid-fight")
        nextGuard = 0
        Log.Write(string.format("NoReactions: real time on, %d fighters blocked", n))
    end)
    Brawl.Hook("Disabling", function()
        local list = {}
        for uuid in pairs(applied) do list[#list + 1] = uuid end
        for _, uuid in ipairs(list) do remove(uuid, "!dag_rt off: vanilla turn-based rules") end
        local n = restoreAll("!dag_rt off: vanilla turn-based rules")
        Log.Write(string.format("NoReactions: real time off, %d character(s) got their reaction switches back", n))
    end)
    Brawl.Hook("CombatEnded", function(combat)
        local list = {}
        for uuid, c in pairs(applied) do
            if c == combat or not inCombat(uuid) then list[#list + 1] = uuid end
        end
        for _, uuid in ipairs(list) do remove(uuid, "fight over") end
    end)
    listen("LeftCombat", 2, function(obj)
        local uuid = Party.Norm(obj)
        if uuid and (applied[uuid] or loadStore()[uuid]) then remove(uuid, "left combat") end
    end)
    listen("Died", 1, function(obj)
        local uuid = Party.Norm(obj)
        if not uuid then return end
        applied[uuid] = nil
        if not Party.IsMember(uuid) then restore(uuid, "died") end
    end)
    listen("CharacterJoinedParty", 1, function(obj)
        local uuid = Party.Norm(obj)
        if uuid and Brawl.Enabled() and partyAlways() then
            dirty[uuid] = "joined the party"
            nextGuard = 0
        end
    end)
    listen("CharacterLeftParty", 1, function(obj)
        local uuid = Party.Norm(obj)
        if uuid and not (Brawl.Enabled() and (applied[uuid] or inCombat(uuid))) then restore(uuid, "left the party") end
    end)
    -- An interrupt added to a character whose switches are off (BG3 gives
    -- a new one its default: on, ask).
    listen("ReactionInterruptAdded", 2, function(obj)
        local uuid = Party.Norm(obj)
        if uuid and Brawl.Enabled() and (applied[uuid] or Party.IsMember(uuid)) then
            dirty[uuid] = dirty[uuid] or "interrupt added"
        end
    end)
    -- BG3 is about to show a reaction prompt: shouldn't happen any more.
    listen("ReactionInterruptActionNeeded", 1, function(obj)
        local uuid = Party.Norm(obj)
        if not uuid then return end
        local on = {}
        local prefs, ent = prefsOf(uuid)
        if prefs then
            for n, f in pairs(interruptsOf(ent, prefs)) do if f ~= 0 then on[#on + 1] = n .. " " .. describe(f) end end
            table.sort(on)
        end
        Log.Write(string.format("NoReactions: PROMPT for %s: BG3 asks about an interrupt (real time %s, status %s, switches %s; still on: %s)",
            Brawl.Name(uuid), Brawl.Enabled() and "on" or "off", has(uuid) and "on" or "off",
            loadStore()[uuid] and "saved" or "not saved", #on > 0 and nameList(on) or "none"))
        if Brawl.Enabled() then dirty[uuid] = "BG3 asked anyway" end
    end)
    listen("ReactionInterruptUsed", 3, function(obj, interrupt, auto)
        local uuid = Party.Norm(obj)
        if not uuid or not Brawl.Enabled() or not (applied[uuid] or Party.IsMember(uuid)) then return end
        local key, t = uuid .. tostring(interrupt), now()
        if t - (usedAt[key] or -1e12) < USED_LOG_MS then return end
        usedAt[key] = t
        Log.Write(string.format("NoReactions: %s used interrupt %s in real-time play (%s)", Brawl.Name(uuid), tostring(interrupt),
            tonumber(auto) == 1 and "automatic" or "asked"))
    end)
    listen("LevelGameplayStarted", 2, function()
        local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerCharacter")
        sweep = { handles = (ok and ents) or {}, idx = 1, removed = 0 }
        -- Switches saved for characters that no longer qualify (a save made
        -- mid-fight, real time switched off since).
        local store, back, kept = loadStore(), 0, 0
        local list = {}
        for uuid in pairs(store) do list[#list + 1] = uuid end
        for _, uuid in ipairs(list) do
            if wantOff(uuid) then kept = kept + 1 else restore(uuid, "left over from a save"); back = back + 1 end
        end
        if #list > 0 then
            Log.Write(string.format("NoReactions: level start: %d character(s) with saved reaction switches, %d put back, %d kept off", #list, back, kept))
        end
        nextGuard = 0
    end)
    Ext.Events.Tick:Subscribe(TickBudget.Wrap("NoReactions", tick, 2.0))
    ConsoleForward.Server("dag_reactions", function() report() end)
    Log.Write(string.format("NoReactions: registered (status %s on every real-time fighter; BG3's reaction switches off for %s and every real-time fighter, guard every %.1f s; !dag_reactions in the server console)",
        STATUS, partyAlways() and "party members while real time is on" or "party members in real-time fights", tonumber(R.guard_s) or 1.0))
end

return M
