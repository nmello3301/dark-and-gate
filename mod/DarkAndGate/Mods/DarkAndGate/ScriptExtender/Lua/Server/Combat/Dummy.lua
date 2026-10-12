-- SPDX-License-Identifier: GPL-3.0-or-later
-- Spawn a training dummy / goblin in front of the user. Used by
-- !dag_spawn_dummy for safe hit tests before the goblin fight.
--
-- Templates are looked up by name at runtime via Ext.Template so we don't
-- ship a hard-coded UUID that might not exist in this install's data.
-- Preference order: anything with "TrainingDummy" / "Dummy" in the name,
-- then anything that looks like an Act 1 goblin ("GOB_", "Goblin"). The
-- chosen template name + UUID is logged on both server AND client (via
-- DAG_SpawnDummyReply) so a client.log paste shows the result.

local Log       = Ext.Require("Shared/Log.lua")
local Net       = Ext.Require("Shared/Net.lua")
local ServerNet = Ext.Require("Server/Net.lua")

local M = {}

-- !dag_spawn_dummy moving: dummies walking back and forth (data/projectiles.lua).
local pdata = Ext.Require("data/projectiles.lua")
local patrols = {}   -- uuid -> { a = {x,y,z}, b = {x,y,z}, goal = "a"|"b", issuedAt = ms }
local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function moveTo(uuid, p)
    local md = pdata.moving_dummy or {}
    local ok, err = pcall(function()
        Osi.CharacterMoveToPosition(uuid, p[1], p[2], p[3], md.movement or "Walk", "DAG_DummyPatrol")
    end)
    return ok, err
end

local patrolCheckAt = -1e9
local function patrolTick()
    local t = nowMs()
    local md = pdata.moving_dummy or {}
    if t - patrolCheckAt < (md.repath_s or 0.5) * 1000 then return end
    patrolCheckAt = t
    for uuid, pt in pairs(patrols) do
        local okE, e = pcall(Ext.Entity.Get, uuid)
        local pos = nil
        if okE and e then pcall(function() local tr = e.Transform.Transform.Translate; pos = { tr[1], tr[2], tr[3] } end) end
        if not pos then
            patrols[uuid] = nil
        else
            local g = pt[pt.goal]
            local dx, dz = pos[1] - g[1], pos[3] - g[3]
            local arrived = dx * dx + dz * dz <= (md.arrive_m or 0.6) ^ 2
            if arrived then pt.goal = (pt.goal == "a") and "b" or "a" end
            if arrived or t - pt.issuedAt > 4000 then
                pt.issuedAt = t
                local ok, err = moveTo(uuid, pt[pt.goal])
                if not pt.logged then
                    pt.logged = true
                    Log.Write(string.format("Dummy: patrol %s -> %s %s", uuid, pt.goal, ok and "CharacterMoveToPosition ok" or ("ERROR " .. tostring(err))))
                end
            end
        end
    end
end

-- Ranked name patterns. First-match wins within each tier; tiers are
-- scanned in order. "Combat_Dummy" / "Training_Dummy" character templates
-- first (NOT the DEC_ scenery ones — those have no HP and clicks pass
-- through them), then any goblin from Act 1.
local TIERS = {
    { tag = "training",    patterns = { "training_dummy", "trainingdummy", "combat_dummy", "combatdummy" } },
    { tag = "act1-goblin", patterns = { "^gob_", "goblin" } },
    { tag = "any-dummy",   patterns = { "dummy" } },
}

-- Scenery name prefixes to exclude outright. DEC_ in particular bit us —
-- "DEC_GEN_Training_Dummy_C" is a scenery decoration that renders as a
-- training dummy but takes no damage and clicks pass through it.
local SCENERY_PREFIXES = { "dec_", "scn_", "wpn_", "arm_", "obj_", "door_", "trap_", "item_", "lgt_", "fx_" }

-- Return template type if the SE binding exposes it, else nil. Checked
-- in order: method call, direct field. "character" is what we want.
local function templateTypeOf(tpl)
    local okM, t = pcall(function() return tpl:GetTemplateType() end)
    if okM and t and tostring(t) ~= "" then return tostring(t) end
    local okF, t2 = pcall(function() return tpl.TemplateType end)
    if okF and t2 and tostring(t2) ~= "" then return tostring(t2) end
    return nil
