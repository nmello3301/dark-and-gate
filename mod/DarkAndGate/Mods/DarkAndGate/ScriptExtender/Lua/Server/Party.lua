-- SPDX-License-Identifier: GPL-3.0-or-later
-- Who is in the party and who controls whom (server).
--
--   Party.Norm(guid)            "Name_<uuid>" or "<uuid>" -> "<uuid>"
--   Party.Members()             party member uuids (Osiris DB_Players)
--   Party.IsMember(uuid)
--   Party.UserOf(uuid)          the Osiris user a party member is reserved for
--   Party.Controlled(user)      the character that user controls right now
--   Party.IsControlled(uuid)    some player controls it directly (it is not
--                               on companion AI)
--   Party.CompanionsOf(user)    party members reserved for that user that
--                               they don't control right now
--   Party.UserFromPeer(peer)    net-message user id -> Osiris user id
--                               ((peer & 0xffff0000) | 1, SE docs; Brawl uses it)
--   Party.CharacterOfPeer(peer) the character a net message's sender controls
--   Party.OnControl(fn)         fn(user, uuid, previous uuid) after each change
--
-- Control is tracked from Osiris GainedControl (Brawl does the same), then
-- Osi.GetCurrentCharacter(user). Only the HOST's user falls back to the host
-- character (single player: exactly as before); any other user with no
-- known character gets nil, so a remote player's request is dropped instead
-- of acting on the host's character (multiplayer MP-1, blocker B1/B2 in
-- docs/design/multiplayer.md).
--   Party.Users()               Osiris user ids of the players in the party
--   Party.HostUser()            the host's Osiris user id

local M = {}

local controlled = {}   -- Osiris user id -> uuid
local userCache = { at = -1e9, list = {} }
local controlHooks = {} -- OnControl listeners (Server/Combat/Downed.lua)
local memberCache = { at = -1e9, list = {}, set = {} }

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

function M.Norm(g)
    if g == nil then return nil end
    g = tostring(g)
    return g:match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$") or g
end

-- Character creation (a new game's first screen): our systems stay out of it
-- (playtest 2026-10-13: BG3 crashed in character creation, a pure virtual
-- call in its UI update).
function M.InCharacterCreation()
    local cc = false
    pcall(function()
        local lvl = Osi.GetRegion(Osi.GetHostCharacter())
        cc = lvl ~= nil and lvl ~= "" and tonumber(Osi.IsCharacterCreationLevel(lvl)) == 1
    end)
    return cc
end

function M.UserFromPeer(peer)
    peer = tonumber(peer) or 0
    return (peer & 0xffff0000) | 0x0001
end

function M.Members()
    local t = now()
    if t - memberCache.at < 1000 then return memberCache.list end
    local list, set = {}, {}
    pcall(function()
        for _, row in pairs(Osi.DB_Players:Get(nil) or {}) do
            local u = M.Norm(row[1])
            if u and not set[u] then set[u] = true; list[#list + 1] = u end
        end
    end)
    memberCache.at, memberCache.list, memberCache.set = t, list, set
    return list
end

function M.IsMember(uuid)
    M.Members()
    return memberCache.set[M.Norm(uuid)] == true
end

function M.UserOf(uuid)
    local ok, u = pcall(function() return Osi.GetReservedUserID(uuid) end)
    return ok and tonumber(u) or nil
end

local function host()
    local ok, h = pcall(function() return Osi.GetHostCharacter() end)
    return ok and M.Norm(h) or nil
end

function M.HostUser()
    local h = host()
    return h and M.UserOf(h) or nil
end

-- Every player's Osiris user (deduplicated reserved users of the party).
function M.Users()
    local t = now()
    if t - userCache.at < 1000 then return userCache.list end
    local set, list = {}, {}
    for _, u in ipairs(M.Members()) do
        local id = M.UserOf(u)
        if id and id > 0 and not set[id] then set[id] = true; list[#list + 1] = id end
    end
    local hu = M.HostUser()
    if hu and not set[hu] then list[#list + 1] = hu end
    userCache.at, userCache.list = t, list
    return list
end

function M.Controlled(user)
    if user and controlled[user] then return controlled[user] end
    if user then
        local ok, c = pcall(function() return Osi.GetCurrentCharacter(user) end)
        if ok and c and c ~= "" then return M.Norm(c) end
    end
    -- Only the host's own user falls back to the host character.
    if user == nil or user == M.HostUser() then return host() end
    return nil
end

function M.IsControlled(uuid)
    uuid = M.Norm(uuid)
    if not uuid then return false end
    for _, user in ipairs(M.Users()) do
        if M.Controlled(user) == uuid then return true end
    end
    return false
end

function M.CompanionsOf(user)
    local out = {}
    for _, u in ipairs(M.Members()) do
        if not M.IsControlled(u) and (user == nil or M.UserOf(u) == user) then out[#out + 1] = u end
    end
    return out
end

-- The character the sender of a net message controls (the host's own
-- messages fall back to the host character; anyone else's to nil).
function M.CharacterOfPeer(peer)
    return M.Controlled(M.UserFromPeer(peer))
end

function M.OnControl(fn) controlHooks[#controlHooks + 1] = fn end

function M.Register()
    Ext.Osiris.RegisterListener("GainedControl", 1, "after", function(target)
        local uuid = M.Norm(target)
        local user = M.UserOf(uuid)
        if not user then return end
        local prev = controlled[user]
        if prev == nil then
            -- No event yet this session: the host's user was on the host character.
            local h = host()
            if h and M.UserOf(h) == user then prev = h end
        end
        controlled[user] = uuid
        if prev ~= uuid then
            for _, fn in ipairs(controlHooks) do pcall(fn, user, uuid, prev) end
        end
    end)
    Ext.Osiris.RegisterListener("CharacterJoinedParty", 1, "after", function() memberCache.at = -1e9; userCache.at = -1e9 end)
    Ext.Osiris.RegisterListener("CharacterLeftParty", 1, "after", function() memberCache.at = -1e9; userCache.at = -1e9 end)
    Ext.Osiris.RegisterListener("CharacterReservedUserIDChanged", 3, "after", function() userCache.at = -1e9 end)
    Ext.Osiris.RegisterListener("UserDisconnected", 3, "after", function(user)
        local u = tonumber(user)
        if u then controlled[u] = nil end
        userCache.at = -1e9
    end)
end

return M
