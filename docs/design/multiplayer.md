# Multiplayer (co-op)

**Status:** MP-0 (research + architecture + diagnostics), started 2026-10-13.
**Decision** (DECISIONS 2026-10-13): "Multiplayer moved up: it touches every system, so it's cheaper to build now than retrofit later. Gate 1 / Pass D follow after MP-2."

**Goals:**
- co-op must feel like single-player for EVERY player, not just the host;
- it must work with Party Limit Begone (16 party members, 8 players, including its exe patch).

## Design principles

**P1 Same feel as single-player.** Anything the player feels runs on their own machine with zero wait:
- camera, movement, jump, crouch, aim;
- their own swing start + clip + rate;
- cast stages and the cast bar;
- bow draw and release;
- their own arrow / projectile visual from the moment they fire;
- hotbar, HUD, and the mana display (predicted).

**P2 The host decides outcomes.**
- Damage, hits, mana spend, statuses, downed / revive, stealth checks, enemy AI, the real-time combat loop.
- Clients send intents ("swung chain step 2 at t, aim ray X", "released Fire Bolt, dir Y") and never results.
- The host validates every message (sender = the character's owner, range, cooldown, mana, line of sight) and never trusts a client-named target or damage number.
- Lag tolerance in hit validation: see [Lag tolerance](#lag-tolerance).
- Rejections are rare and visible only as "no damage", never as a snap-back of the player's own animation or camera.

**P3 Engine sync first.**
- If BG3 already shows something to all players when the host triggers it (statuses, damage, server-side animations, the controller-mode movement path, deaths, loot), use that.
- Our own broadcast messages are only for what the DLL / client Lua drives locally (jump arc, play-rate, cast stages, swing clips, projectile steering, the bow draw freeze).
- The [audit table](#3-audit-table) says which bucket each system is in.

**P4 No "4" anywhere.**
- Up to 8 players and 16 party members (Party Limit Begone).
- No fixed-size arrays, party-index assumptions or 4-slot lists in Lua, the DLL, the HUD, the V cycle, spectate, revive priority, Brawl or net code.
- Each player's companions follow that player's V-cycle orders.

**P5 Test as the client.** Every MP playtest step is done from the JOINING player's machine first (the host has zero latency and hides bugs), then repeated as the host.

---

## 1. How BG3 co-op works for us

Sources: SE v33 source and docs (`reference/bg3se`), Brawl and MCM (both used in co-op), our own notes ([se-api-notes.md](../se-api-notes.md), [spikes/real-lift.md](../spikes/real-lift.md)). Web facts are marked *(web)* and are unverified until a playtest shows them.

### Who runs what

| Machine | Runs |
| --- | --- |
| Host | The server (`esv`, Osiris, **all our server Lua**), its own client (`ecl`, client Lua) and our DLL. The game can't run without the host; only the host saves and loads *(web: bg3.wiki/Multiplayer)*. |
| Every other player | Their client (`ecl`, client Lua) and our DLL. No server Lua. |

The DLL is per machine, and so is every file it reads or writes (`%LOCALAPPDATA%\…\Script Extender\DarkAndGate\`). Two game instances under one Windows account would share those files and break each other; see [Test setup](#6-test-setup).

### User ids, peers and characters

- **A net message's user id is `peer << 16`.** The host's own client is peer 1, so it sends as **65536**; the second player sends as 131072, and so on. SE: `UserId = (peerId << 16) | userIndex`, with index 0 on net messages (`CoreLib/Base/BaseTypes.h:72-104`).
- **Osiris uses the same id with index 1**: the host is **65537**. Convert with `(u & 0xffff0000) | 1`; ours is `Party.UserFromPeer`, and Brawl and MCM do the same.
- **Server, user → character:**
  - `Osi.GetCurrentCharacter(osiUser)`;
  - `GainedControl` / `CharacterReservedUserIDChanged`;
  - `UserReservedFor.UserID`, `ServerCharacter.UserID`;
  - `DB_Players` (every party member), `DB_Avatars`.
  
  Join and leave: Osiris `UserConnected` / `UserDisconnected(user, name, profile)`.
- **Client, which character is mine:**
  - `ClientControl` can sit on **other players'** characters too.
  - The local player's is the one with `ClientCharacter.ReservedUserID == 1` (SE's own `_C()`) or `UserReservedFor.UserID == 1` (Brawl).
  - `ClientControl` also lags behind control changes. Brawl therefore has the server push each user's controlled character to that user.
  - **Ours:** about 25 client files take `GetAllEntitiesWithComponent("ClientControl")[1]`, which can be another player's character.
- **The DLL must drive only the local player's character:**

  | DLL part | How it picks the character | In co-op |
  | --- | --- | --- |
  | MoveFeel (direct WASD), RealJump | the character of the local client's MoveController / MoveSpeed template call (local input only) | right by construction |
  | Pov (head anchor), VisualLift, AnimRate | addresses Lua takes from `ClientControl[1]` | must come from the filtered local character |
  | Camera | latches onto the camera that looks at Lua's ground-truth position | follows whatever Lua says |

### Messaging (`Ext.Net`, SE v33)

- **Client → server:** `PostMessageToServer`. The listener gets `(channel, payload, userId)`; **the user id comes from SE, not the payload**.
- **Server → one player:** `PostMessageToUser(userId)` (net or Osiris id; only the peer bits are used), or `PostMessageToClient(characterGuid)`.
- **Server → all:** `BroadcastMessage`.
  - It **includes the host's own client**.
  - It can exclude only by a character GUID.
  - It skips peers that are still loading.
- **Channels:** we use the legacy `RegisterNetListener`. `Ext.Net.CreateChannel` is the newer API and gives the same user id, so there's no need to switch.
- **Missing APIs:** there's no peer list and no ping. Our handshake keeps the peer table, and the server measures ping with its own probe round trip (`!dag_mp_status`).
- **`Ext.Net.IsHost()`** is true on the host's client.

### What replicates for free, and what doesn't

| Replicates (host server changes it → every client sees it) | Does not replicate |
| --- | --- |
| HP and damage, statuses, deaths, loot, items (server-authoritative; Brawl relies on it) | Anything the DLL writes: the real jump's arc while we steer it, play rates, direct transform writes |
| A player-driven character's movement: the owning client reports its path, and the server replays it (MSMoveToSync) and sends it on (`CHARACTER_UPDATE`) | Client Lua visuals: prepare VFX, our casting animations through genome events, the bow draw freeze, our jump clips' play rate |
| A falling state's start (message 0xCC), so others see a **vanilla parabola**, not our steered curve | The visual lift (old jump mode) |
| Steering / facing (message 0x24): our body-follows-camera turn goes through BG3's steering, so it syncs | Edits to a projectile's path after launch (our server flight is ours; its visual clone is broadcast by us) |
| Server-side `Osi.PlayAnimation`, `PlayEffect…` (unverified for MP; the NPC draw clips play on every client) | RenderPasses / head hiding (local by design) |
| `Ext.Vars` with `SyncToClient`, `Entity:Replicate()` | |

### Co-op game rules that touch us

| Topic | BG3 *(web, unverified)* | What it means for us |
| --- | --- | --- |
| Dialogue | Others keep playing and may opt in to listen. Some cinematic dialogues need everyone present. Osiris: `DialogGetNumberOfInvolvedPlayers` / `DialogGetInvolvedPlayer`. | Our scene flag is global today (`Server/Scene.lua` broadcasts it; every player's first person stands aside). It must go per involved player. |
| Map / fast travel | Not confirmed who can travel or whether it moves every player. | `PovSettle` is already per character. To check in MP-3. |
| Camp / long rest | The whole party goes to camp; it fails if anyone can't make the trip. | V "go to camp" is per player's companions. |
| Pausing / turn-based | Turn-based freezes what is "in combat-range proximity of the character(s)". | Real-time fights never pause; a player's menu doesn't pause anyone. |
| Players | 4 in vanilla. Late joiners make custom characters. Each companion is controlled by one player. | P4: up to 8 with PLB. |
| Joining | Steam invite, the LAN tab, or Direct Connect by code; port 23253. | Players 5–8 join by LAN or the host's IP (below). |

---

## 2. Party Limit Begone compatibility

**What it is.** "Party Limit Begone" by Sildur, Nexus mod 327 (v3.5, 2026-03-28): "Increases the party limit to 16 members and multiplayer limit to 8 players!"

| File | What it is | For us |
| --- | --- | --- |
| Standalone v3.5 | `meta.lsx` overrides dropped into the game's **`Data`** folder | **Not on the dev machine**: hard rule 1 (never modify the game install). Every player uses the SE version instead. |
| **SE v3.5** | `PartyLimitBegone.pak` in the Mods folder (Patch 8 Hotfix 36/37). "Everyone needs this to prevent mismatch errors." | The one we use. Removing it: `Osi.SetMaxPartySizeOverride(4)`, then `Osi.PROC_CheckPartyFull()`. |
| SE-Universal v1.1 | any game patch | "Does not support the MP patch." |
| **Multiplayer Patch v1.6** (2025-10-05) | `PartyLimitBegonePatcher.bat` runs the hex editor XVI32 with the script `PatchFiles/PLB-MP-Patch.xsc` (552 bytes) on a dragged-in `bg3.exe` or `bg3_dx11.exe`. It patches in place and leaves `*.exe.backup`. Must be re-applied after every game update. | Since v1.4, "clients will also need this patch" to manage characters past 4, so **every player** runs a patched exe. Only Hotfix 36/37 is listed. |

**Known issues that touch us:**
- "Some ingame events are simply hardcoded for 4 party members and will glitch out" (dismissing extras or teleporting fixes it).
- Quest items carried by member 5+ aren't registered.
- The Grymforge boat needs 4 or fewer.
- A camp sleeping bug.
- Honour mode: start with 4 or fewer and invite the rest in-game.
- Crossplay is broken since Hotfix 36.
- Hotfix 36 broke Steam matchmaking for some; the workaround is launching `bg3.exe` directly.

**Joining with 5–8 players:**
- Players 5–8 join via **LAN** (Options → Gameplay → LAN connection), or the host opens **port 23253** and they type the host's IP into the Direct Connect box.
- Not by Steam invite.
- Larian's FAQ lists ports 23253–23262 and 23243–23252.

**Fake download:** `github.com/FaceNoviceFilter/party-limit-begone` (2026-10-05) is not PLB. Its download links go to an unrelated site. Get PLB from Nexus only.

### Our hooks against the patched exe

**Status: half done.**
- **Vanilla side:** done.
- **PLB side:** blocked on PLB's patch bytes. They aren't published; they're in the `.xsc` inside the Nexus zip, which needs a login.

**Vanilla Patch 8** (`bg3_dx11.exe`, 104,354,368 bytes, SHA-256 `6fa3cd43…37af00`; `bg3.exe` 107,018,304 bytes, `e37dacd2…ecda0`). `python tools/mp/plb_check.py <exe>`, 2026-10-13:
- **24 patterns** in the DLL source.
- 23 resolve exactly once.
- The 24th, AnimRate's string-table lookup, matches twice (rva `0xF46B0F` and `0xF46C1F`). It isn't a hook: it only reads the global string table for the animation recorder's names, and both matches load the same global (rva `0x604B2E0`). Harmless; noted so nobody "fixes" it.
- **5 fixed RVAs** the DLL validates objects against: the ecl::Character, MSFalling, steering look-at and genome SetFs vtables, and the movement transaction counter. Checked at runtime by the self-check.
- **Vtable-slot hooks** (data, not code; PLB is a code patch): MoveController Update/Enter, MSFalling Update/Exit, the camera vtable slot 11, the VisualLift visual slots, the AnimRate node Execute slots.

**To finish the PLB check** (static; nothing of PLB's is run):
1. The developer downloads "Multiplayer Patch v1.6" from Nexus 327 by hand into `downloaded_mods/` (git-ignored).
2. Claude reads `PatchFiles/PLB-MP-Patch.xsc` as text. It's an XVI32 find/replace script.
3. Claude applies its find/replace pairs with a Python script to a **copy** of `bg3_dx11.exe` in the scratchpad, outside the game folder. XVI32 and the `.bat` are never run.
4. Run `python tools/mp/plb_check.py <vanilla exe> <patched copy>`. It lists every changed range and, per DLL pattern: resolves in both? unique? overlaps a change?
5. Put the pairs into `SelfCheck.cpp` `kPlb`. The DLL then tells a PLB-patched exe apart from an unknown build at startup.

Expectation, not yet a result: PLB changes "the hardcoded multiplayer bits", the player-count limits in session and lobby code. Our hooks sit in movement, camera, falling, steering and animation code, so no overlap is expected, but it isn't proven.

**The DLL's startup self-check** (`SelfCheck.cpp`, built in MP-0) runs on every machine. It writes `SELFCHECK` lines in `native.log`:
- **The exe:**
  - `exe bg3_dx11.exe, <size>, sha256 <…> -> vanilla | patched (PLB multiplayer patch) | UNKNOWN build`;
  - PLB's pairs: present / still vanilla.
- **Every pattern the DLL scanned for, re-scanned in the exe file** (memory can already hold other mods' hooks): found in memory, unique in the file, same address, overlaps PLB.
- **Every code patch site** against PLB's changes.
- **The fixed RVAs.**
- It also writes `native-selfcheck.txt` (`exe=… dll_build=… patterns=… plb_overlap=…`), which the version handshake reads.

---

## 3. Audit table

From the 2026-10-13 code audit. **File refs** are under `mod/…/Lua/` (`L/`) and `tools/native/src/` (`N/`).

**Blockers that cut across rows:**
- **B1 — remote actions land on the host's character.** `ServerNet.UserToCharacter` passes the net id (65536) to `Osi.GetCurrentCharacter`, which needs the Osiris id (65537). The lookup fails and it falls back to `Osi.GetHostCharacter()`, so **every remote player's request acts on the host's character**. About 15 callers: Server/Net.lua (PlayAnim, legacy cast, RagdollPush, JumpStart, JumpLift), HitValidator, SpellCast, Mana, HudStats, Dummy, AnimLib. The right helper exists: `Party.CharacterOfPeer`.
- **B2 — remote characters count as companions at first.** `Party.IsControlled` / `Controlled` only know the host until a `GainedControl` event, and they fall back to the host. Disconnected users are never removed.
- **B3 — the client may pick another player's character as its own.** About 25 client files use `ClientControl[1]`; it must become the local character (filtered or server-pushed).
- **B4 — candidate lists centre on the host.** The projectile candidate scan (140 m around the host) is also used by stealth and NPC melee. Fight sides are judged from the host (NpcCombat, Pace).
- **B5 — client data is trusted.**
  - HitClaim's `damage`, `reach` and `eye`;
  - bow / spell aim origins;
  - `ManaRefill` from any client;
  - any client can run any forwarded server command.

| System | Where it runs now | Who owns it in MP | What other players must see | Engine sync or our broadcast | Hardcoded-4 risk | Work needed (pass) |
| --- | --- | --- | --- | --- | --- | --- |
| Camera / head anchor | Client Lua `FullPov.lua` → files → DLL `Pov.cpp`, `Camera.cpp` | Each player, locally | Nothing (your own view); others see your body, facing and crouch | — (local) | none (`kMaxMeshes=16` is per character) | Local character from B3, not `ClientControl[1]`. The scene flag (`Server/Scene.lua`) only for players in that dialogue, not everyone (MP-1/MP-3) |
| Direct WASD controller | DLL `MoveFeel.cpp`, `MoveSpeed.cpp`; client `Movement.lua` | Each player drives their own; the host server replays paths | Smooth walking, no slide or hover | **Engine** (path sync, MSMoveToSync) | Single `g_char` (fine: one local character) | **The host's server-step stub follows the host's own mode and menu state** (`ApplyDirect` sets `g_serverFlag`), so a remote player's replayed path depends on the host. Make the server stub per path owner, or always on for direct-mode players. Remote speed multipliers come from each client's MCM (clamp on the host) (MP-1) |
| RealJump | DLL `RealJump.cpp`; client `Jump.lua`; server `Net.lua` JumpStart / JumpLift, `Shared/Hitbox.lua` | Each player's jump is local (P1); the host validates the hitbox lift | The jumper going up and down on the steered arc, the jump clips | **Our broadcast**: others see only BG3's vanilla parabola from the falling-state start. Need a jump event (start, duration, height, momentum) and others' clients drawing the arc (or a host-side replay) | none | B1 (JumpStart / JumpLift act on the host). `liftUuid` cached per user forever. Remote arc display (MP-1) |
| Play-rate hook | DLL `AnimRate.cpp` (local instances from Lua) | Each player for their own clips; each client for remote characters' clips | Remote prepares, draws and jump clips at the right speed | **Our broadcast** (rate per character, applied on every client) | **8 clip ids × 16 entries for NPC / remote characters** (`kNpcIds=8`, `kNpcEntries=16`; Lua caps at 16): about 8 archers drawing at once | Raise the caps for 8 players + 16 members + enemies (MP-2) |
| Swing chain | Client `Swing.lua` | The swinging player (start, clip, rate); hits from the host | The swing clip on the attacker | **Engine** for the clip if the server plays it; **our broadcast** for start + rate (P1: the attacker starts locally) | none | B1 (`PlayAnimRequest` plays on the host). A cooldown knob that reaches every client (MP-2) |
| HitValidator | Server `HitValidator.lua` | Host | Damage numbers, hit reactions (engine) | **Engine** | none | B1 (attacker = host, so cooldowns and nonces collide). B5: compute damage on the host from the attacker's weapon, check the eye against the attacker's position, friendly-fire rule, lag tolerance. Use `Damage.Apply` (downed check, player hit-reaction rule). Prune `landed` (MP-2) |
| Damage | Server `Damage.lua` | Host | HP and statuses (engine) | **Engine** | none | B2: player vs companion routing must know every player from the start (MP-2) |
| Mana | Server `Mana.lua`; client HUD orb | Host spends; each client predicts its display (P1) | Only your own mana | **Our message** to that user | none | B1 (stats from the host's caster). Keyed by user, so one pool per player shared across their characters: decide per character. `ManaUpdate` carries no character. Validate `ManaRefill` (MP-2) |
| SpellCast + spell animations | Client `Hotbar.lua`, `Spells.lua`, `Prepare.lua`, `GenomeEvents.lua`, `SpellAnims.lua`; server `SpellCast.lua`, `CastRequest.lua` | Caster locally (stages, bar); host validates and casts | Cast stages (prepare, loop, cast, recover), VFX | Cast and recover: **engine** (server UseSpell). Prepare and loop: **our broadcast** (local genome events today) | none | **B1: every remote cast is cast by the host's character.** Stage events broadcast to others (MP-2) |
| Hotbar + Prepare Hotbar | Client only (`hotbar-<uuid>.json` per machine) | The player (P1); the host checks the spell is known | Nothing | — | 10 slots (hotbar, not party) | DESIGN says server-owned: decide in MP-2 (keep the layout local, validate on the host — already done) |
| Bows / draw / reload | Client `Bow.lua`; server `Bows.lua` | Archer locally (draw, release); host validates the shot | The draw pose and stretched clip, the release | `BowAnim` broadcast (excludes the shooter), `RangedState` broadcast every 0.5 s; draw stretch by the play rate (our broadcast) | the AnimRate caps above | B5: validate the aim origin (eye) against the archer. `RangedState` for 16 members at 2 Hz is fine (MP-2) |
| Projectiles | Server `Projectiles.lua` (flight, hits); client `ProjectileView.lua` | Host flies and hits; the shooter shows their own visual at once (P1) | The projectile in flight, the impact | **Our broadcast** (`ProjectileLaunch` / `ProjectileHit`) + engine VFX for the impact | `controlledNear` returns only the first player in an area | B4: candidate set around every player, not the host. One pending launch per caster. Shooter-side immediate visual (MP-2) |
| LookAt / F interact | Client `LookAt.lua`, `Interact.lua`; server `Combat/Interact.lua` | The player aims; the host validates and uses | Doors, loot, levers (engine) | **Engine** | none | `watching[container]` keeps one opener: two players on one chest. Already per peer otherwise (MP-3) |
| Downed / revive / bleed-out / Give up / spectate | Server `Downed.lua`; client `Downed.lua`, `GiveUpButton.lua` | Host | Downed banner and timer for everyone, revive bars, spectate any ally | `DownedState` **our broadcast** (4 Hz); statuses **engine** | none found (spectate uses PartyMember, no cap) | B2 (revive dispatch). Give up waits forever for a disconnected player. Spectate order unstable. Per-player game-over rule with up to 8 players (MP-3) |
| Stealth | Server `Stealth.lua`; client `Crouch.lua` | Host checks; each player crouches locally | Crouch pose (engine sneaking) | **Engine** + `CrouchState` broadcast | none | B4 (host-centred candidates). Client `crouched` not reset on a character switch (MP-3) |
| Brawl + NpcCombat + Pace | Server `BrawlAdapter.lua`, `NpcCombat.lua`, `Pace.lua`, `Brawl/*` | Host | Enemies acting, targeting every player | **Engine** (server-side AI actions) | `Brawl/State.lua:19 MaxPartySize = 4`: **neutralised** by `BrawlAdapter.lua:89-93` (keep it that way). Brawl's own host assumptions in State, Roster, Utils, Pick, Spells (the spell table built at the host's level), Listeners, TurnOrder, Pause | One global `fight.active` (two fights at once break it). Region from the host. B4: sides judged from the host (MP-2) |
| Companions + V cycle | Client `Companions.lua`; server `Companions.lua` | Host; each player's own companions | Companion behaviour (engine) | **Engine** + Toast to the presser | none (members by user) | B2: early in a session V can detach or camp a remote **player's own** character (MP-3) |
| HUD | Client `HUD/Hud.lua`, `Combat/HUD.lua`; server `HudStats.lua` | Each player for their own | Teammate frames for up to 16 members (none today: BG3's portraits are hidden) | `HudStats` broadcast | none, but **no party frames at all** | B1: `HudStats` uses the host (user 0), so **everyone sees the host's XP and potions**; `UsePotion` drinks the host's. Teammate frames for 16 (MP-2 / MP-3) |
| Test kit / play mode | Server `TestKit.lua`, `PlayMode.lua`; client `PlayMode.lua`, `PlayFlag.lua` | Host | — | — | none | Any client's `!dag_play` turns server-wide real time on; `!dag_god party` / `!dag_goblins` from anyone. Host-only or announced (MP-4) |
| `!dag` commands | Client (per machine), server (host), forwarded client → server (`ConsoleForward`) | Per machine for feel knobs; the host for rules | — | — | none | Forwarded server commands: host-only, or announced to everyone. `!dag_melee_cooldown` must reach every client (MP-4) |
| Settings (MCM) | Per Lua state, per machine | Rules: host-authoritative, pushed to clients. Feel: each player | — | **Our message** (settings sync) | none | Nothing is pushed today; clients could raise their own speed. Host pushes rule values (MP-4) |
| Logging | `Shared/Log.lua`, DLL `Log.cpp` | Each machine | — | — | none | **Done in MP-0:** `[Client p2]`, `[Native p2]` tags |

**Hardcoded-4 summary:**
- The only explicit 4-player assumptions are `Brawl/State.lua:19` (neutralised) and the old "2–4 player co-op" wording in DESIGN.
- There are no `1..4` loops in our Lua.
- The real limits are:
  - the DLL's single-character globals (right for the local player);
  - the AnimRate caps for remote / NPC clips (about 8 archers);
  - the HUD having no party frames.

---

## 4. Net protocol

### Messages

**Intents (client → host).** Every one carries `char` (the character it claims to act for), `t` (client monotonic ms) and `seq`. **The sender is SE's user id, never a payload field.**

| Message | Today | Carries |
| --- | --- | --- |
| `HitClaim` | yes (trusts damage / reach / eye) | swing nonce, chain step, `t`, eye + forward at the active window, claimed target + hit point (a hint, re-checked) |
| `SpellArm` / `CastSpellRequest` | yes | spell, aim ray (eye + dir), picked targets (hints) |
| `BowDraw` / `BowRelease` | yes | draw start `t`, release `t`, aim ray |
| `JumpStart` / `JumpLift` | yes | duration, height, take-off position + velocity |
| `UsePotion`, `InteractRequest`, `CompanionMode`, `CrouchToggle`, `ReviveHold`, `GiveUp`, `WeaponSetToggle` | yes | as now + `char` |
| `MpHello`, `MpStatusReq`, `MpProbeBack` | MP-0 | versions / – / probe id |

**Visual events (host → everyone else, excluding the actor).** These are the P3 broadcasts for what only the actor's DLL or client Lua drives:
- swing start (clip, rate);
- cast stage (prepare, loop, cast, recover);
- jump arc;
- bow draw / release;
- projectile launch / hit;
- play-rate per character.

**Corrections (host → one player):**
- `HitResult` (damage or "no damage");
- `ManaUpdate` (the host's value; the client's prediction snaps to it in the orb only);
- the controlled-character push (B3);
- `MpWelcome`.

### Validation rules (the host, on every intent)

1. **Owner:** the sender's Osiris user (`(id & 0xffff0000) | 1`) is the reserved user of `char`, or controls it. Otherwise drop and log.
2. **State:** `char` is alive, not downed (except revive / give-up), not in a dialogue it can't act in.
3. **Rate:** cooldown (the melee cooldown, spell cooldowns, cast time, bow draw ≥ 30 %), one pending action per character.
4. **Cost:** mana and charges, spent on the host.
5. **Geometry:** the eye is within tolerance of `char`'s own eye position on the host. Reach / range are from the host's weapon or spell data, never the client's number. Line of sight is re-cast on the host.
6. **Target:** recomputed on the host from the aim ray (the client's target is a hint, used only to break ties); damage computed on the host.
7. A rejection answers "no damage" (`HitResult` without damage). **It never moves or rewinds the actor's own animation or camera.**

### Lag tolerance

**Choice: positional tolerance scaled by the attacker's measured ping, not a rewind window.**

Every check on the host accepts a target point within `slack + v_target × min(rtt/2 + 100 ms, 300 ms)` of where the host has the target. `slack` is today's `Hitbox.ReachSlack`; `rtt` comes from the MP probes; 100 ms covers the remote character's interpolation.

**Why:**
- BG3 keeps no position history. A rewind window would mean recording every character's position about 20 times a second on the host and searching it on every claim.
- Our hit checks are already generous geometric checks (a cylinder + an arc), not hitscan.
- Characters move at most about 6 m/s. At a 150 ms ping the tolerance grows by 0.45 m on a 2.2 m reach, which is fair to the attacker and barely felt by the target.

**Revisit in MP-4:** if lag tests (simulated delay) show unfair misses, add a 200 ms rewind ring (10 Hz × 16 members + enemies) for melee only.

Projectiles need neither: the host flies them on its own simulation and decides hits there. The shooter sees their visual at once (P1), and the host's hit replaces the visual's guess.

---

## 5. Version handshake (built in MP-0)

- **Hello:** after the session loads, every client (the host's own too) sends `MpHello` with its versions (`Shared/Version.lua`):
  - `mod_version` (meta.lsx);
  - `mod_build`: the pack-time stamp `<git>[+dirty]-<UTC>` that `scripts/deploy.ps1` writes into `Shared/BuildInfo.lua`;
  - `dll_build`: the DLL's stamp from `cmake/BuildInfo.cmake`, read from `native-selfcheck.txt`;
  - `exe` (vanilla / plb / unknown) and the start of the exe's SHA-256;
  - the SE version and the game version.
- **Compare:** the server compares against the host's own (it runs in the host's process).
  - **Must match:** `mod_build`, `mod_version`, `dll_build`.
  - **Warn only:** `exe`, `se`, `game`.
- **Reply:** `MpWelcome` with the user / peer / Osiris ids, the character, the host's versions and the differing keys.
  - **A mismatch:** a 12 s toast on that player's screen ("your build differs from the host's (mod_build)") and a log line on both sides. The host gets a toast naming the player.
  - **Not detected yet:** a player without SE or without the mod never says hello. `!dag_mp_status` lists party members whose user never said hello.
- **Retries:** every 5 s, up to 12 times, until the server answers.
- **Log tags:** the welcome sets them, `[Client p2]` / `[Client p1 host]` and `[Native p2]`.

---

## 6. Test setup

**Every player installs exactly the same set** (the handshake checks the first two):
1. **The same Dark and Gate build:** the pak (`DarkAndGate.pak` in the Mods folder) and `DarkAndGate.dll` in `bin\NativeMods`, from the same `pov-build-deploy.ps1` run. Copy both from the host's machine; don't rebuild.
2. Script Extender (`bin\DWrite.dll`, the updater) with the same SE version.
3. Ch4nKyy's Mod Loader (`bin\version.dll`). Never Native Mod Loader as well.
4. BG3WASD (`bin\NativeMods`), Native Camera Tweaks, Mod Configuration Menu, AnimationUnlocker: the same versions as the host.
5. For more than 4 players: Party Limit Begone **SE** pak, plus its multiplayer patch on the exe. **Every** player since MP patch v1.4.
6. The load order exported from BG3 Mod Manager, the same on every machine.

**Network:**
- **2–4 players:** Steam invite, or Direct Connect by code.
- **5–8 players:** LAN (Options → Gameplay → LAN connection; Hamachi or similar over the internet), or the host forwards **TCP/UDP 23253** and they type the host's IP.
- Online vs LAN: test both before MP-4. LAN first for 5+.

**Two instances on one PC: check, don't count on it.**
- BG3 / Steam may refuse a second instance.
- If it starts, both instances share `%LOCALAPPDATA%\…\Script Extender\DarkAndGate\`, so logs, native-pov.txt and the status files clash. It would need a per-process output folder first.
- Plan on two PCs.

**Diagnostics (built in MP-0):**
- `!dag_mp_status` (client console): my user / peer / character, every peer with its versions, its ping (round trip from the host) and how long since its hello, plus party members whose player never said hello.
- User-tagged logs on every machine: `client.log` `[Client p2]`, `native.log` `[Native p2]`, `server.log` (host only). Collect each machine's three files after a session; `scripts/read-log.ps1` merges by timestamp per machine.
- The DLL's `SELFCHECK` lines on every machine (exe kind, hooks).

**Simulated lag:** not built yet.
- Option A, our own debug knob: delay every outgoing `ClientNet.Send` on one client by N ms (`!dag_net_delay <ms>`, client-side queue). That's easy, and covers intents but not BG3's own sync.
- Option B: a network shaper on the joining PC, such as "clumsy" (Windows, open source), with delay and drops on port 23253. This covers BG3's own sync too.
- Planned for MP-4; A first.

---

## Pass plan

Each pass ends in `docs/playtest/mp-N.md`, every step done as the joining player first, then as the host (P5). Gate 1 / Pass D come after MP-2.

**MP-0 — research + architecture + diagnostics** (this pass).
- This doc and the PLB check (the vanilla half done; the PLB half needs the `.xsc`).
- Diagnostics: `!dag_mp_status`, user-tagged logs, the version handshake, the exe detection + hook self-check.
- A solo check that single-player is unchanged ([playtest/mp-0.md](../playtest/mp-0.md)).

**MP-1 — everyone in first person.**
- Fix B1, B2 and B3, the identity layer:
  - the server resolves every message's character from the sender;
  - the client and the DLL drive only the local character.
- The host's server-step stub per path owner.
- The remote jump arc.
- Own camera / movement / jump / crouch feel identical to single-player.
- Each player sees the others move, jump and crouch smoothly (no hovering, sliding or ghost jumps).
- Test with 2 players, then with a PLB party bigger than 4 if possible.

**MP-2 — combat per player.**
- Melee, spells (with visible cast stages), bows, projectiles (visible to all; the host decides hits), mana and the hotbar.
- B4 (candidates around every player) and B5 (validation, lag tolerance).
- Fights with all players + enemies; enemies target every player correctly.
- The AnimRate caps raised.

**MP-3:**
- Downed / revive / bleed-out / spectate any ally (any count).
- Stealth per player.
- Companions split between players with per-player V cycles.
- F interact + dialogue (the scene flag per involved player).
- Map / fast travel.

**MP-4 — polish.**
- Joining mid-session, reconnecting, the version check (the no-mod case), lag tests (simulated lag).
- Settings sync (host rules pushed), forwarded commands host-only.
- 5–8 players via LAN.