end

-- Primary filter: real character templates. Falls back to name-prefix
-- blocklist + Stats-field heuristic when GetTemplateType is unavailable.
local function isCharacter(tpl, nameLower)
    for _, p in ipairs(SCENERY_PREFIXES) do
        if nameLower:sub(1, #p) == p then return false end
    end
    local t = templateTypeOf(tpl)
    if t then
        return t == "character" or t == "Character"
    end
    local okS, s = pcall(function() return tpl.Stats end)
    return okS and s and s ~= ""
end

-- Collect templates, grouped by tier. Returns:
--   choice   = { uuid, name, tier, type } | nil
--   topList  = up to 10 { uuid, name, type } candidates when no match is
--              found, so the user can see what's actually available.
-- Score an (already lower-cased) template name as a test goblin.
-- nil = never pick it.
local EXCLUDE = { "child", "kid", "young", "baby", "cine", "festiv", "corpse", "dead", "cutscene",
                  "prisoner", "captive", "statue", "portrait", "illusion", "dream", "polymorph",
                  "wildshape", "summon", "_tut", "origin", "hireling", "player", "puppet", "zombie",
                  "_dummy_root", "cameo", "ghost", "spirit", "_sleep", "_drunk", "_party" }
local function goblinScore(n)
    if not (n:find("goblin", 1, true) or n:find("^gob_")) then return nil end
    for _, x in ipairs(EXCLUDE) do
        if n:find(x, 1, true) then return nil end
    end
    local sc = 0
    if n:find("^goblins?_") then sc = sc + 10 end
    if n:find("^gob_") then sc = sc + 6 end
    if n:find("hobgoblin", 1, true) then sc = sc - 3 end
    for _, w in ipairs({ "warrior", "melee", "fighter", "brute", "grunt", "raider", "soldier", "sentry", "guard" }) do
        if n:find(w, 1, true) then sc = sc + 4; break end
    end
    for _, w in ipairs({ "ranged", "archer", "caster", "shaman", "priest" }) do
        if n:find(w, 1, true) then sc = sc + 1; break end
    end
    return sc
end

local function findDummyTemplate(filter)
    if not (Ext.Template and Ext.Template.GetAllRootTemplates) then
        return nil, {}, "Ext.Template.GetAllRootTemplates unavailable"
    end
    local okT, templates = pcall(Ext.Template.GetAllRootTemplates)
    if not okT or not templates then
        return nil, {}, "GetAllRootTemplates threw: " .. tostring(templates)
    end

    local pool = {}
    local scannedCount, charCount = 0, 0
    for uuid, tpl in pairs(templates) do
        scannedCount = scannedCount + 1
        local okN, n = pcall(function() return tpl.Name end)
        if okN and n and n ~= "" then
            local nameLower = tostring(n):lower()
            if isCharacter(tpl, nameLower) then
                charCount = charCount + 1
                pool[#pool + 1] = {
                    uuid = tostring(uuid),
                    name = tostring(n),
                    type = templateTypeOf(tpl) or "character?",
                    low  = nameLower,
                }
            end
        end
    end
    Log.Write(string.format(
        "Dummy: scanned %d templates, %d matched character filter",
        scannedCount, charCount))

    -- fix2: deterministic, scored choice. pairs() over the template map
    -- has no stable order, so "first match wins" picked a different
    -- goblin every run (a child goblin last time). Adult combat goblins
    -- score highest; children / cinematic / dead / captive variants are
    -- excluded outright.
    local filterLow = filter and filter ~= "" and filter:lower() or nil
    local ranked = {}
    for _, cand in ipairs(pool) do
        local sc
        if filterLow then
            sc = cand.low:find(filterLow, 1, true) and 1 or nil
        else
            sc = goblinScore(cand.low)
        end
        if sc then
            ranked[#ranked + 1] = { c = cand, s = sc }
        end
    end
    table.sort(ranked, function(a, b)
        if a.s ~= b.s then return a.s > b.s end
        if #a.c.name ~= #b.c.name then return #a.c.name < #b.c.name end
        return a.c.name < b.c.name
    end)
    local top = {}
    for i = 1, math.min(25, #ranked) do
        top[i] = { uuid = ranked[i].c.uuid, name = ranked[i].c.name, type = ranked[i].c.type, score = ranked[i].s }
    end
    if #ranked > 0 then
        local c = ranked[1].c
        return { uuid = c.uuid, name = c.name, tier = filterLow and "filter" or "adult-goblin", type = c.type }, top, nil
    end
    return nil, top, filterLow and ("no character template name contains '" .. filter .. "'")
                              or "no adult goblin template found"
end

local function sendReply(userId, payload)
    pcall(function()
        Ext.Net.PostMessageToUser(userId, Net.Channels.SpawnDummyReply,
            Ext.Json.Stringify(payload))
    end)
end

-- Read a character's world position. Round-2 build hit "position lookup
-- failed" on Osi.GetX/Y/Z — these may not be available in this SE build
-- or need Osi-safe context we're not quite in. Fall back to Ext.Entity's
-- Transform the same way FullPov.lua does on the client; works on both
-- states. Returns {x,y,z} or nil + error string.
local function readPos(uuid)
    local errors = {}
    -- 1. Try Osi.GetPosition (multi-return).
    local okP, px, py, pz = pcall(function() return Osi.GetPosition(uuid) end)
    if okP and tonumber(px) and tonumber(py) and tonumber(pz) then
        return { x = tonumber(px), y = tonumber(py), z = tonumber(pz) }, nil
    else
        errors[#errors+1] = "Osi.GetPosition err=" .. tostring(px)
    end
    -- 2. Try individual Osi.GetX/Y/Z.
    local okX, gx = pcall(function() return Osi.GetX(uuid) end)
    local okY, gy = pcall(function() return Osi.GetY(uuid) end)
    local okZ, gz = pcall(function() return Osi.GetZ(uuid) end)
    if okX and okY and okZ and tonumber(gx) and tonumber(gy) and tonumber(gz) then
        return { x = tonumber(gx), y = tonumber(gy), z = tonumber(gz) }, nil
    end
    errors[#errors+1] = string.format("Osi.GetX/Y/Z okX=%s okY=%s okZ=%s", tostring(okX), tostring(okY), tostring(okZ))
    -- 3. Ext.Entity.Get(uuid).Transform.Transform.Translate (same shape FullPov uses).
    local okE, ent = pcall(function() return Ext.Entity.Get(uuid) end)
    if not okE or not ent then
        errors[#errors+1] = "Ext.Entity.Get err=" .. tostring(ent)
        return nil, table.concat(errors, " | ")
    end
    local okT, t = pcall(function() return ent.Transform.Transform.Translate end)
    if not okT or not t then
        errors[#errors+1] = "Transform.Transform.Translate err=" .. tostring(t)
        return nil, table.concat(errors, " | ")
    end
    local x = t[1] or t.x
    local y = t[2] or t.y
    local z = t[3] or t.z
    if not (x and y and z) then
        errors[#errors+1] = "Transform fields nil"
        return nil, table.concat(errors, " | ")
    end
    return { x = tonumber(x), y = tonumber(y), z = tonumber(z) }, nil
end

function M.Register()
    Ext.RegisterNetListener(Net.Channels.SpawnDummy, function(_, payload, userId)
        local okP, req = pcall(Ext.Json.Parse, payload or "{}")
        if not okP or type(req) ~= "table" then req = {} end
        if req.list then
            local _, top, err = findDummyTemplate(req.filter)
            Log.Write(string.format("Dummy: list filter=%s -> %d candidates %s",
                tostring(req.filter), #(top or {}), err and ("(" .. err .. ")") or ""))
            for i, c in ipairs(top or {}) do
                Log.Write(string.format("  [%d] score=%s %s", i, tostring(c.score), c.name))
            end
            sendReply(userId, { ok = false, reason = "list only (nothing spawned)",
                                list = top or {}, filter = req.filter })
            return
        end
        ServerNet.EnqueueOsi(function()
            local caster = ServerNet.UserToCharacter(userId)
            if not caster then
                sendReply(userId, { ok = false, reason = "no character for user" })
                return
            end
            Log.Write("Dummy: user=" .. tostring(userId) .. " caster=" .. tostring(caster))
            local pos, err = readPos(caster)
            if not pos then
                Log.Write("Dummy: position lookup failed: " .. tostring(err))
                sendReply(userId, { ok = false, reason = "position lookup failed: " .. tostring(err) })
                return
            end
            local x = pos.x + 3.0
            local y = pos.y
            local z = pos.z
            -- Moving dummy: ahead along the player's view, patrolling across it.
            local fx, fz = 0, 1
            if req.fwd and tonumber(req.fwd.x) and tonumber(req.fwd.z) then
                local l = math.sqrt(req.fwd.x ^ 2 + req.fwd.z ^ 2)
                if l > 1e-3 then fx, fz = req.fwd.x / l, req.fwd.z / l end
            end
            if req.moving then
                local md = pdata.moving_dummy or {}
                x, z = pos.x + fx * (md.ahead_m or 9), pos.z + fz * (md.ahead_m or 9)
            end

            local choice, topList, err = findDummyTemplate(req.filter)
            if not choice then
                Log.Write("Dummy: " .. tostring(err))
                for i, c in ipairs(topList or {}) do
                    Log.Write(string.format("  cand[%d] name=%s uuid=%s", i, c.name, c.uuid))
                end
                sendReply(userId, {
                    ok      = false,
                    reason  = err or "no template matched",
                    top     = topList or {},
                })
                return
            end

            Log.Write(string.format("Dummy: chosen template name=%s uuid=%s tier=%s type=%s",
                choice.name, choice.uuid, choice.tier, tostring(choice.type)))

            local okC, spawned = pcall(function()
                return Osi.CreateAt(choice.uuid, x, y, z, 1, 1, "")
            end)
            if not okC or not spawned or spawned == "" then
                Log.Write("Dummy: CreateAt failed uuid=" .. choice.uuid)
                sendReply(userId, {
                    ok = false,
                    reason = "CreateAt failed",
                    template = choice,
                })
                return
            end

            Log.Write(string.format("Dummy: spawned %s at (%.2f, %.2f, %.2f)", spawned, x, y, z))

            -- Hostile only on request: a hostile goblin that sees you makes
            -- BG3 start TURN-BASED combat, which real-time M1b can't stop
            -- yet. Damage works on a neutral target too.
            if req.hostile then
                local okF, errF = pcall(function()
                    Osi.SetFaction(spawned, "Evil NPC_64321d50-d516-b1b2-cfac-2eb773de1ff6")
                end)
                local okG, fac = pcall(function() return Osi.GetFaction(spawned) end)
                Log.Write(string.format("Dummy: hostile SetFaction ok=%s err=%s now=%s",
                    tostring(okF), tostring(errF), okG and tostring(fac) or "?"))
            end
            if req.moving then
                local md = pdata.moving_dummy or {}
                local half = (md.span_m or 6) / 2
                local px, pz = -fz, fx   -- across the view
                patrols[tostring(spawned)] = {
                    a = { x + px * half, y, z + pz * half }, b = { x - px * half, y, z - pz * half },
                    goal = "a", issuedAt = -1e9,
                }
                Log.Write(string.format("Dummy: %s will walk between (%.1f,%.1f) and (%.1f,%.1f), %.1f m apart",
                    tostring(spawned), x + px * half, z + pz * half, x - px * half, z - pz * half, 2 * half))
            end
            local okH, hp = pcall(function() return Osi.GetHitpoints(spawned) end)
            Log.Write(string.format("Dummy: hp=%s hostile=%s", okH and tostring(hp) or "?", tostring(req.hostile == true)))

            sendReply(userId, {
                ok       = true,
                uuid     = tostring(spawned),
                template = choice,
                pos      = { x = x, y = y, z = z },
            })
        end)
    end)
    Ext.Events.Tick:Subscribe(function() pcall(patrolTick) end)
    Log.Write("Dummy: registered (Ext.Template probe + client reply, moving dummies)")
end

return M
