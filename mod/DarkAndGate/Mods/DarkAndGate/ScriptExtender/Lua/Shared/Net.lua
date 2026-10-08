-- SPDX-License-Identifier: GPL-3.0-or-later
-- Shared net-channel registry.
--
-- Dark and Gate always runs as client/server, even in single player. Every
-- cross-state message goes through a named channel so there is exactly one
-- place to grep for the full wire protocol.
--
-- Channels are strings. The module UUID scopes them so other mods can't
-- cross-talk. Payloads are plain Lua tables; SE's Ext.Net serializes them.
--
-- Rule: client sends intents, server validates and (if needed) calls Osi.
-- Osi calls are never allowed inside restricted contexts (e.g. SessionLoaded),
-- so Server/Net.lua queues them to the next tick via Ext.OnNextTick.

local Net = {}

Net.MOD_UUID = "d5d298fd-ba29-4dc1-8346-6ac96b8c2cd7"

-- Channel names. Keep sorted and documented. Add here first; handlers go in
-- Server/Net.lua and Client/Net.lua.
Net.Channels = {
    -- Round-trip verification. Payload: { nonce: string, sentMs: int64 }.
    -- Server echoes with { nonce, sentMs, recvMs, replyMs }.
    Ping              = "DAG_Ping",
    PingReply         = "DAG_PingReply",

    -- Spike 5. Payload: { spell: string, fromUser: int, aim: {x,y,z}, targetUuid: string? }.
    -- Server resolves user â†’ character, then Osi.UseSpell on next tick.
    CastSpellRequest  = "DAG_CastSpellRequest",

    -- Spike 4. Payload: { animId: string, speed: number? }. Server plays the
    -- animation on the user's character via Osi.PlayAnimation.
    PlayAnimRequest   = "DAG_PlayAnimRequest",

    -- Spike 6. Payload: { targetUuid: string, direction: {x,y,z}, force: number }.
    -- Server lands the killing-blow push (status + impulse via Osi.ApplyStatus).
    RagdollPush       = "DAG_RagdollPush",

    -- Spike 7. Payload: { targetUuid: string, durationMs: int }.
    -- Server freezes the target by setting a short-lived timescale status.
    HitStopRequest    = "DAG_HitStopRequest",

    -- M1b melee. Payload: {
    --   weapon: string, swingIndex: int, swingNonce: int64,
    --   eye: {x,y,z}, forward: {x,y,z},
    --   targetUuid: string, hitPoint: {x,y,z}, hitZone: "head"|"torso"|"limbs",
    --   damage: number, reach: number
    -- }
    -- Server validates range + swing state, applies damage, replies via HitResult.
    HitClaim          = "DAG_HitClaim",
    HitResult         = "DAG_HitResult",

    -- M1b mana. Server broadcasts pool state. Payload: { max, current, regen }.
    ManaUpdate        = "DAG_ManaUpdate",
    -- Client requests a mana refill (debug only). Server echoes ManaUpdate.
    ManaRefill        = "DAG_ManaRefill",

    -- M1b combat intent. Payload: { targetUuid: string, kind: "melee"|"block" }.
    -- The server tracks combat state for the user and keeps real-time combat
    -- running (opposite of BG3's turn-based mode) when active.
    CombatIntent      = "DAG_CombatIntent",

    -- M1b debug: spawn a training dummy in front of the user.
    SpawnDummy        = "DAG_SpawnDummy",
}

-- Every channel both sides care about. Both server and client must register
-- all of these up front so a message never arrives at a side that hasn't
-- subscribed yet.
Net.AllChannels = {
    Net.Channels.Ping,
    Net.Channels.PingReply,
    Net.Channels.CastSpellRequest,
    Net.Channels.PlayAnimRequest,
    Net.Channels.RagdollPush,
    Net.Channels.HitStopRequest,
    Net.Channels.HitClaim,
    Net.Channels.HitResult,
    Net.Channels.ManaUpdate,
    Net.Channels.ManaRefill,
    Net.Channels.CombatIntent,
    Net.Channels.SpawnDummy,
}

return Net
