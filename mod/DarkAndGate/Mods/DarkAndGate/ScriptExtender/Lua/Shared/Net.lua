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
    -- Server echoes the result so client.log shows "Dummy: spawned ..." or
    -- "Dummy: no template matched; top candidates ...".
    SpawnDummyReply   = "DAG_SpawnDummyReply",

    -- First-person jump (visual lift). Client -> server: { durMs, h, k }.
    -- The server lifts the jumper's hitbox (Shared/Hitbox.lua) and relays
    -- JumpNotify { uuid, durMs, h, k } to every other client.
    -- Channelled casting: the client tells the server when a spell is
    -- armed / disarmed ({ spell = id | nil }); the server only accepts the
    -- cast once the spell's cast time has passed since the arm.
    SpellArm          = "DAG_SpellArm",
    JumpStart         = "DAG_JumpStart",
    JumpNotify        = "DAG_JumpNotify",

    -- Animation gallery (Server/AnimLib.lua). Client -> server:
    --   AnimLibSpawn { n, rig, template?, target?, fwd = {x,y,z} }
    --   AnimLibClear { why }
    -- Server -> client, one per copy: AnimLibSpawned { slot, uuid | error }.
    AnimLibSpawn      = "DAG_AnimLibSpawn",
    AnimLibSpawned    = "DAG_AnimLibSpawned",
    AnimLibClear      = "DAG_AnimLibClear",
    -- Client -> server: { uuid, name } -- rename a gallery copy after its clip.
    AnimLibName       = "DAG_AnimLibName",

    -- First-person HUD (Client/HUD/Hud.lua, Server/Combat/HudStats.lua).
    -- Client -> server: UsePotion { kind = "health"|"mana" } (R / T).
    -- Server -> clients, ~1 Hz: HudStats { uuid, xpCur, xpNext, level, hpPotions, manaPotions }.
    UsePotion         = "DAG_UsePotion",
    HudStats          = "DAG_HudStats",

    -- Projectile system v1 (Server/Combat/Projectiles.lua, docs/spikes/projectiles.md).
    -- Server -> clients: ProjectileLaunch { id, caster, spell, origin, vel, gravity, drag, radius, maxT }
    --                    ProjectileHit { id, pos, target?, what = "character"|"world"|"expired" }
    -- Client -> server: JumpLift { lift } -- the real jump's height above the
    -- take-off ground, ~15 Hz while airborne (the server can't see it).
    ProjectileLaunch  = "DAG_ProjectileLaunch",
    ProjectileHit     = "DAG_ProjectileHit",
    JumpLift          = "DAG_JumpLift",

    -- Real-time combat pass (2026-10-12, docs/playtest/realtime-combat.md).
    -- Client -> server: a server console command typed in the client
    -- console (Shared/ConsoleForward.lua). { cmd, args = { ... } }
    ServerCommand     = "DAG_ServerCommand",
    -- Server -> client(s): a short on-screen message (Client/HUD/Overlay.lua).
    -- { text, secs?, kind? }
    Toast             = "DAG_Toast",
    -- Downed / bleed-out / revive (Server/Combat/Downed.lua, Client/Downed.lua).
    -- Server -> clients: DownedState { uuid, name, state = "downed"|"up"|"dead",
    --   left = s, total = s, paused, reviver?, reviverName?, progress = 0..1 }
    -- Client -> server: ReviveHold { target, hold = true|false } (F held near a
    --   downed ally; false = F let go or another action cancels it).
    DownedState       = "DAG_DownedState",
    ReviveHold        = "DAG_ReviveHold",
    -- F interaction (Client/LookAt.lua + Client/Interact.lua, Server/Combat/Interact.lua).
    -- Client -> server: InteractClassify { target }  (what is this?)
    --                   InteractRequest  { target }  (F tapped on it)
    -- Server -> client: InteractInfo { target, kind, verb, name } (kind "none" = not interactive)
    --                   InteractResult { target, ok, how }
    InteractClassify  = "DAG_InteractClassify",
    InteractInfo      = "DAG_InteractInfo",
    InteractRequest   = "DAG_InteractRequest",
    InteractResult    = "DAG_InteractResult",
    -- Crouch = BG3 sneaking (Client/Crouch.lua, Server/Combat/Stealth.lua).
    -- Client -> server: CrouchToggle {}; server -> clients: CrouchState { uuid, on }.
    CrouchToggle      = "DAG_CrouchToggle",
    CrouchState       = "DAG_CrouchState",
    -- V companion mode (Server/Companions.lua). Client -> server: CompanionMode {}.
    CompanionMode     = "DAG_CompanionMode",
    -- Teleport / fast travel: server -> the owning client, re-settle first
    -- person (FullPov). { why }
    PovSettle         = "DAG_PovSettle",
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
    Net.Channels.SpawnDummyReply,
    Net.Channels.SpellArm,
    Net.Channels.JumpStart,
    Net.Channels.JumpNotify,
    Net.Channels.AnimLibSpawn,
    Net.Channels.AnimLibSpawned,
    Net.Channels.AnimLibClear,
    Net.Channels.AnimLibName,
    Net.Channels.UsePotion,
    Net.Channels.HudStats,
    Net.Channels.ProjectileLaunch,
    Net.Channels.ProjectileHit,
    Net.Channels.JumpLift,
    Net.Channels.ServerCommand,
    Net.Channels.Toast,
    Net.Channels.DownedState,
    Net.Channels.ReviveHold,
    Net.Channels.InteractClassify,
    Net.Channels.InteractInfo,
    Net.Channels.InteractRequest,
    Net.Channels.InteractResult,
    Net.Channels.CrouchToggle,
    Net.Channels.CrouchState,
    Net.Channels.CompanionMode,
    Net.Channels.PovSettle,
}

return Net
