-- SPDX-License-Identifier: GPL-3.0-or-later
-- F interaction, server side (DECISIONS 2026-10-12, docs/spikes/lookat.md).
--
-- Classify (InteractClassify -> InteractInfo): what an entity under a
-- player's crosshair is, from authoritative server data (ServerItem flags,
-- Osiris queries), so the client highlights only interactive things:
--   talk    a living, non-hostile character with a dialog (not in combat)
--   loot    a corpse the story doesn't block (DB_CustomLootCorpseResponse)
--   door / close / locked / open / pickup / use / climb   items
--   none    anything else
--
-- Request (InteractRequest -> InteractResult): F on it starts it at once,
-- the way a click would (docs/spikes/lookat.md):
--   talk    Osi.DialogStartRequested(npc, player): the engine's own event, so
--           every story handler runs exactly as for a click
--   loot    Osi.OpenCharacterLootUI(player, corpse)
--   pickup  Osi.Pickup(player, item, "DAG_Pickup", 1)
--   others  Osi.Use(player, item, 1, 1, "DAG_Interact"): vanilla's pattern for
--           a player opening a door or climbing a ladder (walks up, animates)
-- Refused when farther than data/interact.lua server_reach_m.

local Log   = Ext.Require("Shared/Log.lua")
local Net   = Ext.Require("Shared/Net.lua")
local Party = Ext.Require("Server/Party.lua")
local ServerNet = Ext.Require("Server/Net.lua")
local cfg   = Ext.Require("data/interact.lua")

local M = {}

local function q(fn, ...)
    local args = table.pack(...)
    local ok, v = pcall(function() return Osi[fn](table.unpack(args, 1, args.n)) end)
    return ok and tonumber(v) or nil
end

local function displayName(uuid)
    local ok, n = pcall(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(uuid)) end)
    return (ok and n and n ~= "") and n or nil
end
M.DisplayName = displayName

local function rows(db, ...)
    local args = table.pack(...)
    local ok, r = pcall(function() return Osi[db]:Get(table.unpack(args, 1, args.n)) end)
    if ok and type(r) == "table" then return #r end
    return 0
end

-- -> kind, name
function M.Classify(player, target)
    target = Party.Norm(target)
    if not target or target == Party.Norm(player) then return "none" end
    local name = displayName(target)
    if q("IsCharacter", target) == 1 then
        if q("IsDead", target) == 1 then
            if rows("DB_CustomLootCorpseResponse", player, target, 0) > 0 then return "none", name end
            return "loot", name
        end
        if q("IsEnemy", target, player) == 1 or q("IsInCombat", target) == 1 then return "none", name end
        if q("IsDialogueBlocked", target) == 1 then return "none", name end
        local talk = Party.IsMember(target) or q("GetHasDefaultDialog", target) == 1 or rows("DB_Dialogs", target, nil) > 0
        return talk and "talk" or "none", name
    end
    if q("IsItem", target) == 1 then
        local flags = {}
        pcall(function()
            local si = Ext.Entity.Get(target).ServerItem
            for _, f in ipairs({ "InteractionDisabled", "Invisible", "OffStage", "Destroyed", "IsLadder", "IsDoor", "IsContainer",
                                 "CanBePickedUp", "CanUse", "CanClimbOn" }) do
                local okF, v = pcall(function() return si[f] end)
                flags[f] = okF and v == true
            end
        end)
        if flags.InteractionDisabled or flags.Invisible or flags.OffStage or flags.Destroyed then return "none", name end
        if flags.IsLadder or q("IsLadder", target) == 1 then return "climb", name end
        if flags.IsDoor then
            if q("IsOpened", target) == 1 then return "close", name end
            return (q("IsLocked", target) == 1) and "locked" or "door", name
        end
        if flags.IsContainer or q("IsContainer", target) == 1 then
            return (q("IsLocked", target) == 1) and "locked" or "open", name
        end
        if flags.CanBePickedUp or q("GetCanPickUp", target) == 1 then return "pickup", name end
        if flags.CanUse or q("GetCanInteract", target) == 1 then return "use", name end
        if flags.CanClimbOn then return "climb", name end
        return "none", name
    end
    return "none", name
end

local function distance(a, b)
    local ok, d = pcall(function() return Osi.GetDistanceTo(a, b) end)
    return ok and tonumber(d) or nil
end

