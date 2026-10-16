-- SPDX-License-Identifier: GPL-3.0-or-later
-- RPG Mode (DECISIONS 2026-10-15, docs/DESIGN.md "RPG Mode", data/rpgmode.lua):
-- optional, player-controlled respawning of cleared fights.
--
--   Recording  An encounter is one whole fight (combat start to end, one flag
--              per fight). Every HOSTILE character that enters it (late joiners
--              too; no party members, allies, neutrals, summons or props) is
--              recorded as it ENTERS: template, level, faction, combat group,
--              position, rotation, and its items (equipped and carried, again
--              right after it dies, when BG3 has generated its loot).
--   Cleared    The fight ends with every recorded hostile dead. Ended any
--              other way (fleeing, dialogue, distance end): nothing.
--              Story / global / unique characters are left out unless
--              respawn_unique_enemies; nothing left = no flag.
--   Flag       A BG3 banner where the last hostile died (snapped to walkable
--              ground), OFF. F toggles it (Server/Combat/Interact.lua).
--   Respawn    Flag ON + no party member within respawn_radius of the centre
--              + respawn_min_delay seconds of play since ON: fresh copies at the
--              start positions and rotations, same faction / group, dialogue
--              off, carrying new copies of the originals' items (no new loot
--              roll). The flag goes. Clearing the copies = a new flag, OFF.
--              The originals are never revived; copies have new ids, so the
--              story's quest scripts (keyed by the originals) never see them.
-- Saved per save in the mod variable RpgEncounters. Only encounters in the
-- region the host is in are looked at; others sit dormant.
--
-- Console: !dag_rpg_list, !dag_rpg_respawn <id>, !dag_rpg_delete <id>,
-- !dag_rpg_flag_templates, !dag_rpg_reload.

local Log            = Ext.Require("Shared/Log.lua")
local Net            = Ext.Require("Shared/Net.lua")
local Party          = Ext.Require("Server/Party.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")
local defaults       = Ext.Require("data/rpgmode.lua")

local M = {}

local VAR = "RpgEncounters"
local FILE = "DarkAndGate/rpgmode.json"
local SLOTS = { "Helmet", "Breast", "Cloak", "Melee Main Weapon", "Melee Offhand Weapon", "Ranged Main Weapon",
                "Ranged Offhand Weapon", "Ring", "Ring2", "Underwear", "Boots", "Gloves", "Amulet", "MusicalInstrument",
                "VanityBody", "VanityBoots" }

local cfg = {}
local store = nil          -- { seq, list = { [id] = encounter } } (the mod variable)
local flagIndex = {}       -- flag uuid -> encounter id
local copyIndex = {}       -- copy uuid -> encounter id
local fight = nil          -- the fight being recorded: { members = { uuid -> rec }, copies = { encId -> true }, lastDeath }
local pendingEnd = nil     -- { at = ms } a fight ended: decide once it settled
local lastTick, dirtyAt = 0, nil
local flagTemplates = nil  -- { off, on } once picked

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local function uuidOf(s) s = tostring(s or ""); return s:match("(%x+%-%x+%-%x+%-%x+%-%x+)$") or (s ~= "" and s or nil) end
local function q(fn, ...) local ok, v = pcall(Osi[fn], ...); return ok and v or nil end
local function name(u)
    local ok, n = pcall(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(u)) end)
    return (ok and n and n ~= "") and n or tostring(u)
end
local function host() return Party.Norm(q("GetHostCharacter")) end
local function region() local h = host(); return h and q("GetRegion", h) or nil end
local function posOf(u)
    local ok, x, y, z = pcall(function() return Osi.GetPosition(u) end)
    if ok and tonumber(x) then return { tonumber(x), tonumber(y), tonumber(z) } end
    return nil
