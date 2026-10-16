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
    -- Multiplayer MP-0 (Client/MP.lua, Server/MP.lua, docs/design/multiplayer.md):
    -- MpHello     client -> server  this machine's versions (Shared/Version.lua)
    -- MpWelcome   server -> client  { user, peer, osi_user, character, host
    --             = host versions, must = {keys}, warn = {keys}, text }
    -- MpStatusReq client -> server  {}  (!dag_mp_status)
    -- MpStatus    server -> client  { peers = {...}, host = versions }
    -- MpProbe     server -> client  { id }, answered with MpProbeBack { id }:
    --             the round trip the server measures for each peer's ping.
    MpHello           = "DAG_MpHello",
    MpWelcome         = "DAG_MpWelcome",
    MpStatusReq       = "DAG_MpStatusReq",
    MpStatus          = "DAG_MpStatus",
    MpProbe           = "DAG_MpProbe",
    MpProbeBack       = "DAG_MpProbeBack",
    -- MP-1..MP-4:
    -- MpFeatures  server -> all     { features = {name = bool} } (kill switches)
    -- MpRoster    server -> all     { peers = n } (connected players)
    -- MpClock     client -> server  { tc } ; MpClockBack { tc, ts } (clock sync)
    -- MpControl   server -> client  { uuid } the character you control now
    -- MpSettings  server -> client  { melee_cooldown, ... } host rules (join snapshot)
    -- MpNote      client -> server  { text, state } issue marker request
    -- MpNoteMark  server -> all     { n, from, text, t, state } "Issue #n marked"
    MpFeatures        = "DAG_MpFeatures",
    MpRoster          = "DAG_MpRoster",
    MpClock           = "DAG_MpClock",
    MpClockBack       = "DAG_MpClockBack",
    MpControl         = "DAG_MpControl",
    MpSettings        = "DAG_MpSettings",
    MpNote            = "DAG_MpNote",
    MpNoteMark        = "DAG_MpNoteMark",

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
    --   left = s, total = s, paused, reviver?, reviverName?, progress = 0..1,
    --   standing = party members still on their feet }
    -- Client -> server: ReviveHold { target, hold = true|false } (F held near a
    --   downed ally; false = F let go or another action cancels it).
    DownedState       = "DAG_DownedState",
    ReviveHold        = "DAG_ReviveHold",
    -- Give up, offered while nobody in the party stands (the downed screen's
    -- button / G). Client -> server: GiveUp { uuid } (the client's downed or
    -- dead character). Server -> that client: GiveUpReply { ok, waiting?, text }
    -- (waiting = other players still have to give up). Server -> clients:
    -- GameOver { by } (BG3's game-over screen is up: our HUD and first person
    -- stand aside).
    GiveUp            = "DAG_GiveUp",
    GiveUpReply       = "DAG_GiveUpReply",
    GameOver          = "DAG_GameOver",
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

    -- Bows (Client/Combat/Bow.lua, Server/Combat/Bows.lua, data/bows.lua).
    -- Client -> server: BowDraw { on = true } (LMB down: the draw starts) /
    --                   { on = false, why } (cancelled)
    --                   BowRelease { eye, dir, hitPoint, targetUuid?, draw = 0..1 }
    --                   WeaponSetToggle {} (Q: BG3's own key press didn't switch it)
    -- Server -> client(s): RangedState { uuid, set = "Melee"|"Ranged", kind =
    --                   "bow"|"crossbow"|nil, family, drawS, reloadS } (the owner)
    --                   BowAnim { uuid, phase = "draw"|"release"|"cancel", drawS }
    --                   (everyone: play / end the draw on that character)
    BowDraw           = "DAG_BowDraw",
    BowRelease        = "DAG_BowRelease",
    WeaponSetToggle   = "DAG_WeaponSetToggle",
    RangedState       = "DAG_RangedState",
    BowAnim           = "DAG_BowAnim",
    -- Server -> the client that pressed F: a chest / corpse loot window opened
    -- or closed (Osiris Closed). { open, target, name?, why? }
    ContainerUI       = "DAG_ContainerUI",
    -- WASD in fights, server fallback (Client/Movement/CombatMove.lua ->
    -- Server/Combat/CombatMove.lua). Client -> server: CombatMove
    -- { on, dx, dz, gait = "Walk"|"Run", why }; server -> that client:
    -- CombatMoveState { refused?, why } (refused = not in a fight); to every
    -- client: CombatMoveState { fight = true|false } when a real-time fight
    -- starts / ends.
    CombatMove        = "DAG_CombatMove",
    CombatMoveState   = "DAG_CombatMoveState",
    -- !dag_play (Client/PlayMode.lua, Server/PlayMode.lua). Client -> server:
    -- PlayMode { on } at session start and when typed; server -> that client
    -- (and to every client at each level start): PlayReady { level, cc }
    -- (cc = character creation: first person waits).
    PlayMode          = "DAG_PlayMode",
    PlayReady         = "DAG_PlayReady",
    -- Server -> clients: a dialogue / cutscene runs or ended (Server/Scene.lua):
    -- Scene { on }. Our HUD, input and first person stand aside while on.
    Scene             = "DAG_Scene",
    -- Movement-feel metrics (!dag_move_metrics: Client/Movement/MoveMetrics.lua,
    -- Server/MoveProbe.lua). Client -> server: MoveProbeReq { on }; server ->
    -- that client every 50 ms while on: MoveProbe { x, y, z } (the server's
    -- own position of the client's character), to measure client/server drift.
    MoveProbeReq      = "DAG_MoveProbeReq",
    MoveProbe         = "DAG_MoveProbe",
    -- Meta-Points (Server/MetaPoints.lua, Client/MetaPoints.lua). Client ->
    -- server: MetaQuery { uuid? } (no uuid = config + the whole party),
    -- MetaConfirm { uuid, spent }, MetaRespec { uuid }. Server -> clients:
    -- MetaConfig { config }, MetaState { uuid, name, level, spent, bonus,
    -- total, unspent, inCamp, respec, respecWhy, owner }, MetaNotify { uuid,
    -- name, unspent, level } (a level-up brought points to spend).
    MetaQuery         = "DAG_MetaQuery",
    MetaConfirm       = "DAG_MetaConfirm",
    MetaRespec        = "DAG_MetaRespec",
    MetaConfig        = "DAG_MetaConfig",
    MetaState         = "DAG_MetaState",
    MetaNotify        = "DAG_MetaNotify",
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
    Net.Channels.GiveUp,
    Net.Channels.GiveUpReply,
    Net.Channels.GameOver,
    Net.Channels.InteractClassify,
    Net.Channels.InteractInfo,
    Net.Channels.InteractRequest,
    Net.Channels.InteractResult,
    Net.Channels.CrouchToggle,
    Net.Channels.CrouchState,
    Net.Channels.CompanionMode,
    Net.Channels.PovSettle,
    Net.Channels.BowDraw,
    Net.Channels.BowRelease,
    Net.Channels.WeaponSetToggle,
    Net.Channels.RangedState,
    Net.Channels.BowAnim,
    Net.Channels.ContainerUI,
    Net.Channels.CombatMove,
    Net.Channels.CombatMoveState,
    Net.Channels.PlayMode,
    Net.Channels.PlayReady,
    Net.Channels.Scene,
    Net.Channels.MoveProbeReq,
    Net.Channels.MoveProbe,
    Net.Channels.MpHello,
    Net.Channels.MpWelcome,
    Net.Channels.MpStatusReq,
    Net.Channels.MpStatus,
    Net.Channels.MpProbe,
    Net.Channels.MpProbeBack,
    Net.Channels.MpFeatures,
    Net.Channels.MpRoster,
    Net.Channels.MpClock,
    Net.Channels.MpClockBack,
    Net.Channels.MpControl,
    Net.Channels.MpSettings,
    Net.Channels.MpNote,
    Net.Channels.MpNoteMark,
    Net.Channels.MetaQuery,
    Net.Channels.MetaConfirm,
    Net.Channels.MetaRespec,
    Net.Channels.MetaConfig,
    Net.Channels.MetaState,
    Net.Channels.MetaNotify,
}

return Net
