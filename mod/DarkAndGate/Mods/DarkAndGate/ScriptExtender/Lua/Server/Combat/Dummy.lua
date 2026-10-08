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

-- Ranked name patterns. First-match wins within each tier; tiers are
-- scanned in order. "Combat_Dummy" from the Larian training area, failing
-- that any goblin from Act 1. Patterns are lowercase Lua patterns applied
-- to the lowercased template name.
local TIERS = {
    { tag = "training",     patterns = { "trainingdummy", "training_dummy", "combat_dummy", "combatdummy" } },
    { tag = "any-dummy",    patterns = { "dummy" } },
    { tag = "act1-goblin",  patterns = { "^gob_", "goblin" } },
}

-- Collect templates, grouped by tier. Returns:
--   choice   = { uuid, name, tier } | nil
--   topList  = up to 10 { uuid, name } candidates when no match is found,
--              so the user can see what's actually available.
local function findDummyTemplate()
    if not (Ext.Template and Ext.Template.GetAllRootTemplates) then
        return nil, {}, "Ext.Template.GetAllRootTemplates unavailable"
    end
    local okT, templates = pcall(Ext.Template.GetAllRootTemplates)
    if not okT or not templates then
        return nil, {}, "GetAllRootTemplates threw: " .. tostring(templates)
    end

    local pool = {}
    local count = 0
    for uuid, tpl in pairs(templates) do
        count = count + 1
        local okN, n = pcall(function() return tpl.Name end)
        if okN and n and n ~= "" then
            pool[#pool + 1] = { uuid = tostring(uuid), name = tostring(n) }
        end
    end
    Log.Write(string.format("Dummy: Ext.Template returned %d templates (%d with Name)", count, #pool))

    -- Prefer only character-shaped templates. Filter by Stats presence if
    -- available (characters have a Stats field; items/triggers don't).
    local function hasStats(uuid)
        local okTpl, tpl = pcall(function() return templates[uuid] end)
        if not okTpl or not tpl then return false end
        local okS, s = pcall(function() return tpl.Stats end)
        if okS and s and s ~= "" then return true end
        return false
    end

    for _, tier in ipairs(TIERS) do
        for _, cand in ipairs(pool) do
            local n = cand.name:lower()
            for _, pat in ipairs(tier.patterns) do
                if n:find(pat) then
                    if hasStats(cand.uuid) then
                        return { uuid = cand.uuid, name = cand.name, tier = tier.tag }, nil, nil
                    end
                end
            end
        end
    end

    -- No match. Return the 10 most "dummy / goblin / monster" sounding
    -- candidates so the user can pick one.
    local function score(n)
        n = n:lower()
        if n:find("dummy")   then return 10 end
        if n:find("goblin")  then return 9 end
        if n:find("^gob_")   then return 8 end
        if n:find("monster") then return 5 end
        if n:find("npc")     then return 3 end
        return 0
    end
    table.sort(pool, function(a, b)
        local sa, sb = score(a.name), score(b.name)
        if sa ~= sb then return sa > sb end
        return a.name < b.name
    end)
    local top = {}
    for i = 1, math.min(10, #pool) do top[i] = pool[i] end
    return nil, top, "no template matched the ranked patterns"
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
    Ext.RegisterNetListener(Net.Channels.SpawnDummy, function(_, _, userId)
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

            local choice, topList, err = findDummyTemplate()
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

            Log.Write(string.format("Dummy: chosen template name=%s uuid=%s tier=%s",
                choice.name, choice.uuid, choice.tier))

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
            sendReply(userId, {
                ok       = true,
                uuid     = tostring(spawned),
                template = choice,
                pos      = { x = x, y = y, z = z },
            })
        end)
    end)
    Log.Write("Dummy: registered (Ext.Template probe + client reply)")
end

return M
