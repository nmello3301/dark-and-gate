-- SPDX-License-Identifier: GPL-3.0-or-later
-- Multiplayer, server side (docs/design/multiplayer.md). The server runs in
-- the host's process, so its own versions are the host's.
--   * MpHello -> MpWelcome (who you are, version check) + the join snapshot:
--     MpFeatures (kill switches), MpSettings (host rules), MpControl (your
--     character), your mana; MpRoster to everyone (player count).
--   * MpClock -> MpClockBack (each client's host-clock offset).
--   * MpControl whenever a player's controlled character changes.
--   * !dag_mp_feature <name> on|off (host only): kill switches, pushed to all.
--   * !dag_mp_status (MpStatusReq): every peer's versions, ping (probe round
--     trip), hello age, the host's net stats.
--   * Issue markers: MpNote from anyone (or !dag_note in the server console)
--     -> "#n", logged here with the host's state and the last 10 s of net
--     messages, and MpNoteMark to everyone (each logs its own state too).
-- Ids (SE v33): a net message's user id is peer << 16 (the host's client is
-- peer 1, 65536); Osiris uses the same id with index 1 (65537).

local Log            = Ext.Require("Shared/Log.lua")
local Net            = Ext.Require("Shared/Net.lua")
local Version        = Ext.Require("Shared/Version.lua")
local ServerNet      = Ext.Require("Server/Net.lua")
local Party          = Ext.Require("Server/Party.lua")
local MPState        = Ext.Require("Shared/MPState.lua")
local MPFeatures     = Ext.Require("Shared/MPFeatures.lua")
local NetHub         = Ext.Require("Shared/NetHub.lua")
local MeleeCooldown  = Ext.Require("Shared/MeleeCooldown.lua")
local ConsoleForward = Ext.Require("Shared/ConsoleForward.lua")
local Mana           = Ext.Require("Server/Combat/Mana.lua")

local M = {}

local PROBE_WAIT_MS = 700

local peers = {}          -- net user id -> { user, peer, osi, versions, helloAt, character, name, must, warn, rtt, hostPeer }
local probes = {}         -- probe id -> { user, at }
local probeSeq = 0
local noteSeq = 0

