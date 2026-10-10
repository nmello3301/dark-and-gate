-- SPDX-License-Identifier: GPL-3.0-or-later
-- Animation gallery, server side: spawns and removes the preview copies.
--
-- Client (Client/AnimLib/Gallery.lua) asks for n copies of a rig with
-- DAG_AnimLibSpawn { n, rig, template?, target? }. The server:
--   * picks a neutral character template whose name matches the rig
--     (race/gender tokens, generic NPCs preferred), unless the client sent
--     an override or the scan finds nothing -- then the browsed
--     character's own template is used. The choice is logged.
--   * spawns ONE copy per tick on a grid 4 m in front of the requester,
--     1.5 m apart, and makes each copy inert: no combat, no fighting, no
--     dialogue, invulnerable (boost, if the build accepts it).
--   * replies DAG_AnimLibSpawned { slot, uuid } per copy (or { slot, error }).
-- DAG_AnimLibClear removes every copy. Copies are also removed at level
-- start (leftovers listed in DarkAndGate/animlib-spawned.txt) and before a
-- save, so none ever end up in a save game.
--
-- Copies are allowed targets for DAG_PlayAnimRequest (Server/Net.lua).

local Log       = Ext.Require("Shared/Log.lua")
local Net       = Ext.Require("Shared/Net.lua")
local ServerNet = Ext.Require("Server/Net.lua")

local M = {}

local SPAWNED_PATH = "DarkAndGate/animlib-spawned.txt"
local MAX_COPIES = 25
local SPACING = 2.0   -- 2026-10-09 playtest: 1.5 m felt a bit tight
local AHEAD = 4.0
local PER_ROW = 5

