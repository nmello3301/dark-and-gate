-- SPDX-License-Identifier: GPL-3.0-or-later
-- Meta-Points, server side (Shared/MetaPoints.lua has the storage and the
-- curves; docs/DESIGN.md "Meta-Points").
--
-- The server owns the points. Clients ask:
--   MetaQuery   { uuid? }            -> MetaState for that character (with
--                                       whether it is in camp), or with no
--                                       uuid the config + every party member
--   MetaConfirm { uuid, spent }      the menu's Confirm: every stat >= what is
--                                    spent already, <= max_per_stat, the total
--                                    within the points available
--   MetaRespec  { uuid }             "Reset all points" (respec_mode: camp =
--                                    the character or you in camp)
-- and hear:
--   MetaConfig  { config }           the host's effective config
--   MetaState   { uuid, name, level, spent, bonus, total, unspent, inCamp,
--                 respec, owner }    after every change, level-up and query
--   MetaNotify  { uuid, name, unspent, level }   a level-up brought points
-- Only the player a character is reserved for (or who controls it) may
-- spend its points.
--
-- Console (server, also typed in the client console):
--   !dag_meta_grant <n>          n bonus points for the character you control
--   !dag_meta_set <STAT> <n>     set a stat (bonus points added if needed)
--   !dag_meta_reset              refund everything (debug: ignores respec_mode)
--   !dag_meta_print              every effective value for the character you control
--   !dag_meta_selftest           the curve self-test
--   !dag_meta_reload             re-read metapoints.json and send it to everyone
--   !dag_meta_xp <n>             n experience for the character you control (to test
--                                level-ups; Osi.AddExplorationExperience, SE docs)

local Log            = Ext.Require("Shared/Log.lua")
local Net            = Ext.Require("Shared/Net.lua")
local Party          = Ext.Require("Server/Party.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")
local MetaPoints     = Ext.Require("Shared/MetaPoints.lua")
local Mana           = Ext.Require("Server/Combat/Mana.lua")

local M = {}

local loadLogged = {}    -- uuid -> true once its points were logged this session
local listeners = {}     -- fn(uuid) after a character's points changed

local function cfg() return MetaPoints.Config() end

local function name(uuid)
    local ok, n = pcall(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(uuid)) end)
    return (ok and n and n ~= "") and n or tostring(uuid)
end

local function level(uuid)
    local ok, l = pcall(function() return Osi.GetLevel(uuid) end)
    return math.max(1, tonumber(ok and l) or 1)
end

local function send(user, channel, t)
    pcall(function() Ext.Net.PostMessageToUser(user, channel, Ext.Json.Stringify(t)) end)
end
local function broadcast(channel, t)
    pcall(function() Ext.Net.BroadcastMessage(channel, Ext.Json.Stringify(t)) end)
end

-- Osiris user id -> net user id (SE v33: net id = peer << 16, Osiris = | 1).
local function netUserOf(osiUser)
    osiUser = tonumber(osiUser)
    if not osiUser then return nil end
    return (osiUser >> 16) << 16
end