local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) or 0 end
local function peerOf(user) return (tonumber(user) or 0) >> 16 end
local function list(t) return (t and #t > 0) and table.concat(t, ", ") or "none" end

local function send(user, channel, payload)
    pcall(function() Ext.Net.PostMessageToUser(user, channel, Ext.Json.Stringify(payload)) end)
end
local function broadcast(channel, payload)
    pcall(function() Ext.Net.BroadcastMessage(channel, Ext.Json.Stringify(payload)) end)
end

local function nameOf(uuid)
    if not uuid then return "?" end
    local ok, n = pcall(function() return Osi.ResolveTranslatedString(Osi.GetDisplayName(uuid)) end)
    return (ok and n and n ~= "") and n or "?"
end

local function count()
    local n = 0
    for _ in pairs(peers) do n = n + 1 end
    return n
end

local function roster()
    local n = math.max(1, count())
    MPState.SetPeers(n)
    broadcast(Net.Channels.MpRoster, { peers = n })
end

-- The host's rules a joining player must use (MP-1 join snapshot).
local function settings()
    return { melee_cooldown = MeleeCooldown.Base() }
end

local function onHello(p, user)
    ServerNet.EnqueueOsi(function()
        local host = Version.Get()
        local cmp = Version.Compare(p, host)
        local character = Party.CharacterOfPeer(user)
        local fresh = peers[user] == nil
        local rec = peers[user] or {}
        rec.user, rec.peer, rec.osi = user, peerOf(user), Party.UserFromPeer(user)
        rec.versions, rec.helloAt = p, nowMs()
        rec.character, rec.name = character, nameOf(character)
        rec.must, rec.warn = cmp.must, cmp.warn
        rec.hostPeer = p.host_process == true or rec.peer == 1
        peers[user] = rec
        local text = nil
        if #cmp.must > 0 then
            text = string.format("Dark and Gate: your build differs from the host's (%s). Everyone needs the same mod and DLL build.", list(cmp.must))
        end
        Log.Write(string.format("MP: hello from p%d (user %d, Osiris %d%s), character %s (%s): %s -> %s",
            rec.peer, user, rec.osi, rec.hostPeer and ", the host's own client" or "", tostring(character), rec.name,
            Version.Line(p), #cmp.must > 0 and ("MISMATCH " .. list(cmp.must)) or ("matches the host" .. (#cmp.warn > 0 and (" (differs: " .. list(cmp.warn) .. ")") or ""))))
        send(user, Net.Channels.MpWelcome, {
            user = user, peer = rec.peer, osi_user = rec.osi, character = character,
            host = host, must = cmp.must, warn = cmp.warn, text = text,
        })
        -- Join snapshot: kill switches, host rules, your character, your mana.
        send(user, Net.Channels.MpFeatures, { features = MPFeatures.All() })
        send(user, Net.Channels.MpSettings, settings())
        if character then send(user, Net.Channels.MpControl, { uuid = character }) end
        pcall(Mana.Push, user, character)
        if fresh then roster() end
        -- The host hears about a mismatching player too.
        if #cmp.must > 0 and not rec.hostPeer then
            for u, q in pairs(peers) do
                if q.hostPeer then
                    send(u, Net.Channels.Toast, { text = string.format("Player p%d (%s) runs a different Dark and Gate build (%s)", rec.peer, rec.name, list(cmp.must)), secs = 10 })
                end
            end
        end
    end)
end

local function replyStatus(asker)
    ServerNet.EnqueueOsi(function()
        local out = {}
        local seen = {}
        for user, q in pairs(peers) do
            seen[q.osi or 0] = true
            out[#out + 1] = {
                user = user, peer = q.peer, host_peer = q.hostPeer, character = Party.CharacterOfPeer(user) or q.character,
                name = q.name, versions = q.versions, must = q.must, rtt_ms = q.rtt,
                hello_age_s = q.helloAt and math.floor((nowMs() - q.helloAt) / 1000) or nil,
            }
        end
        table.sort(out, function(a, b) return (a.peer or 0) < (b.peer or 0) end)
        local unknown = {}
        for _, uuid in ipairs(Party.Members()) do
            local u = Party.UserOf(uuid)
            if u and not seen[u] then unknown[#unknown + 1] = string.format("%s (Osiris user %d)", nameOf(uuid), u) end
        end
        send(asker, Net.Channels.MpStatus, { host = Version.Get(), peers = out, unknown = unknown,
            features = MPFeatures.All(), host_net = NetHub.StatsLines(5) })
        Log.Write(string.format("MP: status for p%d: %d peer(s)%s", peerOf(asker), #out,
            #unknown > 0 and ("; no hello from: " .. list(unknown)) or ""))
    end)
end

local function onStatusReq(asker)
    local t = nowMs()
    for user, q in pairs(peers) do
        probeSeq = probeSeq + 1
        probes[probeSeq] = { user = user, at = t }
        q.rtt = nil
        send(user, Net.Channels.MpProbe, { id = probeSeq })
    end
    local ok = pcall(function() Ext.Timer.WaitFor(PROBE_WAIT_MS, function() replyStatus(asker) end) end)
    if not ok then replyStatus(asker) end
end

local function onProbeBack(p, user)
    local pr = probes[tonumber(p.id) or -1]
    if not pr or pr.user ~= user then return end
    probes[p.id] = nil
    local q = peers[user]
    if q then q.rtt = math.floor(nowMs() - pr.at + 0.5) end
end

-- Kill switches (host only).
local function setFeature(name, v, who)
    if not MPFeatures.Known(name) then
        Log.Write("MP: !dag_mp_feature: unknown switch '" .. tostring(name) .. "' (" .. table.concat(MPFeatures.NAMES, ", ") .. ")")
        return
    end
    MPFeatures.Apply({ [name] = v })
    broadcast(Net.Channels.MpFeatures, { features = MPFeatures.All() })
    Log.Write(string.format("MP: feature %s %s by %s -> pushed to every player: %s", name, v and "ON" or "OFF", who, MPFeatures.Line()))
    broadcast(Net.Channels.Toast, { text = string.format("Host: %s %s", name, v and "on" or "OFF"), secs = 4 })
end

-- Issue markers.
local function mark(fromUser, text, reporterState)
    noteSeq = noteSeq + 1
    local n = noteSeq
    local peer = fromUser and peerOf(fromUser) or 1
    Log.Write(string.format("==== ISSUE #%d marked by p%d: %s ====", n, peer, tostring(text or "")))
    Log.Write("ISSUE #" .. n .. " host features: " .. MPFeatures.Line())
    for user, q in pairs(peers) do
        local c = Party.CharacterOfPeer(user)
        local pos = "?"
        pcall(function()
            local x, y, z = Osi.GetPosition(c)
            pos = string.format("(%.2f,%.2f,%.2f)", tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
        end)
        Log.Write(string.format("ISSUE #%d p%d %s %s at %s, ping %s ms", n, q.peer, tostring(c), q.name or "?", pos, tostring(q.rtt or "?")))
    end
    for _, l in ipairs(NetHub.StatsLines(10)) do Log.Write("ISSUE #" .. n .. " host " .. l) end
    for _, e in ipairs(NetHub.Recent(10)) do
        Log.Write(string.format("ISSUE #%d host net %s %s user=%s %dB %s", n, e.dir, e.ch, tostring(e.user), e.bytes, e.preview))
    end
    if reporterState then Log.Write("ISSUE #" .. n .. " reporter state: " .. tostring(reporterState)) end
    Log.Write(string.format("==== end of ISSUE #%d ====", n))
    broadcast(Net.Channels.MpNoteMark, { n = n, from = peer, text = text, t = nowMs() })
end

function M.Register()
    local function listen(channel, fn)
        Ext.RegisterNetListener(channel, function(_, payload, user)
            local ok, p = pcall(Ext.Json.Parse, payload)
            if ok and type(p) == "table" then
                local ok2, err = pcall(fn, p, user)
                if not ok2 then Log.Write("MP: handler error on " .. tostring(channel) .. ": " .. tostring(err)) end
            end
        end)
    end
    listen(Net.Channels.MpHello, onHello)
    listen(Net.Channels.MpStatusReq, function(_, user) onStatusReq(user) end)
    listen(Net.Channels.MpProbeBack, onProbeBack)
    listen(Net.Channels.MpClock, function(p, user) send(user, Net.Channels.MpClockBack, { tc = p.tc, ts = nowMs() }) end)
    listen(Net.Channels.MpNote, function(p, user) mark(user, p.text, p.state) end)
    -- Your controlled character, whenever it changes (Client/Me.lua).
    Party.OnControl(function(user, uuid)
        send(user, Net.Channels.MpControl, { uuid = uuid })
    end)
    ConsoleForward.Server("dag_mp_feature", function(_, name, v)
        local caller = ConsoleForward.Caller()
        if caller and peerOf(caller.peer) ~= 1 then
            Log.Write("MP: !dag_mp_feature from p" .. peerOf(caller.peer) .. " refused (host only)")
            if caller.peer then send(caller.peer, Net.Channels.Toast, { text = "Only the host can switch MP features", secs = 4 }) end
            return
        end
        if not name then Log.Write("MP: features: " .. MPFeatures.Line()); return end
        if v ~= "on" and v ~= "off" then Log.Write("MP: usage: !dag_mp_feature <name> on|off"); return end
        setFeature(name, v == "on", caller and ("p" .. peerOf(caller.peer)) or "the server console")
    end)
    ConsoleForward.Server("dag_note_srv", function(_, ...)
        mark(nil, table.concat({ ... }, " "), nil)
    end)
    pcall(function()
        Ext.Osiris.RegisterListener("UserConnected", 3, "after", function(user, name)
            Log.Write(string.format("MP: user %s (%s) connected", tostring(user), tostring(name)))
        end)
        Ext.Osiris.RegisterListener("UserDisconnected", 3, "after", function(user, name)
            local u = tonumber(user) or 0
            for k, q in pairs(peers) do
                if q.osi == u then peers[k] = nil end
            end
            Log.Write(string.format("MP: user %s (%s) disconnected", tostring(user), tostring(name)))
            roster()
        end)
    end)
    Log.Write("MP: server registered (handshake, snapshot, clock, features, issue markers, !dag_mp_status); host runs " .. Version.Line(Version.Get()))
end

-- Simulated peers in the smoke tests reach these directly.
M._peers = peers
M._mark = mark

return M