local function start(player, target, kind)
    local name = displayName(target)
    if kind == "talk" then
        local ok, err = pcall(function() Osi.DialogStartRequested(target, player) end)
        return ok, ok and "DialogStartRequested (the engine's click-to-talk event)" or ("DialogStartRequested ERROR " .. tostring(err))
    elseif kind == "loot" then
        local ok, r = pcall(function() return Osi.OpenCharacterLootUI(player, target) end)
        return ok, ok and ("OpenCharacterLootUI -> " .. tostring(r)) or ("OpenCharacterLootUI ERROR " .. tostring(r))
    elseif kind == "pickup" then
        ServerNet.SetInteracting(player, (tonumber(Ext.Timer.MonotonicTime()) or 0) + 5000)
        local ok, err = pcall(function() Osi.Pickup(player, target, "DAG_Pickup", 1) end)
        return ok, ok and "Osi.Pickup" or ("Osi.Pickup ERROR " .. tostring(err))
    end
    ServerNet.SetInteracting(player, (tonumber(Ext.Timer.MonotonicTime()) or 0) + 6000)
    local ok, err = pcall(function() Osi.Use(player, target, 1, 1, "DAG_Interact") end)
    return ok, ok and string.format("Osi.Use(%s, 1, 1)", tostring(name)) or ("Osi.Use ERROR " .. tostring(err))
end

local logged = {}
function M.Register()
    Ext.RegisterNetListener(Net.Channels.InteractRequest, function(_, payload, peer)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" or not p.target then return end
        Ext.OnNextTick(function()
            local player = Party.CharacterOfPeer(peer)
            local target = Party.Norm(p.target)
            local kind, name = M.Classify(player, target)
            local d = distance(player, target)
            local okS, how
            if kind == "none" then
                okS, how = false, "not interactive"
            elseif d and d > (cfg.server_reach_m or 6) then
                okS, how = false, string.format("too far (%.1f m)", d)
            else
                okS, how = start(player, target, kind)
            end
            Log.Write(string.format("Interact: %s -> [F] %s %s (%s, %s m): %s", displayName(player) or tostring(player), cfg.verbs[kind] or kind,
                tostring(name), tostring(target), d and string.format("%.1f", d) or "?", how))
            pcall(function()
                Ext.Net.PostMessageToUser(peer, Net.Channels.InteractResult, Ext.Json.Stringify({ target = target, ok = okS, how = how }))
            end)
        end)
    end)
    -- The interaction's Osiris task is over: our queue purges may run again.
    local function done(char) ServerNet.SetInteracting(Party.Norm(char), nil) end
    Ext.Osiris.RegisterListener("UseFinished", 3, "after", function(char, item, okUse)
        done(char)
        Log.Write(string.format("Interact: %s finished using %s (%s)", tostring(displayName(char)), tostring(displayName(item) or item),
            tonumber(okUse) == 1 and "ok" or "failed"))
    end)
    Ext.Osiris.RegisterListener("PickupFailed", 2, "after", function(char, item)
        done(char)
        Log.Write(string.format("Interact: %s could not pick up %s", tostring(displayName(char)), tostring(displayName(item) or item)))
    end)
    Ext.Osiris.RegisterListener("EntityEvent", 2, "after", function(obj, ev)
        if ev == "DAG_Interact" or ev == "DAG_Pickup" then done(obj) end
    end)
    Ext.RegisterNetListener(Net.Channels.InteractClassify, function(_, payload, peer)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" or not p.target then return end
        Ext.OnNextTick(function()
            local player = Party.CharacterOfPeer(peer)
            local okC, kind, name = pcall(M.Classify, player, p.target)
            if not okC then
                Log.Write("Interact: classify " .. tostring(p.target) .. " failed: " .. tostring(kind))
                kind, name = "none", nil
            end
            local verb = cfg.verbs[kind]
            if not logged[p.target] then
                logged[p.target] = true
                Log.Write(string.format("Interact: %s (%s) is %s%s", tostring(name), tostring(p.target), kind,
                    verb and (" -> \"[F] " .. verb .. "\"") or ""))
            end
            pcall(function()
                Ext.Net.PostMessageToUser(peer, Net.Channels.InteractInfo,
                    Ext.Json.Stringify({ target = p.target, kind = kind, verb = verb, name = name }))
            end)
        end)
    end)
    Log.Write("Interact: registered (classify + F requests)")
end

return M