function M.OnChange(fn) listeners[#listeners + 1] = fn end

-- ---------------------------------------------------------------------
-- Camp and respec
-- ---------------------------------------------------------------------
local function inCamp(uuid)
    if not uuid then return false, "nobody" end
    local yes, how = false, nil
    pcall(function()
        for _, row in pairs(Osi.DB_InCamp:Get(nil) or {}) do
            if Party.Norm(row[1]) == uuid then yes, how = true, "DB_InCamp" end
        end
    end)
    if not yes then
        pcall(function() if Ext.Entity.Get(uuid).CampPresence ~= nil then yes, how = true, "CampPresence" end end)
    end
    return yes, how or "not in camp"
end

-- Reset all points allowed for `uuid` (requested by the player controlling
-- `by`)? -> ok, reason
local function respecAllowed(uuid, by)
    local mode = tostring(cfg().respec_mode or "camp")
    if mode == "off" then return false, "respec is off (respec_mode)" end
    if mode == "anywhere" then return true, "anywhere" end
    local c1, how1 = inCamp(uuid)
    if c1 then return true, "in camp (" .. how1 .. ")" end
    if by and by ~= uuid then
        local c2, how2 = inCamp(by)
        if c2 then return true, "you are in camp (" .. how2 .. ")" end
    end
    return false, "only in camp"
end

-- ---------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------
local function stateOf(uuid, by)
    local rec = MetaPoints.Record(uuid) or {}
    local lvl = level(uuid)
    local spent = {}
    for _, s in ipairs(cfg().stats) do spent[s] = MetaPoints.Points(rec, s) end
    local total = MetaPoints.Total(lvl, rec)
    local camp = inCamp(uuid)
    local okR, why = respecAllowed(uuid, by)
    return { uuid = uuid, name = name(uuid), level = lvl, spent = spent, bonus = math.max(0, tonumber(rec.bonus) or 0),
             total = total, unspent = total - MetaPoints.SpentTotal(rec), inCamp = camp, respec = okR, respecWhy = why,
             owner = Party.UserOf(uuid) }
end
M.StateOf = stateOf

local function push(uuid, toUser, by)
    local st = stateOf(uuid, by)
    if toUser then send(toUser, Net.Channels.MetaState, st) else broadcast(Net.Channels.MetaState, st) end
    return st
end

local function pushAll(toUser)
    for _, u in ipairs(Party.Members()) do push(u, toUser) end
end

local function write(uuid, spent, bonus)
    local clean = {}
    for _, s in ipairs(cfg().stats) do clean[s] = math.max(0, math.floor(tonumber(spent and spent[s]) or 0)) end
    local rec = { v = 1, spent = clean, bonus = math.max(0, math.floor(tonumber(bonus) or 0)) }
    local ok, err = pcall(function() Ext.Entity.Get(uuid).Vars[MetaPoints.VAR] = rec end)
    if not ok then Log.Write(string.format("MetaPoints: writing %s's points FAILED: %s", name(uuid), tostring(err))) end
    return ok
end

local function spentText(spent)
    local parts = {}
    for _, s in ipairs(cfg().stats) do parts[#parts + 1] = string.format("%s %d", s, tonumber(spent and spent[s]) or 0) end
    return table.concat(parts, ", ")
end

local function changed(uuid, why)
    local st = push(uuid)
    pcall(Mana.OnCharacterChanged, uuid)
    for _, fn in ipairs(listeners) do pcall(fn, uuid) end
    Log.Write(string.format("MetaPoints: %s (%s): %s | level %d, %d points, %d unspent", name(uuid), why, spentText(st.spent),
        st.level, st.total, st.unspent))
end

-- ---------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------
local function canEdit(peer, uuid)
    if not uuid or not Party.IsMember(uuid) then return false, "not a party member" end
    if Party.CharacterOfPeer(peer) == uuid then return true end
    local owner = Party.UserOf(uuid)
    if owner and owner == Party.UserFromPeer(peer) then return true end
    return false, "that character is another player's"
end

local function toast(peer, text)
    send(peer, Net.Channels.Toast, { text = text, secs = 3.5 })
end

local function onConfirm(peer, p)
    local uuid = Party.Norm(p.uuid)
    local ok, why = canEdit(peer, uuid)
    if not ok then
        Log.Write(string.format("MetaPoints: confirm from user %s for %s REFUSED (%s)", tostring(peer), tostring(uuid), why))
        toast(peer, "Meta-Points: " .. why)
        return
    end
    local rec = MetaPoints.Record(uuid) or {}
    local maxPer = tonumber(cfg().max_per_stat) or 96
    local new, sum = {}, 0
    for _, s in ipairs(cfg().stats) do
        local old = MetaPoints.Points(rec, s)
        local n = math.floor(tonumber(type(p.spent) == "table" and p.spent[s]) or old)
        if n < old then
            Log.Write(string.format("MetaPoints: confirm for %s REFUSED (%s %d is below the %d already confirmed; use Reset all points)", name(uuid), s, n, old))
            toast(peer, "Meta-Points: confirmed points can only be refunded with Reset all points")
            push(uuid, peer)
            return
        end
        if n > maxPer then n = maxPer end
        new[s] = n
        sum = sum + n
    end
    local total = MetaPoints.Total(level(uuid), rec)
    if sum > total then
        Log.Write(string.format("MetaPoints: confirm for %s REFUSED (%d points asked, %d available)", name(uuid), sum, total))
        toast(peer, string.format("Meta-Points: only %d points available", total))
        push(uuid, peer)
        return
    end
    if write(uuid, new, rec.bonus) then changed(uuid, "confirmed") end
end

local function onRespec(peer, p, force)
    local uuid = Party.Norm(p.uuid)
    local ok, why = canEdit(peer, uuid)
    if not ok and not force then
        toast(peer, "Meta-Points: " .. why)
        return
    end
    if not force then
        local okR, whyR = respecAllowed(uuid, Party.CharacterOfPeer(peer))
        if not okR then
            Log.Write(string.format("MetaPoints: reset of %s REFUSED (%s)", name(uuid), whyR))
            toast(peer, "Meta-Points: Reset all points works " .. (whyR == "only in camp" and "only in camp" or ("never (" .. whyR .. ")")))
            push(uuid, peer)
            return
        end
    end
    local rec = MetaPoints.Record(uuid) or {}
    if write(uuid, {}, rec.bonus) then changed(uuid, force and "reset (debug)" or "reset all points") end
end

-- ---------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------
local function sendConfig(toUser)
    local t = { config = MetaPoints.Config() }
    if toUser then send(toUser, Net.Channels.MetaConfig, t) else broadcast(Net.Channels.MetaConfig, t) end
end

function M.ReloadConfig(why)
    local file, err = MetaPoints.ReadFile()
    local notes = {}
    if not file then
        if err == "missing" then
            local okW = MetaPoints.WriteDefaultsFile()
            Log.Write("MetaPoints: no " .. MetaPoints.FILE .. " yet -> the defaults" .. (okW and " (written there to edit)" or " (could not write it)"))
        else
            Log.Write("MetaPoints: " .. MetaPoints.FILE .. " " .. err .. " -> the defaults (the file is left as it is)")
        end
        MetaPoints.SetConfig(MetaPoints.Defaults())
    else
        local merged
        merged, notes = MetaPoints.Merge(MetaPoints.Defaults(), file)
        MetaPoints.SetConfig(merged)
        for _, n in ipairs(notes) do Log.Write("MetaPoints: " .. MetaPoints.FILE .. ": " .. n) end
    end
    local c = cfg()
    Log.Write(string.format("MetaPoints: config (%s): %d per level, max %d per stat, respec %s, min action interval %.3f s, enemy HP x%.2f damage x%.2f, spell damage hook %s",
        why or "load", tonumber(c.points_per_level) or 0, tonumber(c.max_per_stat) or 0, tostring(c.respec_mode),
        MetaPoints.MinInterval(), tonumber(c.enemy_hp_mult) or 1, tonumber(c.enemy_damage_mult) or 1, tostring(c.spell_damage_hook)))
    sendConfig(nil)
end

-- ---------------------------------------------------------------------
-- Debug
-- ---------------------------------------------------------------------
local function callerCharacter()
    local c = ConsoleForward.Caller()
    if c and c.peer then return Party.CharacterOfPeer(c.peer), c.peer end
    return Party.Controlled(Party.HostUser()), nil
end

-- Every effective value for `uuid` (server side), one line each.
function M.Describe(uuid)
    local lines = {}
    local st = stateOf(uuid)
    lines[#lines + 1] = string.format("%s level %d: %d points, %d spent, %d unspent (bonus %d) | %s | respec %s (%s)",
        st.name, st.level, st.total, st.total - st.unspent, st.unspent, st.bonus, spentText(st.spent),
        st.respec and "allowed" or "refused", tostring(st.respecWhy))
    for _, e in ipairs(cfg().effects) do
        local v = MetaPoints.Value(uuid, e.id) or 0
        lines[#lines + 1] = string.format("  %-15s %s %3d -> %s%s", e.id, e.stat, st.spent[e.stat] or 0,
            e.kind == "fraction" and string.format("%.1f %%", v * 100) or string.format("x%.3f", v),
            e.controlled_only and "  (only while a player controls it)" or "")
    end
    return lines
end

local function registerDebug()
    ConsoleForward.Server("dag_meta_grant", function(_, n)
        local uuid = callerCharacter()
        if not uuid then return end
        local rec = MetaPoints.Record(uuid) or {}
        local add = math.floor(tonumber(n) or 0)
        if write(uuid, rec.spent or {}, (tonumber(rec.bonus) or 0) + add) then changed(uuid, string.format("debug: %+d points", add)) end
    end)
    ConsoleForward.Server("dag_meta_set", function(_, stat, n)
        local uuid = callerCharacter()
        if not uuid then return end
        stat = tostring(stat or ""):upper()
        local known = false
        for _, s in ipairs(cfg().stats) do if s == stat then known = true end end
        if not known then Log.Write("MetaPoints: !dag_meta_set <" .. table.concat(cfg().stats, "|") .. "> <points>"); return end
        local rec = MetaPoints.Record(uuid) or {}
        local spent = {}
        for _, s in ipairs(cfg().stats) do spent[s] = MetaPoints.Points(rec, s) end
        spent[stat] = math.max(0, math.min(tonumber(cfg().max_per_stat) or 96, math.floor(tonumber(n) or 0)))
        local sum = 0
        for _, s in ipairs(cfg().stats) do sum = sum + spent[s] end
        local bonus = math.max(0, tonumber(rec.bonus) or 0)
        local total = MetaPoints.Total(level(uuid), { bonus = bonus })
        if sum > total then bonus = bonus + (sum - total) end
        if write(uuid, spent, bonus) then changed(uuid, string.format("debug: %s = %d", stat, spent[stat])) end
    end)
    ConsoleForward.Server("dag_meta_reset", function()
        local uuid, peer = callerCharacter()
        if uuid then onRespec(peer, { uuid = uuid }, true) end
    end)
    ConsoleForward.Server("dag_meta_print", function()
        local uuid = callerCharacter()
        if not uuid then Log.Write("MetaPoints: no character"); return end
        Log.Write("MetaPoints: server values for " .. name(uuid) .. ":")
        for _, l in ipairs(M.Describe(uuid)) do Log.Write("MetaPoints:   " .. l) end
        for _, fn in ipairs(M.describers or {}) do
            local ok, more = pcall(fn, uuid)
            if ok and type(more) == "table" then for _, l in ipairs(more) do Log.Write("MetaPoints:   " .. l) end end
        end
    end)
    ConsoleForward.Server("dag_meta_selftest", function() MetaPoints.SelfTest(true) end)
    ConsoleForward.Server("dag_meta_xp", function(_, n)
        local uuid = callerCharacter()
        if not uuid then return end
        local amount = math.floor(tonumber(n) or 1000)
        local ok, err = pcall(function() Osi.AddExplorationExperience(uuid, amount) end)
        Log.Write(string.format("MetaPoints: %d experience for %s%s", amount, name(uuid), ok and " (level up in BG3's level-up screen)" or (" FAILED: " .. tostring(err))))
    end)
    ConsoleForward.Server("dag_meta_reload", function()
        M.ReloadConfig("!dag_meta_reload")
        pushAll(nil)
    end)
end

-- Other modules add their own lines to !dag_meta_print (cast time, mana...).
function M.AddDescriber(fn)
    M.describers = M.describers or {}
    M.describers[#M.describers + 1] = fn
end

-- ---------------------------------------------------------------------
-- Register
-- ---------------------------------------------------------------------
local function logLoaded()
    for _, u in ipairs(Party.Members()) do
        if not loadLogged[u] then
            loadLogged[u] = true
            local st = stateOf(u)
            local saved = MetaPoints.Record(u) ~= nil
            Log.Write(string.format("MetaPoints: %s level %d -> %d points, %d spent, %d to spend (%s)", st.name, st.level, st.total,
                st.total - st.unspent, st.unspent, saved and "saved points found" or "nothing saved yet: all from the level"))
        end
    end
end

function M.Register()
    M.ReloadConfig("load")
    MetaPoints.SelfTest(true)
    registerDebug()

    Ext.RegisterNetListener(Net.Channels.MetaQuery, function(_, payload, peer)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" then p = {} end
        Ext.OnNextTick(function()
            if p.uuid then
                local u = Party.Norm(p.uuid)
                if u and Party.IsMember(u) then push(u, peer, Party.CharacterOfPeer(peer)) end
            else
                sendConfig(peer)
                logLoaded()
                pushAll(peer)
            end
        end)
    end)
    Ext.RegisterNetListener(Net.Channels.MetaConfirm, function(_, payload, peer)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" then return end
        Ext.OnNextTick(function()
            local okC, err = pcall(onConfirm, peer, p)
            if not okC then Log.Write("MetaPoints: confirm error " .. tostring(err)) end
        end)
    end)
    Ext.RegisterNetListener(Net.Channels.MetaRespec, function(_, payload, peer)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" then return end
        Ext.OnNextTick(function()
            local okR, err = pcall(onRespec, peer, p, false)
            if not okR then Log.Write("MetaPoints: reset error " .. tostring(err)) end
        end)
    end)

    Ext.Osiris.RegisterListener("LeveledUp", 1, "after", function(char)
        local uuid = Party.Norm(char)
        if not uuid or not Party.IsMember(uuid) then return end
        local st = push(uuid)
        pcall(Mana.OnCharacterChanged, uuid)
        Log.Write(string.format("MetaPoints: %s reached level %d -> %d points, %d to spend", st.name, st.level, st.total, st.unspent))
        if st.unspent > 0 and cfg().notify_level_up ~= false then
            local note = { uuid = uuid, name = st.name, unspent = st.unspent, level = st.level }
            local user = netUserOf(Party.UserOf(uuid))
            if user then send(user, Net.Channels.MetaNotify, note) else broadcast(Net.Channels.MetaNotify, note) end
        end
    end)
    -- A new level (or a load): log everyone's points once more.
    Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function()
        loadLogged = {}
        Ext.OnNextTick(function() pcall(logLoaded); pcall(pushAll, nil) end)
    end)
    Log.Write("MetaPoints: registered (server)")
end

return M
