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
--
-- Control is tracked from Osiris GainedControl (Brawl does the same); before
-- the first event the host character counts as controlled.

local M = {}

local controlled = {}   -- Osiris user id -> uuid
local memberCache = { at = -1e9, list = {}, set = {} }

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

function M.Norm(g)
    if g == nil then return nil end
    g = tostring(g)
    return g:match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$") or g
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

function M.Controlled(user)
    if user and controlled[user] then return controlled[user] end
    if user then
        local ok, c = pcall(function() return Osi.GetCurrentCharacter(user) end)
        if ok and c and c ~= "" then return M.Norm(c) end
    end
    return host()
end

function M.IsControlled(uuid)
    uuid = M.Norm(uuid)
    if not uuid then return false end
    local any = false
    for _, c in pairs(controlled) do
        any = true
        if c == uuid then return true end
    end
    if not any then return uuid == host() end
    return false
end

function M.CompanionsOf(user)
    local out = {}
    for _, u in ipairs(M.Members()) do
        if not M.IsControlled(u) and (user == nil or M.UserOf(u) == user) then out[#out + 1] = u end
    end
    return out
end

-- The character the sender of a net message controls (falls back to the host).
function M.CharacterOfPeer(peer)
    return M.Controlled(M.UserFromPeer(peer))
end

function M.Register()
    Ext.Osiris.RegisterListener("GainedControl", 1, "after", function(target)
        local uuid = M.Norm(target)
        local user = M.UserOf(uuid)
        if user then controlled[user] = uuid end
    end)
    Ext.Osiris.RegisterListener("CharacterJoinedParty", 1, "after", function() memberCache.at = -1e9 end)
    Ext.Osiris.RegisterListener("CharacterLeftParty", 1, "after", function() memberCache.at = -1e9 end)
end

return M
