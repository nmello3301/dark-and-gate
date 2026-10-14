-- SPDX-License-Identifier: GPL-3.0-or-later
-- Multiplayer, client side (docs/design/multiplayer.md):
--   * version handshake: after the session loads, say hello with this
--     machine's versions; the server answers who we are and whether we match
--     the host's build (a mismatch = a toast + a log line), then sends the
--     join snapshot: kill switches (MpFeatures), host rules (MpSettings), our
--     character (MpControl -> Client/Me.lua), our mana.
--   * roster (MpRoster): how many players are connected -> Shared/MPState
--     (every MP branch elsewhere is off while we're alone) and the DLL
--     (mp_remote: the host's server replays the others' direct movement).
--   * clock sync (MpClock): the host's clock offset, so host times line up.
--   * log tags: "[Client p2]", "[Native p2]" once the server has named us.
--   * !dag_mp_status: me, every peer (versions, ping), features, net stats.
--   * !dag_mp_lag <ms>: delay our own messages (Shared/NetHub.lua).
--   * issue marker: INSERT or !dag_note <text> -> "Issue #n marked" on every
--     player's screen; each machine logs its state and its last 10 s of
--     net messages under that number.
--   * !dag_mp_feature <name> on|off is forwarded to the server (host only).

local Log           = Ext.Require("Shared/Log.lua")
local Net           = Ext.Require("Shared/Net.lua")
local Version       = Ext.Require("Shared/Version.lua")
local FullPov       = Ext.Require("FullPov.lua")
local ClientNet     = Ext.Require("Client/Net.lua")
local Overlay       = Ext.Require("Client/HUD/Overlay.lua")
local Me            = Ext.Require("Client/Me.lua")
local MPState       = Ext.Require("Shared/MPState.lua")
local MPFeatures    = Ext.Require("Shared/MPFeatures.lua")
local NetHub        = Ext.Require("Shared/NetHub.lua")
local MeleeCooldown = Ext.Require("Shared/MeleeCooldown.lua")
local State         = Ext.Require("Client/Combat/State.lua")

local M = {}

local HELLO_RETRY_MS = 5000
local HELLO_TRIES = 12
local CLOCK_EVERY_MS = 10000
local NOTE_KEY = "INSERT"

local me = { welcomed = false, tries = 0, nextAt = 0, clockAt = 0, bestRtt = nil }

local function nowMs() return tonumber(Ext.Timer.MonotonicTime()) or 0 end

local function isHost()
    local ok, h = pcall(function() return Ext.Net.IsHost() end)
    return ok and h == true
end

local function list(t) return (t and #t > 0) and table.concat(t, ", ") or "none" end

local function hello()
    me.tries = me.tries + 1
    me.nextAt = nowMs() + HELLO_RETRY_MS
    local v = Version.Get()
    v.host_process = isHost()
    ClientNet.Send(Net.Channels.MpHello, v)
    if me.tries == 1 then Log.Write("MP: hello -> server: " .. Version.Line(v)) end
end

local function clockPing()
    me.clockAt = nowMs() + CLOCK_EVERY_MS
    ClientNet.Send(Net.Channels.MpClock, { tc = nowMs() })
end

local function onClockBack(p)
    local t = nowMs()
    local tc, ts = tonumber(p.tc), tonumber(p.ts)
    if not tc or not ts then return end
    local rtt = t - tc
    -- Keep the sample with the smallest round trip (least queueing noise).
    if me.bestRtt == nil or rtt <= me.bestRtt * 1.5 then
        me.bestRtt = me.bestRtt and math.min(me.bestRtt, rtt) or rtt
        local offset = ts + rtt / 2 - t
        local first = MPState.ClockOffset() == 0
        MPState.SetClockOffset(offset)
        if first then Log.Write(string.format("MP: clock synced: host offset %+.0f ms (round trip %.0f ms)", offset, rtt)) end
    end
    me.rtt = rtt
end

local function onWelcome(p)
    me.welcomed = true
    me.user, me.peer, me.osiUser, me.character = p.user, p.peer, p.osi_user, p.character
    MPState.SetMe(p.peer, p.osi_user)
    Me.SetServerCharacter(p.character)
    local tag = string.format("p%s%s", tostring(p.peer or "?"), isHost() and " host" or "")
    Log.SetTag(tag)
    FullPov.SetMpTag(tag)
    Log.Write(string.format("MP: welcome: user %s (peer %s, Osiris user %s), character %s; host runs %s",
        tostring(p.user), tostring(p.peer), tostring(p.osi_user), tostring(p.character), Version.Line(p.host)))
    local must, warn = p.must or {}, p.warn or {}
    if #must > 0 then
        local text = p.text or ("Dark and Gate: your build differs from the host's (" .. list(must) .. ")")
        Log.Write("MP: VERSION MISMATCH with the host: " .. list(must) .. (#warn > 0 and ("; also differs: " .. list(warn)) or ""))
        pcall(Overlay.Toast, text, 12)
    elseif #warn > 0 then
        Log.Write("MP: same build as the host; differs (warning only): " .. list(warn))
    else
        Log.Write("MP: same build as the host")
    end
    clockPing()
end

local function onStatus(p)
    local mine = Version.Get()
    Log.Write(string.format("MP status: I am user %s (peer %s%s), character %s (local %s); my versions: %s",
        tostring(me.user or "?"), tostring(me.peer or "?"), isHost() and ", host" or "",
        tostring(me.character or "?"), tostring(Me.Uuid()), Version.Line(mine)))
    Log.Write(string.format("MP status: %d player(s) connected, clock offset %+.0f ms, my round trip %s ms, lag sim %d ms",
        MPState.Peers(), MPState.ClockOffset(), tostring(me.rtt and math.floor(me.rtt) or "?"), NetHub.Lag()))
    Log.Write("MP status: host runs " .. Version.Line(p.host))
    for _, q in ipairs(p.peers or {}) do
        Log.Write(string.format("MP status:   p%s user %s %s, character %s (%s), ping %s, hello %s s ago%s: %s",
            tostring(q.peer), tostring(q.user), q.host_peer and "(host)" or "", tostring(q.character),
            tostring(q.name), q.rtt_ms and (q.rtt_ms .. " ms") or "?", tostring(q.hello_age_s),
            (q.must and #q.must > 0) and (" MISMATCH " .. list(q.must)) or "", Version.Line(q.versions)))
    end
    Log.Write("MP status: features " .. MPFeatures.Line())
    for _, l in ipairs(NetHub.StatsLines(5)) do Log.Write("MP status: mine " .. l) end
    for _, l in ipairs(p.host_net or {}) do Log.Write("MP status: host " .. l) end
    if p.unknown and #p.unknown > 0 then Log.Write("MP status: party members whose player never said hello (no mod?): " .. list(p.unknown)) end
end

-- My state for an issue marker (one line).
local function myState()
    local pos = "?"
    pcall(function()
        local t = Me.Entity().Transform.Transform.Translate
        pos = string.format("(%.2f,%.2f,%.2f)", t[1], t[2], t[3])
    end)
    return string.format("p%s %s at %s pov=%s jumping=%s scene=%s downed=%s lag=%d rtt=%s",
        tostring(me.peer or "?"), tostring(Me.Uuid()), pos, tostring(State.povOn), tostring(State.jumping),
        tostring(State.sceneOn), tostring(State.downed), NetHub.Lag(), tostring(me.rtt and math.floor(me.rtt) or "?"))
end

local function note(text)
    text = (text and text ~= "") and text or "(hotkey)"
    ClientNet.Send(Net.Channels.MpNote, { text = text, state = myState() })
    Log.Write("MP: issue marker asked: " .. text)
end

local function onNoteMark(p)
    local n = p.n or "?"
    Log.Write(string.format("==== ISSUE #%s marked by p%s: %s ====", tostring(n), tostring(p.from), tostring(p.text or "")))
    Log.Write("ISSUE #" .. tostring(n) .. " me: " .. myState())
    Log.Write("ISSUE #" .. tostring(n) .. " features: " .. MPFeatures.Line())
    for _, l in ipairs(NetHub.StatsLines(10)) do Log.Write("ISSUE #" .. tostring(n) .. " " .. l) end
    for _, e in ipairs(NetHub.Recent(10)) do
        Log.Write(string.format("ISSUE #%s net %s %s user=%s %dB %s", tostring(n), e.dir, e.ch, tostring(e.user), e.bytes, e.preview))
    end
    Log.Write(string.format("==== end of ISSUE #%s ====", tostring(n)))
    pcall(Overlay.Toast, string.format("Issue #%s marked (p%s%s)", tostring(n), tostring(p.from),
        (p.text and p.text ~= "(hotkey)") and (": " .. p.text) or ""), 4)
end

local function tick()
    local t = nowMs()
    if not me.welcomed and me.started and me.tries < HELLO_TRIES and t >= me.nextAt then hello() end
    if me.welcomed and t >= me.clockAt then clockPing() end
end

function M.Register()
    local function listen(channel, fn)
        Ext.RegisterNetListener(channel, function(_, payload)
            local ok, p = pcall(Ext.Json.Parse, payload)
            if ok and type(p) == "table" then
                local ok2, err = pcall(fn, p)
                if not ok2 then Log.Write("MP: handler error on " .. tostring(channel) .. ": " .. tostring(err)) end
            end
        end)
    end
    listen(Net.Channels.MpWelcome, onWelcome)
    listen(Net.Channels.MpStatus, onStatus)
    listen(Net.Channels.MpProbe, function(p) ClientNet.Send(Net.Channels.MpProbeBack, { id = p.id }) end)
    listen(Net.Channels.MpClockBack, onClockBack)
    listen(Net.Channels.MpRoster, function(p)
        local before = MPState.Peers()
        MPState.SetPeers(p.peers)
        FullPov.SetMpRemote(MPState.Multi())
        if before ~= MPState.Peers() then Log.Write(string.format("MP: %d player(s) connected", MPState.Peers())) end
    end)
    listen(Net.Channels.MpFeatures, function(p)
        local changed = MPFeatures.Apply(p.features)
        if #changed > 0 then Log.Write("MP: features from the host: " .. MPFeatures.Line()) end
    end)
    listen(Net.Channels.MpSettings, function(p)
        if p.melee_cooldown then MeleeCooldown.Set(p.melee_cooldown) end
        Log.Write(string.format("MP: host settings: melee cooldown %.2fs", MeleeCooldown.Base()))
    end)
    listen(Net.Channels.MpControl, function(p)
        Me.SetServerCharacter(p.uuid)
        me.character = p.uuid
        Log.Write("MP: you control " .. tostring(p.uuid) .. " (server)")
    end)
    listen(Net.Channels.MpNoteMark, onNoteMark)
    Ext.Events.SessionLoaded:Subscribe(function()
        me.started = true
        me.nextAt = nowMs() + 1000   -- let the server's listeners settle
    end)
    Ext.Events.Tick:Subscribe(function() pcall(tick) end)
    -- The issue hotkey (INSERT: unbound in BG3 and in our keys).
    Ext.Events.KeyInput:Subscribe(function(e)
        if tostring(e.Key) == NOTE_KEY and tostring(e.Event) == "KeyDown" and not e.Repeat then pcall(note, nil) end
    end)
    Ext.RegisterConsoleCommand("dag_note", function(_, ...)
        note(table.concat({ ... }, " "))
    end)
    Ext.RegisterConsoleCommand("dag_mp_status", function()
        if not me.welcomed then hello() end
        ClientNet.Send(Net.Channels.MpStatusReq, {})
        Log.Write("MP: status asked (the server pings every peer; the answer follows in about a second)")
    end)
    Ext.RegisterConsoleCommand("dag_mp_lag", function(_, ms)
        if tonumber(ms) then NetHub.SetLag(tonumber(ms)) end
        Log.Write(string.format("MP: simulated lag %d ms each way on this machine (0 = off)", NetHub.Lag()))
        pcall(Overlay.Toast, string.format("Simulated lag: %d ms", NetHub.Lag()), 3)
    end)
    Log.Write("MP: registered (handshake after load; INSERT / !dag_note marks an issue; !dag_mp_status; !dag_mp_lag; !dag_mp_feature)")
end

M._state = me

return M
