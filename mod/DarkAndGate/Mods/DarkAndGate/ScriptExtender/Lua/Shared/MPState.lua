-- SPDX-License-Identifier: GPL-3.0-or-later
-- Multiplayer state any module can read (filled by Client/MP.lua on a
-- client, Server/MP.lua on the host). Single player: Multi() is false and
-- every MP branch elsewhere is a no-op.
--
--   MPState.Multi()        more than one player connected (known from the
--                          server's roster; false until it says otherwise)
--   MPState.Peers()        number of connected players
--   MPState.MyPeer()       this client's peer number (1 = host), nil before
--                          the welcome
--   MPState.MyOsiUser()    this client's Osiris user id, nil before the welcome
--   MPState.HostNow()      the host's clock (ms), from the clock sync (on the
--                          host itself: the local clock)
--   MPState.ToLocal(t)     a host time -> this machine's clock

local M = {}

local S = { peers = 1, myPeer = nil, myOsi = nil, offset = 0 }

local function now() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

function M.Multi() return (S.peers or 1) > 1 end
function M.Peers() return S.peers or 1 end
function M.MyPeer() return S.myPeer end
function M.MyOsiUser() return S.myOsi end
function M.ClockOffset() return S.offset or 0 end
function M.HostNow() return now() + (S.offset or 0) end
function M.ToLocal(t) return (tonumber(t) or 0) - (S.offset or 0) end

function M.SetPeers(n) S.peers = math.max(1, tonumber(n) or 1) end
function M.SetMe(peer, osiUser) S.myPeer, S.myOsi = peer, osiUser end
function M.SetClockOffset(ms) S.offset = tonumber(ms) or 0 end

return M
