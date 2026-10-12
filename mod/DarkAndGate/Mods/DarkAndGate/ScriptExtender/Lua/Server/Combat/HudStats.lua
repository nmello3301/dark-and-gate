-- SPDX-License-Identifier: GPL-3.0-or-later
-- Server side of the first-person HUD (Client/HUD/Hud.lua):
--   * HudStats ~1 Hz to the clients: XP into the level / XP for the next
--     level (Experience component) and potion counts.
--   * UsePotion { kind }: drink the best matching potion (R = health,
--     T = mana) with Osi.Use, the call Larian's own story uses.
-- Potion lookup by root template, best first (docs/spikes/hud-tech.md §4).
-- BG3 has no mana potions; any item whose stats name contains one of
-- mana_potion_patterns counts (none in vanilla -- our own item comes later).

local Log       = Ext.Require("Shared/Log.lua")
local Net       = Ext.Require("Shared/Net.lua")
local ServerNet = Ext.Require("Server/Net.lua")

local M = {}

local HEALING = {   -- root templates, best first
    { name = "Supreme",  tpl = "7d78f227-e8d4-486d-8121-25cf0bee751d" },
    { name = "Superior", tpl = "df4f3495-abaf-4732-b82f-55bcccd561db" },
    { name = "Greater",  tpl = "e3b95c96-dc26-40fe-bfc0-baa05e1abd20" },
    { name = "Healing",  tpl = "d47006e9-8a51-453d-b200-9e0d42e9bbab" },
}
local MANA_PATTERNS = { "DAG_Potion_Mana", "Potion_Mana" }

local PERIOD_MS = 1000
local lastSent = -1e9
local lastPayload = nil

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function count(tpl, char)
    local ok, n = pcall(function() return Osi.TemplateIsInInventory(tpl, char) end)
    return ok and tonumber(n) or 0
end

-- Items in the character's inventories whose stats id matches a pattern.
local function findByStats(char, patterns)
    local out = {}
    pcall(function()
        local ent = Ext.Entity.Get(char)
        for _, inv in ipairs(ent.InventoryOwner.Inventories) do
            for _, slot in pairs(inv.InventoryContainer.Items) do
                local item = slot.Item
                local okS, sid = pcall(function() return tostring(item.Data.StatsId) end)
                if okS and sid then
                    for _, p in ipairs(patterns) do
                        if sid:find(p, 1, true) then out[#out + 1] = { item = item, stats = sid }; break end
                    end
                end
            end
        end
    end)
    return out
end

local function xpOf(char)
    local ok, cur, nxt, lvl = pcall(function()
        local e = Ext.Entity.Get(char)
        local x = e.Experience
        local level = 0
        pcall(function() level = e.AvailableLevel.Level end)
        return x.CurrentLevelExperience, x.NextLevelExperience, level
    end)
    if ok then return tonumber(cur) or 0, tonumber(nxt) or 0, tonumber(lvl) or 0 end
    return 0, 0, 0
end

local function send(force)
    local char = ServerNet.UserToCharacter(0)
    if not char then return end
    local hp = 0
    for _, h in ipairs(HEALING) do hp = hp + count(h.tpl, char) end
    local mana = #findByStats(char, MANA_PATTERNS)
    local cur, nxt, lvl = xpOf(char)
    local payload = Ext.Json.Stringify({ uuid = char, xpCur = cur, xpNext = nxt, level = lvl, hpPotions = hp, manaPotions = mana })
    if payload == lastPayload and not force then return end
    lastPayload = payload
    pcall(function() Ext.Net.BroadcastMessage(Net.Channels.HudStats, payload) end)
end

local function usePotion(userId, kind)
    local char = ServerNet.UserToCharacter(userId)
    if not char then return end
    if kind == "health" then
        for _, h in ipairs(HEALING) do
            local okI, item = pcall(function() return Osi.GetItemByTemplateInInventory(h.tpl, char) end)
            if okI and item and item ~= "" then
                local okU, err = pcall(function() Osi.Use(char, item, "") end)
                Log.Write(string.format("HudStats: health potion -> %s potion %s: Osi.Use %s", h.name, tostring(item),
                    okU and "ok" or ("ERROR " .. tostring(err))))
                send(true)
                return
            end
        end
        Log.Write("HudStats: health potion -> none in the inventory")
    else
        local list = findByStats(char, MANA_PATTERNS)
        if #list == 0 then
            Log.Write("HudStats: mana potion -> none (BG3 has no mana potions; ours comes later)")
            return
        end
        local okU, err = pcall(function() Osi.Use(char, list[1].item, "") end)
        Log.Write(string.format("HudStats: mana potion -> %s: Osi.Use %s", list[1].stats, okU and "ok" or ("ERROR " .. tostring(err))))
        send(true)
    end
end

function M.Register()
    Ext.RegisterNetListener(Net.Channels.UsePotion, function(_, payload, userId)
        local ok, p = pcall(Ext.Json.Parse, payload)
        if not ok or not p then return end
        local kind = p.kind == "mana" and "mana" or "health"
        ServerNet.EnqueueOsi(function() usePotion(userId, kind) end)
    end)
    Ext.Events.Tick:Subscribe(function()
        local t = now()
        if t - lastSent < PERIOD_MS then return end
        lastSent = t
        pcall(send)
    end)
    Log.Write("HudStats: registered (XP + potions to the HUD, R/T potions)")
end

return M
