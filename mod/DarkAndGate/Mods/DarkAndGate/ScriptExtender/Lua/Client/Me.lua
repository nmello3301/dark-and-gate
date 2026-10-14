-- SPDX-License-Identifier: GPL-3.0-or-later
-- The local player's controlled character on this client (multiplayer MP-1,
-- docs/design/multiplayer.md blocker B3).
--
-- In co-op a client can see ClientControl on OTHER players' characters too,
-- so "GetAllEntitiesWithComponent("ClientControl")[1]" may be someone else.
-- The local one, in order of trust:
--   1. the character the server says we control (MpWelcome / MpControl,
--      Client/MP.lua -> Me.SetServerCharacter), if it has ClientControl here;
--   2. ClientCharacter.ReservedUserID == 1 (SE's own _C()) or
--      UserReservedFor.UserID == 1 (Brawl);
--   3. the first ClientControl entity (the old rule; single player has one).
--
--   Me.All()     ClientControl entities, the local character first: a drop-in
--                for GetAllEntitiesWithComponent("ClientControl")
--   Me.Entity()  the local character's entity (or nil)
--   Me.Uuid()    its uuid

local M = {}

local serverUuid = nil

local function uuidOf(e)
    local ok, u = pcall(function() return e.Uuid.EntityUuid end)
    return ok and u or nil
end

local function isLocal(e)
    local ok, yes = pcall(function()
        local cc = e.ClientCharacter
        if cc and tonumber(cc.ReservedUserID) == 1 then return true end
        local ur = e.UserReservedFor
        if ur and tonumber(ur.UserID) == 1 then return true end
        return false
    end)
    return ok and yes
end

function M.SetServerCharacter(uuid)
    serverUuid = (uuid and uuid ~= "") and tostring(uuid) or nil
end
function M.ServerCharacter() return serverUuid end

function M.All()
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    if not ok or type(ents) ~= "table" then return {} end
    if #ents <= 1 then return ents end
    local pick = nil
    if serverUuid then
        for i, e in ipairs(ents) do
            if uuidOf(e) == serverUuid then pick = i; break end
        end
    end
    if not pick then
        for i, e in ipairs(ents) do
            if isLocal(e) then pick = i; break end
        end
    end
    if not pick or pick == 1 then return ents end
    local out = { ents[pick] }
    for i, e in ipairs(ents) do if i ~= pick then out[#out + 1] = e end end
    return out
end

function M.Entity() return M.All()[1] end

function M.Uuid()
    local e = M.Entity()
    return e and uuidOf(e) or nil
end

return M
