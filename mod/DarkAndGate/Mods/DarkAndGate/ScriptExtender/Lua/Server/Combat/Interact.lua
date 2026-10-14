-- SPDX-License-Identifier: GPL-3.0-or-later
-- F interaction, server side (DECISIONS 2026-10-12, docs/spikes/lookat.md).
--
-- Classify (InteractClassify -> InteractInfo): what an entity under a
-- player's crosshair is, from authoritative server data (ServerItem flags,
-- the item's BG3 use actions, Osiris queries), so the client highlights only
-- interactive things:
--   talk    a living, non-hostile character (not in combat) that BG3 flags as
--           having a dialog (GetHasOsirisDialog: every DB_Dialogs speaker,
--           one to four speakers per row), a default dialog, or a party member
--   loot    a corpse the story doesn't block (DB_CustomLootCorpseResponse)
--   door / close / locked / open / pickup / climb   items
--   use     an item with one of BG3's world use actions (data/interact.lua
--           use_actions: StoryUse, Sit, Lie...). Decorations have none and
--           get no [F] (playtest 2026-10-13: brain jars, an invisible helper)
--   none    anything else
--
-- Request (InteractRequest -> InteractResult): F on it starts it at once,
-- the way a click would (docs/spikes/lookat.md):
--   talk    Osi.DialogStartRequested(npc, player): the engine's own event, so
--           every story handler runs exactly as for a click
--   loot    Osi.OpenCharacterLootUI(player, corpse)
--   pickup  Osi.Pickup(player, item, "DAG_Pickup", 1)
--   others  Osi.Use(player, item, 1, 1, "DAG_Interact") (walks up, animates).
--           That Osiris task doesn't count a player-style use as done and runs
--           it again: a ladder is climbed back down, then up, forever; a lever
--           is pulled twice (playtest 2026-10-13, docs/spikes/lookat.md). So
--           the task is ended at the first UseFinished of the item F used.
-- Refused when farther than data/interact.lua server_reach_m.
--
--   !dag_unstick   your character keeps doing something on its own (a use
--                  BG3 repeats): its Osiris task list is cleared

local Log   = Ext.Require("Shared/Log.lua")
local Net   = Ext.Require("Shared/Net.lua")
local Party = Ext.Require("Server/Party.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")
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

-- BG3's own use actions on an item (eoc::item_template::UseActionComponent,
-- plus its template's OnUsePeaceActions) -> { [ActionDataType] = true }:
-- {} when it has none, nil when the entity can't be read.
local function useActions(target)
    local ok, set = pcall(function()
        local e = Ext.Entity.Get(target)
        local out = {}
        local function add(list)
            if list == nil then return end
            for i = 1, #list do
                local okT, ty = pcall(function() return tostring(list[i].Type) end)
                if okT and ty then out[ty] = true end
            end
        end
        pcall(function() add(e.UseAction and e.UseAction.UseActions) end)
        pcall(function() add(e.ServerItem.Template.OnUsePeaceActions) end)
        return out
    end)
    return ok and set or nil
end

local function actionList(acts)
    local t = {}
    for a in pairs(acts or {}) do t[#t + 1] = a end
    table.sort(t)
    return #t > 0 and table.concat(t, ",") or "none"
end

-- -> kind, name, use action (kind "use"), why (for the log)
function M.Classify(player, target)
    target = Party.Norm(target)
    if not target or target == Party.Norm(player) then return "none" end
    local name = displayName(target)
    if q("IsCharacter", target) == 1 then
        if q("IsDead", target) == 1 then
            if rows("DB_CustomLootCorpseResponse", player, target, 0) > 0 then return "none", name, nil, "the story blocks looting" end
            return "loot", name
        end
        if q("IsEnemy", target, player) == 1 or q("IsInCombat", target) == 1 then return "none", name, nil, "hostile or fighting" end
        if q("IsDialogueBlocked", target) == 1 then return "none", name, nil, "dialogue blocked" end
        -- BG3 flags every speaker of a story dialogue (DB_Dialogs with one to
        -- four speakers, automated ones too) with SetHasDialog, and its
        -- click-to-talk cursor follows that flag. Playtest 2026-10-13: Myrnath,
        -- the man with the exposed brain in the nautiloid lab, is in a
        -- 3-speaker row, which the 2-column DB_Dialogs check missed.
        if Party.IsMember(target) then return "talk", name, nil, "party member" end
        if q("GetHasOsirisDialog", target) == 1 then return "talk", name, nil, "has a dialog" end
        if q("GetHasDefaultDialog", target) == 1 then return "talk", name, nil, "default dialog" end
        if rows("DB_Dialogs", target, nil) > 0 then return "talk", name, nil, "DB_Dialogs" end
        return "none", name, nil, "no dialog"
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
        if flags.InteractionDisabled or flags.Invisible or flags.OffStage or flags.Destroyed then
            return "none", name, nil, "disabled / invisible / off stage / destroyed"
        end
        local acts = useActions(target)
        local why = "BG3 use actions " .. (acts and actionList(acts) or "unreadable")
        if flags.IsLadder or q("IsLadder", target) == 1 or (acts and acts.Ladder) then return "climb", name, nil, why end
        if flags.IsDoor or (acts and acts.Door) then
            if q("IsOpened", target) == 1 then return "close", name, nil, why end
            return (q("IsLocked", target) == 1) and "locked" or "door", name, nil, why
        end
        if flags.IsContainer or q("IsContainer", target) == 1 then
            return (q("IsLocked", target) == 1) and "locked" or "open", name, nil, why
        end
        if flags.CanBePickedUp or q("GetCanPickUp", target) == 1 then return "pickup", name, nil, why end
        if acts == nil then
            -- Use actions unreadable: the item flags decide, as before.
            return flags.CanUse and "use" or "none", name, nil, why
        end
        -- "use" needs one of BG3's world use actions (the story's
        -- SetCanInteract(item, 0) switches it off). The CanUse flag and
        -- GetCanInteract are set on plain decorations too.
        if q("GetCanInteract", target) == 0 then return "none", name, nil, why .. ", the story switched it off" end
        for _, a in ipairs(cfg.use_actions or {}) do
            if acts[a] then return "use", name, a, why end
        end
        return "none", name, nil, why
    end
    return "none", name