local copies = {}          -- uuid -> slot
local copyList = {}        -- slot -> uuid
local templateByRig = {}   -- rig -> { id, name }
local spawnQueue = {}
local spawning = false

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function saveSpawned()
    local lines = {}
    for u in pairs(copies) do lines[#lines + 1] = u end
    pcall(Ext.IO.SaveFile, SPAWNED_PATH, table.concat(lines, "\n"))
end

local function removeCopy(uuid)
    for _, fn in ipairs({ "SetOnStage", "SetHasDialog" }) do
        pcall(function() Osi[fn](uuid, 0) end)
    end
    pcall(function() Osi.RequestDelete(uuid) end)
    pcall(function() Osi.RequestDeleteTemporary(uuid) end)
end

-- keepFile: leave the uuid list on disk (used before a save: if the
-- delete lands after the save is written, the next level start still
-- removes them).
local function clearAll(why, keepFile)
    local n = 0
    for u in pairs(copies) do removeCopy(u); n = n + 1 end
    copies, copyList, spawnQueue = {}, {}, {}
    spawning = false
    if not keepFile then saveSpawned() end
    if n > 0 then Log.Write(string.format("AnimLib: removed %d gallery copies (%s)", n, why)) end
    return n
end

-- ---------------------------------------------------------------------
-- Template choice by rig
-- ---------------------------------------------------------------------
local RIG_TOKENS = {
    HUM_M  = { "humans_male", "elves_male", "halfelves_male", "tieflings_male", "drow_male" },
    HUM_F  = { "humans_female", "elves_female", "halfelves_female", "tieflings_female", "drow_female" },
    HUM_MS = { "malestrong", "male_strong", "strong_male" },
    HUM_FS = { "femalestrong", "female_strong", "strong_female" },
    DWR_M  = { "dwarves_male", "dwarf_male" },
    DWR_F  = { "dwarves_female", "dwarf_female" },
    HFL_M  = { "halflings_male", "halfling_male" },
    HFL_F  = { "halflings_female", "halfling_female" },
    GNO_M  = { "gnomes_male", "gnome_male" },
    GNO_F  = { "gnomes_female", "gnome_female" },
    DGB_M  = { "dragonborn_male" },
    DGB_F  = { "dragonborn_female" },
    GTY_M  = { "githyanki_male" },
    GTY_F  = { "githyanki_female" },
    HRC_M  = { "halforcs_male", "halforc_male" },
    HRC_F  = { "halforcs_female", "halforc_female" },
}
local GOOD = { "commoner", "civilian", "refugee", "villager", "citizen", "peasant", "worker", "townsfolk", "generic", "merchant" }
local BAD = { "combat", "boss", "origin", "player", "companion", "avatar", "dead", "corpse", "dummy", "illithid",
              "undead", "zombie", "skeleton", "ghost", "cine", "scene", "_tmp", "test", "polymorph", "summon" }

local function templateIsCharacter(tpl)
    local ok, t = pcall(function() return tpl.TemplateType end)
    return ok and t ~= nil and tostring(t):lower() == "character"
end

local function scoreTemplate(rig, name)
    local n = name:lower()
    local tokens = RIG_TOKENS[rig]
    if not tokens then return nil end
    local hit = false
    for _, t in ipairs(tokens) do if n:find(t, 1, true) then hit = true; break end end
    if not hit then return nil end
    local s = 10
    if not rig:find("S$") and n:find("strong", 1, true) then s = s - 20 end
    for _, w in ipairs(GOOD) do if n:find(w, 1, true) then s = s + 4; break end end
    for _, w in ipairs(BAD) do if n:find(w, 1, true) then s = s - 8 end end
    if n:sub(1, 2) == "s_" then s = s - 6 end   -- story-unique characters
    return s
end

local function pickTemplate(rig)
    if templateByRig[rig] then return templateByRig[rig] end
    local t0 = now()
    local okT, templates = pcall(Ext.Template.GetAllRootTemplates)
    if not okT or not templates then
        Log.Write("AnimLib: GetAllRootTemplates failed: " .. tostring(templates))
        return nil
    end
    local best, top = nil, {}
    for id, tpl in pairs(templates) do
        local okN, name = pcall(function() return tpl.Name end)
        if okN and name and templateIsCharacter(tpl) then
            local sc = scoreTemplate(rig, tostring(name))
            if sc and sc > 0 then
                local c = { id = tostring(id), name = tostring(name), score = sc }
                top[#top + 1] = c
                if not best or sc > best.score or (sc == best.score and c.name < best.name) then best = c end
            end
        end
    end
    table.sort(top, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.name < b.name end)
    local shown = {}
    for i = 1, math.min(5, #top) do shown[#shown + 1] = string.format("%s(%d)", top[i].name, top[i].score) end
    Log.Write(string.format("AnimLib: template scan for rig %s took %d ms, %d candidates; top: %s",
        rig, now() - t0, #top, table.concat(shown, ", ")))
    if best then templateByRig[rig] = best end
    return best
end

local function ownTemplate(uuid)
    local ok, t = pcall(function() return Osi.GetTemplate(uuid) end)
    if ok and t and t ~= "" then
        return { id = tostring(t):match("(%x+%-%x+%-%x+%-%x+%-%x+)$") or tostring(t), name = tostring(t) }
    end
    return nil
end

-- ---------------------------------------------------------------------
-- Spawning (one copy per tick)
-- ---------------------------------------------------------------------
local function reply(userId, payload)
    Ext.Net.PostMessageToUser(userId, Net.Channels.AnimLibSpawned, Ext.Json.Stringify(payload))
end

local function makeInert(uuid)
    local results = {}
    for _, call in ipairs({
        { "SetCanJoinCombat", function() Osi.SetCanJoinCombat(uuid, 0) end },
        { "SetCanFight",      function() Osi.SetCanFight(uuid, 0) end },
        { "SetHasDialog",     function() Osi.SetHasDialog(uuid, 0) end },
        { "Invulnerable",     function() Osi.AddBoosts(uuid, "Invulnerable()", "DarkAndGate_AnimLib", uuid) end },
    }) do
        local ok, err = pcall(call[2])
        results[#results + 1] = call[1] .. "=" .. (ok and "ok" or tostring(err))
    end
    return table.concat(results, " ")
end

local inertLogged = false
local function spawnNext()
    local job = table.remove(spawnQueue, 1)
    if not job then spawning = false; return end
    local t0 = now()
    local row, col = math.floor((job.slot - 1) / PER_ROW), (job.slot - 1) % PER_ROW
    local cols = math.min(PER_ROW, job.n)
    local side = (col - (cols - 1) / 2) * SPACING
    local ahead = AHEAD + row * SPACING
    local x = job.origin[1] + job.fwd[1] * ahead + job.right[1] * side
    local z = job.origin[3] + job.fwd[3] * ahead + job.right[3] * side
    local y = job.origin[2]
    local okV, vx, vy, vz = pcall(function() return Osi.FindValidPosition(x, y, z, 2.0, job.anchor, 1) end)
    if okV and vx then x, y, z = vx, vy, vz end
    local okC, uuid = pcall(function() return Osi.CreateAt(job.template.id, x, y, z, 1, 0, "") end)
    if not okC or not uuid or uuid == "" then
        Log.Write(string.format("AnimLib: slot %d CreateAt failed (%s)", job.slot, tostring(uuid)))
        reply(job.userId, { slot = job.slot, error = "spawn failed" })
    else
        copies[uuid] = job.slot
        copyList[job.slot] = uuid
        saveSpawned()
        local inert = makeInert(uuid)
        if not inertLogged then
            inertLogged = true
            Log.Write("AnimLib: copy setup " .. inert)
        end
        local okS, errS = pcall(function() Osi.SteerTo(uuid, job.anchor, 1) end)
        if job.slot == 1 then
            Log.Write("AnimLib: face player via Osi.SteerTo " .. (okS and "ok" or ("failed: " .. tostring(errS))))
        end
        reply(job.userId, { slot = job.slot, uuid = uuid, ms = now() - t0 })
    end
    if #spawnQueue > 0 then
        ServerNet.EnqueueOsi(spawnNext)
    else
        spawning = false
        Log.Write(string.format("AnimLib: gallery spawn done, %d copies", #copyList))
    end
end

local function onSpawn(payload, userId)
    local anchor = ServerNet.UserToCharacter(userId)
    if not anchor then return end
    local n = math.max(1, math.min(MAX_COPIES, tonumber(payload.n) or 12))
    local rig = tostring(payload.rig or "HUM_M")
    local tpl
    if payload.template and payload.template ~= "" then
        tpl = { id = payload.template, name = "override " .. payload.template }
    else
        tpl = pickTemplate(rig)
        if not tpl and payload.target then
            tpl = ownTemplate(payload.target)
            if tpl then Log.Write("AnimLib: no generic template for rig " .. rig .. ", using the browsed character's own: " .. tpl.name) end
        end
    end
    if not tpl then
        Log.Write("AnimLib: no template for rig " .. rig)
        reply(userId, { slot = 0, error = "no template for rig " .. rig })
        return
    end
    Log.Write(string.format("AnimLib: gallery %d copies of rig %s using template %s (%s)", n, rig, tpl.name, tpl.id))

    local okP, px, py, pz = pcall(function() return Osi.GetPosition(anchor) end)
    if not okP or not tonumber(px) then Log.Write("AnimLib: no player position"); return end
    local f = payload.fwd or { 0, 0, 1 }
    local fx, fz = tonumber(f[1]) or 0, tonumber(f[3]) or 1
    local fl = math.sqrt(fx * fx + fz * fz)
    if fl < 1e-3 then fx, fz, fl = 0, 1, 1 end
    fx, fz = fx / fl, fz / fl

    -- Reuse existing copies: only spawn the missing slots.
    for slot = 1, n do
        if copyList[slot] then
            reply(userId, { slot = slot, uuid = copyList[slot], reused = true })
        else
            spawnQueue[#spawnQueue + 1] = {
                slot = slot, n = n, userId = userId, anchor = anchor, template = tpl,
                origin = { tonumber(px), tonumber(py), tonumber(pz) },
                fwd = { fx, 0, fz }, right = { fz, 0, -fx },
            }
        end
    end
    -- Copies beyond n are removed.
    for slot = #copyList, n + 1, -1 do
        local u = copyList[slot]
        if u then removeCopy(u); copies[u] = nil; copyList[slot] = nil end
    end
    saveSpawned()
    if #spawnQueue > 0 and not spawning then
        spawning = true
        ServerNet.EnqueueOsi(spawnNext)
    end
end

local function removeLeftovers()
    local ok, s = pcall(Ext.IO.LoadFile, SPAWNED_PATH)
    if not ok or not s or s == "" then return end
    local n = 0
    for u in s:gmatch("[^\r\n]+") do removeCopy(u); n = n + 1 end
    pcall(Ext.IO.SaveFile, SPAWNED_PATH, "")
    if n > 0 then Log.Write(string.format("AnimLib: removed %d leftover gallery copies from a previous session", n)) end
end

function M.Register()
    ServerNet.SetAnimTargetCheck(function(uuid) return copies[uuid] ~= nil end)

    Ext.RegisterNetListener(Net.Channels.AnimLibSpawn, function(_, payload, userId)
        local ok, msg = pcall(Ext.Json.Parse, payload)
        if not ok then return end
        ServerNet.EnqueueOsi(function() onSpawn(msg, userId) end)
    end)
    -- Name each copy after the clip it plays (so the world shows which is
    -- which). Osi.SetStoryDisplayName is tried; its result is logged once.
    local nameLogged = false
    Ext.RegisterNetListener(Net.Channels.AnimLibName, function(_, payload)
        local ok, msg = pcall(Ext.Json.Parse, payload)
        if not ok or not msg or not copies[msg.uuid] then return end
        ServerNet.EnqueueOsi(function()
            local okN, err = pcall(function() Osi.SetStoryDisplayName(msg.uuid, tostring(msg.name)) end)
            if not nameLogged then
                nameLogged = true
                Log.Write("AnimLib: rename copies via Osi.SetStoryDisplayName " .. (okN and "ok" or ("failed: " .. tostring(err))))
            end
        end)
    end)
    Ext.RegisterNetListener(Net.Channels.AnimLibClear, function(_, payload)
        local ok, msg = pcall(Ext.Json.Parse, payload)
        ServerNet.EnqueueOsi(function() clearAll((ok and msg and msg.why) or "client request") end)
    end)

    -- Level start: remove anything a previous session left behind.
    pcall(function()
        Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function()
            copies, copyList = {}, {}
            removeLeftovers()
        end)
    end)
    -- Never save copies; forget them when the level unloads.
    Ext.Events.GameStateChanged:Subscribe(function(e)
        local to = tostring(e.ToState)
        if to == "Save" then
            local okC, err = pcall(clearAll, "before save", true)
            if not okC then Log.Write("AnimLib: clear before save failed: " .. tostring(err)) end
        elseif to == "UnloadLevel" or to == "UnloadSession" then
            copies, copyList, spawnQueue = {}, {}, {}
            spawning = false
        end
    end)
    Log.Write("AnimLib: server registered (gallery spawn/clear)")
end

return M
