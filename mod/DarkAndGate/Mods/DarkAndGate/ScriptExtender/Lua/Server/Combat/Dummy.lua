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

function M.Register()
    Ext.RegisterNetListener(Net.Channels.SpawnDummy, function(_, _, userId)
        ServerNet.EnqueueOsi(function()
            local caster = ServerNet.UserToCharacter(userId)
            if not caster then
                sendReply(userId, { ok = false, reason = "no character for user" })
                return
            end
            local okX, cx = pcall(function() return Osi.GetX(caster) end)
            local okY, cy = pcall(function() return Osi.GetY(caster) end)
            local okZ, cz = pcall(function() return Osi.GetZ(caster) end)
            if not (okX and okY and okZ) then
                sendReply(userId, { ok = false, reason = "position lookup failed" })
                return
            end
            local x = (tonumber(cx) or 0) + 3.0
            local y =  tonumber(cy) or 0
            local z =  tonumber(cz) or 0

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