end

local function distance(a, b)
    local ok, d = pcall(function() return Osi.GetDistanceTo(a, b) end)
    return ok and tonumber(d) or nil
end

-- F uses in progress: character -> { item, untilMs, ended }. BG3's Osiris use
-- task (Osi.Use) doesn't count a player-style use as done and starts it again
-- (esv::OsirisUseItemTask::Update re-arms its MoveAndUseItem behaviour while
-- that reports neither success nor a finished use): a ladder is climbed back
-- down, then up, forever; a lever is pulled twice (playtest 2026-10-13). The
-- task is ended at the first UseFinished of the item F used.
local using = {}
local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function frontTask(char)
    local ok, ty = pcall(function()
        local tasks = Ext.Entity.Get(char).ServerCharacter.OsirisController.Tasks
        if #tasks == 0 then return "none" end
        return tostring(tasks[1].Type)
    end)
    return ok and ty or "unreadable"
end

-- Only while the character's current Osiris task is still that use: a task
-- the story queued after it stays.
local function endUseTask(char)
    local front = frontTask(char)
    if front ~= "UseItem" and front ~= "unreadable" then return "its use task is already over (current task: " .. front .. ")" end
    local okP = pcall(function() Osi.PurgeOsirisQueue(char, 1) end)
    local okF = pcall(function() Osi.FlushOsirisQueue(char) end)
    return string.format("its use task ended so BG3 can't run it again (task list %s, purge %s, flush %s)", front,
        okP and "ok" or "FAILED", okF and "ok" or "FAILED")
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
    using[Party.Norm(player)] = { item = Party.Norm(target), untilMs = nowMs() + 60000, ended = false }
    local ok, err = pcall(function() Osi.Use(player, target, 1, 1, "DAG_Interact") end)
    return ok, ok and string.format("Osi.Use(%s, 1, 1)", tostring(name)) or ("Osi.Use ERROR " .. tostring(err))
end