end
local function dist(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
local function fmt(p) return p and string.format("(%.1f,%.1f,%.1f)", p[1], p[2], p[3]) or "?" end

-- ---------------------------------------------------------------------
-- Config and storage
-- ---------------------------------------------------------------------
local function loadConfig(why)
    cfg = {}
    for k, v in pairs(defaults) do cfg[k] = v end
    local ok, s = pcall(Ext.IO.LoadFile, FILE)
    if ok and s and s ~= "" then
        local okJ, t = pcall(Ext.Json.Parse, s)
        if okJ and type(t) == "table" then
            for k, v in pairs(t) do if type(k) == "string" and k:sub(1, 1) ~= "_" then cfg[k] = v end end
        else
            Log.Write("RpgMode: " .. FILE .. " is not valid JSON -> the defaults")
        end
    end
    Log.Write(string.format("RpgMode: config (%s): %s, radius %.0f m, delay %.0f s, unique enemies %s", why, cfg.rpg_mode_enabled and "ON" or "OFF",
        tonumber(cfg.respawn_radius) or 0, tonumber(cfg.respawn_min_delay) or 0, cfg.respawn_unique_enemies and "respawn" or "stay dead"))
end

local function load()
    local t = nil
    pcall(function() t = Ext.Vars.GetModVariables(ModuleUUID)[VAR] end)
    if type(t) ~= "table" or type(t.list) ~= "table" then t = { seq = 0, list = {} } end
    store = t
    flagIndex, copyIndex = {}, {}
    for id, e in pairs(store.list) do
        if e.flag and e.flag.uuid then flagIndex[e.flag.uuid] = id end
        for _, c in ipairs(e.copies or {}) do copyIndex[c] = id end
    end
end

local function save()
    dirtyAt = nil
    pcall(function() Ext.Vars.GetModVariables(ModuleUUID)[VAR] = store end)
end

local function enc(id) if not store then load() end; return store.list[tostring(id)] end

-- ---------------------------------------------------------------------
-- Who counts, what is recorded
-- ---------------------------------------------------------------------
local function hostile(u)
    if not u or Party.IsMember(u) or q("IsCharacter", u) ~= 1 then return false end
    if q("IsSummon", u) == 1 then return false end
    local summon = false
    pcall(function() summon = Ext.Entity.Get(u).ServerCharacter.Summon == true end)
    if summon then return false end
    local h = host()
    if not h or q("IsAlly", h, u) == 1 then return false end
    return q("IsEnemy", u, h) == 1
end

local function unique(u, tplName)
    local yes, why = false, nil
    pcall(function()
        local sc = Ext.Entity.Get(u).ServerCharacter
        if sc.StoryNPC then yes, why = true, "story NPC" elseif sc.Global then yes, why = true, "global" end
    end)
    if not yes and tostring(tplName or ""):lower():sub(1, 2) == "s_" then yes, why = true, "story template" end
    return yes, why
end

-- Items carried (equipped ones flagged): { { template, amount, equipped } }.
local function itemsOf(u)
    local equipped = {}
    for _, s in ipairs(SLOTS) do
        local it = uuidOf(q("GetEquippedItem", u, s))
        if it then equipped[it] = true end
    end
    local out = {}
    pcall(function()
        for _, inv in ipairs(Ext.Entity.Get(u).InventoryOwner.Inventories) do
            for _, slot in ipairs(inv.InventoryContainer.Items) do
                local it = uuidOf(slot.Item.Uuid.EntityUuid)
                local tpl = it and uuidOf(q("GetTemplate", it))
                if tpl then
                    out[#out + 1] = { template = tpl, amount = math.max(1, tonumber(q("GetStackAmount", it)) or 1), equipped = equipped[it] == true }
                end
            end
        end
    end)
    return out
end

local function rootOf(tplId)
    local id, guard = tplId, 0
    while id and guard < 8 do
        guard = guard + 1
        local okR, r = pcall(Ext.Template.GetRootTemplate, id)
        if okR and r then return id end
        local okT, t = pcall(Ext.Template.GetTemplate, id)
        if not okT or not t then return nil end
        local p = tostring(t.ParentTemplateId or "")
        if p == "" or p == id then return nil end
        id = p
    end
    return nil
end

local function snapshot(u)
    local tplFull = q("GetTemplate", u)
    local tpl = uuidOf(tplFull)
    local tplName = tostring(tplFull or ""):match("^(.-)_%x+%-") or ""
    local rec = { uuid = u, name = name(u), template = tpl, root = tpl and rootOf(tpl) or nil, level = tonumber(q("GetLevel", u)),
                  faction = q("GetFaction", u), pos = posOf(u), items = itemsOf(u) }
    pcall(function() rec.group = tostring(Ext.Entity.Get(u).ServerCharacter.Template.CombatComponent.CombatGroupID or "") end)
    local okR, rx, ry, rz = pcall(function() return Osi.GetRotation(u) end)
    if okR and tonumber(rx) then rec.rot = { tonumber(rx), tonumber(ry), tonumber(rz) } end
    pcall(function() local qt = Ext.Entity.Get(u).Transform.Transform.RotationQuat; rec.quat = { qt[1], qt[2], qt[3], qt[4] } end)
    rec.unique, rec.uniqueWhy = unique(u, tplName)
    return rec
end

-- ---------------------------------------------------------------------
-- The flag
-- ---------------------------------------------------------------------
local function pickFlagTemplates()
    if flagTemplates then return flagTemplates end
    local off, on = cfg.flag_template, cfg.flag_template_on
    local found = {}
    if not off then
        pcall(function()
            for id, t in pairs(Ext.Template.GetAllRootTemplates()) do
                local ty = ""
                pcall(function() ty = tostring(t.TemplateType or t:GetTemplateType()) end)
                local n = tostring(t.Name or ""):lower()
                if ty:lower() == "item" then
                    local hit = false
                    for _, p in ipairs(cfg.flag_name_patterns or {}) do if n:find(p, 1, true) then hit = true end end
                    for _, x in ipairs(cfg.flag_name_exclude or {}) do if n:find(x, 1, true) then hit = false end end
                    if hit then found[#found + 1] = { id = tostring(id), name = tostring(t.Name) } end
                end
            end
        end)
        table.sort(found, function(a, b) return #a.name < #b.name or (#a.name == #b.name and a.name < b.name) end)
        off = found[1] and found[1].id or nil
    end
    flagTemplates = { off = off, on = on or off, candidates = found }
    Log.Write(string.format("RpgMode: flag template %s (%d banner candidates; !dag_rpg_flag_templates; pin it in rpgmode.json flag_template)",
        tostring(off) .. (found[1] and (" " .. found[1].name) or ""), #found))
    return flagTemplates
end

local function snap(p)
    local h = host()
    local ok, x, y, z = pcall(function() return Osi.FindValidPosition(p[1], p[2], p[3], 8, h, 1) end)
    if ok and tonumber(x) then return { tonumber(x), tonumber(y), tonumber(z) } end
    return p
end

local function spawnFlag(e, at, on)
    local t = pickFlagTemplates()
    local tpl = on and t.on or t.off
    if not tpl then Log.Write("RpgMode: no flag template found -> encounter " .. e.id .. " has no flag (set flag_template)"); return end
    local p = snap(at)
    local ok, f = pcall(function() return Osi.CreateAt(tpl, p[1], p[2], p[3], 0, 1, "") end)
    f = ok and uuidOf(f) or nil
    if not f then Log.Write("RpgMode: flag spawn FAILED for encounter " .. e.id); return end
    if e.flag and e.flag.uuid then flagIndex[e.flag.uuid] = nil end
    e.flag = e.flag or {}
    e.flag.uuid, e.flag.pos, e.flag.on = f, p, on == true
    flagIndex[f] = e.id
    Log.Write(string.format("RpgMode: flag %s for encounter %s at %s (%s, snapped from %s)", f, e.id, fmt(p), on and "ON" or "OFF", fmt(at)))
end

local function removeFlag(e)
    if e.flag and e.flag.uuid then
        flagIndex[e.flag.uuid] = nil
        pcall(Osi.RequestDelete, e.flag.uuid)
    end
    e.flag = nil
end

local function toast(player, text)
    local u = Party.UserOf(player)
    local net = u and ((u >> 16) << 16) or nil
    local msg = Ext.Json.Stringify({ text = text, secs = 4 })
    pcall(function() if net then Ext.Net.PostMessageToUser(net, Net.Channels.Toast, msg) else Ext.Net.BroadcastMessage(Net.Channels.Toast, msg) end end)
end

-- Interact.lua: is this a flag, and toggle it.
function M.IsFlag(item) return flagIndex[Party.Norm(item) or ""] ~= nil end
function M.FlagName(item)
    local e = enc(flagIndex[Party.Norm(item) or ""] or "")
    return e and string.format("RPG Mode flag (%s)", e.flag and e.flag.on and "ON" or "OFF") or "RPG Mode flag"
end
function M.Toggle(item, player)
    local e = enc(flagIndex[Party.Norm(item) or ""] or "")
    if not e or not e.flag then return false, "not a flag" end
    local on = not e.flag.on
    e.flag.onElapsed = 0
    local t = pickFlagTemplates()
    if t.on ~= t.off then
        local at = e.flag.pos
        removeFlag(e)
        spawnFlag(e, at, on)
        e.flag.onElapsed = 0
    end
    if e.flag then e.flag.on = on end
    save()
    local text = on and "RPG Mode: ON — this camp will return when you leave" or "RPG Mode: OFF — this camp stays cleared"
    if on and not cfg.rpg_mode_enabled then text = text .. " (RPG Mode is off in rpgmode.json)" end
    toast(player, text)
    Log.Write(string.format("RpgMode: flag of encounter %s switched %s by %s", e.id, on and "ON" or "OFF", name(player)))
    return true, "RPG Mode flag " .. (on and "ON" or "OFF")
end

-- ---------------------------------------------------------------------
-- Fights
-- ---------------------------------------------------------------------
local function onEntered(u)
    u = Party.Norm(u)
    if not u or not cfg.rpg_mode_enabled then return end
    fight = fight or { members = {}, copies = {}, order = {} }
    local copyOf = copyIndex[u]
    if copyOf then
        if not fight.copies[copyOf] then
            fight.copies[copyOf] = true
            -- The rest of that camp comes too (their combat group may not have survived the copy).
            local e = enc(copyOf)
            for _, c in ipairs(e and e.copies or {}) do
                if c ~= u and q("IsDead", c) ~= 1 and q("IsInCombat", c) ~= 1 then pcall(Osi.EnterCombat, c, host()) end
            end
        end
        return
    end
    if fight.members[u] or not hostile(u) then return end
    local ok, rec = pcall(snapshot, u)
    if ok and rec then
        fight.members[u] = rec
        fight.order[#fight.order + 1] = u
    end
end

local function onDied(u)
    u = Party.Norm(u)
    if not fight or not u then return end
    if fight.members[u] or copyIndex[u] then
        fight.lastDeath = posOf(u) or fight.lastDeath
        local rec = fight.members[u]
        if rec then
            -- BG3 generates a corpse's loot around the death: read the items again.
            Ext.Timer.WaitFor(600, function()
                local okI, items = pcall(itemsOf, u)
                if okI and #items > #(rec.items or {}) then rec.items = items end
            end)
        end
    end
end

local function newEncounter(members)
    store.seq = (store.seq or 0) + 1
    local id = tostring(store.seq)
    local c, n = { 0, 0, 0 }, 0
    for _, m in ipairs(members) do
        if m.pos then c = { c[1] + m.pos[1], c[2] + m.pos[2], c[3] + m.pos[3] }; n = n + 1 end
    end
    local e = { id = id, region = region(), members = members, center = n > 0 and { c[1] / n, c[2] / n, c[3] / n } or nil,
                state = "cleared", copies = {} }
    store.list[id] = e
    return e
end

local function decide()
    local f = fight
    fight, pendingEnd = nil, nil
    if not store then load() end
    if not f then return end
    -- Copies of earlier encounters: all dead = cleared again, a new flag (OFF).
    for id in pairs(f.copies) do
        local e = enc(id)
        if e and e.state == "respawned" then
            local alive = 0
            for _, c in ipairs(e.copies) do if q("IsDead", c) ~= 1 then alive = alive + 1 end end
            if alive == 0 then
                for _, c in ipairs(e.copies) do copyIndex[c] = nil end
                e.copies, e.state = {}, "cleared"
                if cfg.rpg_mode_enabled and f.lastDeath then spawnFlag(e, f.lastDeath, false) end
                Log.Write(string.format("RpgMode: encounter %s cleared again -> a new flag (OFF)", id))
            end
        end
    end
    -- New hostiles: cleared only if every one is dead.
    local list, alive, kept, skipped = {}, {}, {}, {}
    for _, u in ipairs(f.order) do
        local rec = f.members[u]
        if q("IsDead", u) ~= 1 then alive[#alive + 1] = rec.name
        elseif rec.unique and not cfg.respawn_unique_enemies then skipped[#skipped + 1] = rec.name .. " (" .. tostring(rec.uniqueWhy) .. ")"
        else kept[#kept + 1] = rec end
        list[#list + 1] = rec.name
    end
    if #list == 0 then save(); return end
    if #alive > 0 then
        Log.Write(string.format("RpgMode: fight over, NOT cleared (%d of %d enemies alive: %s) -> no flag", #alive, #list, table.concat(alive, ", ")))
    elseif #kept == 0 then
        Log.Write(string.format("RpgMode: fight cleared, but nobody to bring back (left out: %s) -> no flag", table.concat(skipped, ", ")))
    elseif not cfg.rpg_mode_enabled then
        Log.Write("RpgMode: fight cleared; RPG Mode is off -> no flag")
    else
        for _, rec in ipairs(kept) do rec.uuid = nil end
        local e = newEncounter(kept)
        Log.Write(string.format("RpgMode: encounter %s recorded: %d enemies (%s)%s, centre %s", e.id, #kept, table.concat(list, ", "),
            #skipped > 0 and (", left out: " .. table.concat(skipped, ", ")) or "", fmt(e.center)))
        if f.lastDeath then spawnFlag(e, f.lastDeath, false) end
    end
    save()
end

-- ---------------------------------------------------------------------
-- Respawn
-- ---------------------------------------------------------------------
local function callFirst(fn, variants)
    for _, args in ipairs(variants) do
        local ok = pcall(function() return Osi[fn](table.unpack(args)) end)
        if ok then return true, #args end
    end
    return false
end

local function setupCopy(c, m, report)
    if m.faction then pcall(Osi.SetFaction, c, m.faction) end
    pcall(Osi.SetHasDialog, c, 0)
    if m.group and m.group ~= "" then report.group = callFirst("SetCombatGroupID", { { c, m.group } }) and "ok" or "unavailable" end
    if m.rot and m.pos then
        report.rot = callFirst("ToTransform", { { c, m.pos[1], m.pos[2], m.pos[3], m.rot[1], m.rot[2], m.rot[3] } }) and "ToTransform" or "none"
    end
    local lvl = tonumber(q("GetLevel", c))
    if m.level and lvl and lvl ~= m.level then report.levels = (report.levels or 0) + 1 end
    -- Its own generated items out, no new loot roll, the originals' items in.
    pcall(function() Ext.Entity.Get(c).ServerCharacter.Treasures = {} end)
    pcall(function()
        for _, inv in ipairs(Ext.Entity.Get(c).InventoryOwner.Inventories) do
            for _, slot in ipairs(inv.InventoryContainer.Items) do pcall(Osi.RequestDelete, slot.Item.Uuid.EntityUuid) end
        end
    end)
    Ext.Timer.WaitFor(200, function()
        for _, it in ipairs(m.items or {}) do
            local okC, item = pcall(function() return Osi.CreateAt(it.template, m.pos[1], m.pos[2], m.pos[3], 0, 0, "") end)
            item = okC and uuidOf(item) or nil
            if item then
                pcall(Osi.ToInventory, item, c, it.amount or 1, 0, 0)
                if it.equipped then callFirst("Equip", { { c, item }, { c, item, 1 }, { c, item, 1, 0 }, { c, item, 1, 0, 0 } }) end
            end
        end
    end)
end

local function respawn(e, why)
    local copies, report = {}, { group = "-", rot = "-" }
    for _, m in ipairs(e.members) do
        local p = m.pos
        if p then
            local c = nil
            for _, tpl in ipairs({ m.template, m.root }) do
                if tpl and not c then
                    local ok, r = pcall(function() return Osi.CreateAt(tpl, p[1], p[2], p[3], 0, 0, "") end)
                    c = ok and uuidOf(r) or nil
                    if c and tpl ~= m.template then report.root = (report.root or 0) + 1 end
                end
            end
            if c then
                copies[#copies + 1] = c
                copyIndex[c] = e.id
                Ext.Timer.WaitFor(300, function() pcall(setupCopy, c, m, report) end)
            else
                Log.Write(string.format("RpgMode: copy of %s (template %s) could not be spawned", tostring(m.name), tostring(m.template)))
            end
        end
    end
    removeFlag(e)
    e.copies, e.state = copies, "respawned"
    save()
    Ext.Timer.WaitFor(1500, function()
        Log.Write(string.format("RpgMode: encounter %s RESPAWNED (%s): %d of %d enemies back; root-template fallback %d, combat group %s, rotation %s, level differences %d",
            e.id, why, #copies, #e.members, report.root or 0, tostring(report.group), tostring(report.rot), report.levels or 0))
    end)
end

local function eligible(e, members)
    if e.state ~= "cleared" or not e.flag or not e.flag.on then return false, "flag off" end
    if not cfg.rpg_mode_enabled then return false, "RPG Mode off" end
    if e.region ~= region() then return false, "another region" end
    local left = (tonumber(cfg.respawn_min_delay) or 60) - (e.flag.onElapsed or 0)
    if left > 0 then return false, string.format("%.0f s to wait", left) end
    local r = tonumber(cfg.respawn_radius) or 100
    for _, u in ipairs(members) do
        local d = dist(posOf(u), e.center)
        if d < r then return false, string.format("%s is %.0f m away (< %.0f)", name(u), d, r) end
    end
    return true, "eligible"
end

local function tick()
    local t = now()
    if pendingEnd and t >= pendingEnd.at then
        local h = host()
        if h and q("IsInCombat", h) == 1 then pendingEnd.at = t + 1000 else pcall(decide) end
    end
    local step = (tonumber(cfg.check_s) or 2) * 1000
    if t - lastTick < step then return end
    local dt = lastTick > 0 and (t - lastTick) / 1000 or 0
    lastTick = t
    if Party.InCharacterCreation() then return end
    if not store then pcall(load); if not store then return end end
    local members = Party.Members()
    for _, e in pairs(store.list) do
        if e.flag and e.flag.on and e.state == "cleared" and e.region == region() then
            e.flag.onElapsed = (e.flag.onElapsed or 0) + dt
            dirtyAt = dirtyAt or t
            local ok = eligible(e, members)
            if ok then respawn(e, "flag ON, party away") end
        end
    end
    if dirtyAt and t - dirtyAt > 10000 then save() end
end

-- ---------------------------------------------------------------------
-- Debug
-- ---------------------------------------------------------------------
local function list()
    if not store then load() end
    local members, n = Party.Members(), 0
    local ids = {}
    for id in pairs(store.list) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
    for _, id in ipairs(ids) do
        local e = store.list[id]
        n = n + 1
        local near = math.huge
        for _, u in ipairs(members) do near = math.min(near, dist(posOf(u), e.center)) end
        local _, why = eligible(e, members)
        Log.Write(string.format("RpgMode: #%s %s, %d enemies, state %s, flag %s, party %s m from the centre, region %s: %s", id,
            e.members[1] and e.members[1].name or "?", #e.members, e.state, e.flag and (e.flag.on and "ON" or "OFF") or "none",
            near < math.huge and string.format("%.0f", near) or "?", tostring(e.region), why))
    end
    Log.Write(string.format("RpgMode: %d encounters recorded (RPG Mode %s)", n, cfg.rpg_mode_enabled and "ON" or "OFF"))
end

function M.Register()
    loadConfig("load")
    pcall(Ext.Vars.RegisterModVariable, ModuleUUID, VAR, { Server = true, Client = false, SyncToClient = false })
    Ext.Osiris.RegisterListener("EnteredCombat", 2, "after", function(u) pcall(onEntered, u) end)
    Ext.Osiris.RegisterListener("Died", 1, "after", function(u) pcall(onDied, u) end)
    Ext.Osiris.RegisterListener("CombatEnded", 1, "after", function()
        if fight then pendingEnd = { at = now() + (tonumber(cfg.end_settle_s) or 2) * 1000 } end
    end)
    Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function() load(); fight, pendingEnd = nil, nil end)
    Ext.Events.Tick:Subscribe(function() local ok, err = pcall(tick); if not ok then Log.Write("RpgMode: tick error " .. tostring(err)) end end)
    ConsoleForward.Server("dag_rpg_list", function() list() end)
    ConsoleForward.Server("dag_rpg_respawn", function(_, id)
        local e = enc(id or "")
        if not e then Log.Write("RpgMode: no encounter " .. tostring(id)); return end
        respawn(e, "forced by !dag_rpg_respawn")
    end)
    ConsoleForward.Server("dag_rpg_delete", function(_, id)
        local e = enc(id or "")
        if not e then Log.Write("RpgMode: no encounter " .. tostring(id)); return end
        removeFlag(e)
        for _, c in ipairs(e.copies or {}) do copyIndex[c] = nil end
        store.list[tostring(id)] = nil
        save()
        Log.Write("RpgMode: encounter " .. tostring(id) .. " deleted (its flag removed; living copies stay)")
    end)
    ConsoleForward.Server("dag_rpg_flag_templates", function()
        local t = pickFlagTemplates()
        for i, c in ipairs(t.candidates or {}) do if i <= 25 then Log.Write(string.format("RpgMode: banner %d: %s %s", i, c.id, c.name)) end end
        Log.Write("RpgMode: flag OFF " .. tostring(t.off) .. ", ON " .. tostring(t.on))
    end)
    ConsoleForward.Server("dag_rpg_reload", function() loadConfig("!dag_rpg_reload"); flagTemplates = nil end)
    Log.Write("RpgMode: registered")
end

return M