local logged = {}
local watching = {}   -- container uuid -> { peer } while its loot window is open
function M.Register()
    Ext.RegisterNetListener(Net.Channels.InteractRequest, function(_, payload, peer)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" or not p.target then return end
        Ext.OnNextTick(function()
            local player = Party.CharacterOfPeer(peer)
            local target = Party.Norm(p.target)
            local kind, name, act = M.Classify(player, target)
            local d = distance(player, target)
            local okS, how
            if kind == "none" then
                okS, how = false, "not interactive"
            elseif d and d > (cfg.server_reach_m or 6) then
                okS, how = false, string.format("too far (%.1f m)", d)
            else
                okS, how = start(player, target, kind)
                -- A chest / corpse opens BG3's loot window: the client frees the
                -- cursor until it closes (Osiris Closed, Esc, or walking away).
                if okS and (kind == "open" or kind == "loot") then
                    watching[target] = watching[target] or { peers = {} }
                    watching[target].peers[peer] = true
                    pcall(function() Ext.Net.PostMessageToUser(peer, Net.Channels.ContainerUI,
                        Ext.Json.Stringify({ open = true, target = target, name = name })) end)
                end
            end
            Log.Write(string.format("Interact: %s -> [F] %s %s (%s, %s m): %s", displayName(player) or tostring(player),
                (act and cfg.use_verbs and cfg.use_verbs[act]) or cfg.verbs[kind] or kind,
                tostring(name), tostring(target), d and string.format("%.1f", d) or "?", how))
            pcall(function()
                Ext.Net.PostMessageToUser(peer, Net.Channels.InteractResult, Ext.Json.Stringify({ target = target, ok = okS, how = how }))
            end)
        end)
    end)
    -- The interaction's Osiris task is over: our queue purges may run again.
    local function done(char) ServerNet.SetInteracting(Party.Norm(char), nil) end
    Ext.Osiris.RegisterListener("UseFinished", 3, "after", function(char, item, okUse)
        local c, it = Party.Norm(char), Party.Norm(item)
        local u = using[c]
        local extra = ""
        if u and u.item == it and nowMs() < u.untilMs then
            extra = (u.ended and " -- BG3 ran it again on its own; " or " -> ") .. endUseTask(c)
            u.ended, u.untilMs = true, nowMs() + 10000
        end
        done(char)
        Log.Write(string.format("Interact: %s finished using %s (%s)%s", tostring(displayName(char)), tostring(displayName(item) or item),
            tonumber(okUse) == 1 and "ok" or "failed", extra))
    end)
    Ext.Osiris.RegisterListener("UseStarted", 2, "after", function(char, item)
        local c, it = Party.Norm(char), Party.Norm(item)
        local u = using[c]
        if u and u.ended and u.item == it and nowMs() < u.untilMs then
            Log.Write(string.format("Interact: %s started using %s AGAIN on its own after F's use task ended (no new F)",
                tostring(displayName(char)), tostring(displayName(item) or item)))
        end
    end)
    Ext.Osiris.RegisterListener("PickupFailed", 2, "after", function(char, item)
        done(char)
        Log.Write(string.format("Interact: %s could not pick up %s", tostring(displayName(char)), tostring(displayName(item) or item)))
    end)
    Ext.Osiris.RegisterListener("EntityEvent", 2, "after", function(obj, ev)
        if ev == "DAG_Interact" or ev == "DAG_Pickup" then done(obj) end
    end)
    Ext.Osiris.RegisterListener("Closed", 1, "after", function(item)
        local u = Party.Norm(item)
        local w = watching[u]
        if not w then return end
        watching[u] = nil
        for peer in pairs(w.peers or {}) do
            pcall(function() Ext.Net.PostMessageToUser(peer, Net.Channels.ContainerUI,
                Ext.Json.Stringify({ open = false, target = u, why = "closed" })) end)
        end
        Log.Write(string.format("Interact: %s closed -> first person back", tostring(displayName(u) or u)))
    end)
    Ext.RegisterNetListener(Net.Channels.InteractClassify, function(_, payload, peer)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or type(p) ~= "table" or not p.target then return end
        Ext.OnNextTick(function()
            local player = Party.CharacterOfPeer(peer)
            local okC, kind, name, act, why = pcall(M.Classify, player, p.target)
            if not okC then
                Log.Write("Interact: classify " .. tostring(p.target) .. " failed: " .. tostring(kind))
                kind, name, act, why = "none", nil, nil, nil
            end
            local verb = (act and cfg.use_verbs and cfg.use_verbs[act]) or cfg.verbs[kind]
            if not logged[p.target] then
                logged[p.target] = true
                Log.Write(string.format("Interact: %s (%s) is %s%s%s", tostring(name), tostring(p.target), kind,
                    verb and (" -> \"[F] " .. verb .. "\"") or "", why and (" (" .. why .. ")") or ""))
            end
            pcall(function()
                Ext.Net.PostMessageToUser(peer, Net.Channels.InteractInfo,
                    Ext.Json.Stringify({ target = p.target, kind = kind, verb = verb, name = name }))
            end)
        end)
    end)
    ConsoleForward.Server("dag_unstick", function()
        local c = ConsoleForward.Caller()
        local char = Party.Norm(c and Party.CharacterOfPeer(c.peer) or Party.Controlled(nil))
        if not char then Log.Write("Interact: !dag_unstick: no character"); return end
        local front = frontTask(char)
        local okP = pcall(function() Osi.PurgeOsirisQueue(char, 1) end)
        local okF = pcall(function() Osi.FlushOsirisQueue(char) end)
        using[char] = nil
        done(char)
        Log.Write(string.format("Interact: !dag_unstick -> %s's Osiris tasks cleared (current task was %s; purge %s, flush %s)",
            tostring(displayName(char) or char), front, okP and "ok" or "FAILED", okF and "ok" or "FAILED"))
    end)
    Log.Write("Interact: registered (classify + F requests; !dag_unstick)")
end

return M
