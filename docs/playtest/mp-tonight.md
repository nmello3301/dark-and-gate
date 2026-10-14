# Playtest: co-op tonight (host + 1 friend over the internet)

**Stages in this build:** MP-0 (diagnostics), MP-1 (presence + movement), MP-2 (combat), MP-3 (downed, stealth, companions, world), MP-4 (robustness + tools). Design: [design/multiplayer.md](../design/multiplayer.md).

**How to run it:**
- Do each step from the **CLIENT's** (friend's) side first, then repeat as the HOST (P5).
- If a step is broken: press **INSERT** (or type `!dag_note <what happened>` in the client console), flip the switch named in the step if there is one, and continue.
- INSERT writes "Issue #n" into **both** players' logs, with positions, states, ping, switches and the last 10 s of net messages, and shows "Issue #n marked" on both screens.

**Console:** the Script Extender console window. Press Enter, type `client`, then the `!dag_…` command. Switches are the host's only: `!dag_mp_feature <name> on|off` (it reaches both players and shows a toast).

## 0. Before you start

**HOST:**
1. **Windows Defender quarantined `bin\version.dll` (Ch4nKyy's mod loader) on this PC on 2026-10-13.** Without it no native mod loads (Dark and Gate's DLL, BG3WASD, the camera mod).
   - Restore it: Windows Security → Virus & threat protection → Protection history → the `Trojan:Win32/Posilod.CA!cl` entry for `version.dll` → Restore. Or re-download it from Nexus 25474.
   - Your call: it is a cloud machine-learning flag on a widely used loader.
2. `scripts\pov-build-deploy.ps1` (already done for this build), then `scripts\make-friend-package.ps1`. Send `Desktop\DarkAndGate-friend-<sha>.zip` to your friend.

**CLIENT (friend):**
1. Install the third-party mods from `FRIEND-README.md` (SE, the loader, BG3WASD 1.9.9, NCT 2.4.5, MCM 1.41, AnimationUnlocker 1.0.5.5), then run `INSTALL.bat`. It finds the game in any Steam library, installs our files plus the host's NCT/WASD tomls and `ScriptExtenderSettings.json` (backing up theirs), checks the game version (`bg3_dx11.exe` 4.1.1.7631656) and every mod, and offers to set the load order (MCM > AnimationUnlocker > DarkAndGate, after a backup).
2. Repeat until it ends with a green **READY**. Launch in **DirectX 11**.
3. Defender may flag the loader on your PC too (see the README).

## 1. Install check, solo sanity, joining

| # | HOST | CLIENT | Expect | If broken |
| --- | --- | --- | --- | --- |
| 1.1 | Load DEV-SAVE alone. Walk, bunny hop, swing at a `!dag_goblins` goblin, cast Fire Bolt. | — | Everything as in single player: hops, the 1.5 s melee cooldown, the body turning past 30°. | Mark it; that's a solo regression, stop and report. |
| 1.2 | `!dag_mp_status` | — | "I am user 65536 (peer 1, host)", 1 peer, features all on. native.log `SELFCHECK: exe … -> vanilla`. | — |
| 1.3 | Host the game and invite (Steam invite, or the Direct Connect code). | Join, pick or create a character, load in. | Both in the world. | — |
| 1.4 | `!dag_mp_status` | `!dag_mp_status` | Each sees 2 peers, the same mod build and DLL build, no MISMATCH, a ping. On a mismatch: a 12 s toast on the client, a toast on the host naming the player. | Rebuild nothing: re-send the zip and re-install. |
| 1.5 | `!dag_play` (first person on, real time). | `!dag_play` | Both in first person. | — |

## 2. MP-1 — presence + movement

| # | HOST | CLIENT | Expect | If broken |
| --- | --- | --- | --- | --- |
| 2.1 | Watch the client. | Walk, run, stop, strafe in circles near the host. | Client: the instant controller as in single player. Host sees smooth walking: no hovering, no sliding, the body facing the way they move. | Client feel wrong: `direct_move off`. Host sees sliding: mark it. |
| 2.2 | Walk, run, stop. | Watch the host. | The same, the other way round. | as above |
| 2.3 | Watch. | Jump in place, then bunny hop forward 10 times. | Client: as in single player. Host sees the arc (up and down, roughly at the same height), no ghost jump. | Arc doubled / jittery on the host: `jump_sync off`. |
| 2.4 | Bunny hop. | Watch. | The client sees the host's arc. | `jump_sync off` |
| 2.5 | Watch. | Crouch (C), walk crouched, stand. | The host sees the crouch pose. | Mark it. |
| 2.6 | Look at the client's face. | Look at the host's face. | Each sees the other's head (only your own is hidden). | Mark it. |

## 3. MP-2 — combat

| # | HOST | CLIENT | Expect | If broken |
| --- | --- | --- | --- | --- |
| 3.1 | `!dag_goblins melee` | Swing at the same goblin. | Client: their swing starts at once (the clip may start a beat later, the host plays it), the goblin loses HP. server.log: `HitValidator: HIT … dmg=…`. | No damage: mark it (server.log REJECT says why). Clip glitches or roots the client: `swing_sync off`. |
| 3.2 | Swing at the same goblin. | Watch. | Damage lands; the client sees the host's swing. | — |
| 3.3 | Both swing at a goblin that walks around. | | Hits land on a moving goblin. server.log may show `in reach N ms ago (rewind)`. | Too many misses: `!dag_mp_rewind 400`. Strange hits: `rewind off`. |
| 3.4 | Cast Fire Bolt at a goblin. | Cast Fire Bolt at a goblin. | Each sees their own cast bar and mana go down, and the other's projectile and impact. | Projectile shown twice / wrong: `proj_sync off`. |
| 3.5 | Watch. | Shoot arrows (Q for the bow) at a moving goblin. | The host sees the client draw, release and hit. | Draw stretched oddly: `remote_playrate off`. |
| 3.6 | A real fight: walk north into the gate fight (or `!dag_goblins` ×2). | Fight too. | Goblins attack **both** players and both players' companions. Both deal damage. | Goblins ignore the client: mark it. |

## 4. MP-3 — downed, stealth, companions, world

| # | HOST | CLIENT | Expect | If broken |
| --- | --- | --- | --- | --- |
| 4.1 | Watch the banner. | `!dag_downme` | The client goes down: orbit camera, banner and timer. The host sees their downed state. | — |
| 4.2 | Walk to the client and hold F. | Watch the bar. | Revive bar on both screens; the client is up at 1 HP, back in first person. | — |
| 4.3 | Stand back. | `!dag_downme` again. | A companion runs over and revives the client. | Companions run around oddly: `revive off`. |
| 4.4 | `!dag_downme` | Watch. | The host is down; the client can revive. While down, the host presses Space to spectate the client (and the companions). | Spectate wrong: `spectate off`. |
| 4.5 | Stand in a goblin's view. | Crouch, sneak behind a goblin. | The client's stealth checks run per goblin (server.log `Stealth: check …`); the host standing in view starts the fight. | Odd detections: `stealth off`. |
| 4.6 | Press V. | Press V. | Each V changes only **your own** companions (Follow / Wait / Camp), with a toast. | Wrong companions move: `companion_v off`. |
| 4.7 | Fight a goblin. | Talk to an NPC (Zevlor or anyone). | The client is in dialogue (our HUD gone for them only); the host keeps fighting in first person. | The host's HUD vanishes too: mark it. |
| 4.8 | Fast travel (M). | Watch. | BG3's own rules. First person comes back for both after travel. | — |
| 4.9 | `!dag_rt off`, start a fight, then `!dag_rt on`. | | Turn-based works in co-op, real time back after. | — |

## 5. MP-4 — robustness

| # | HOST | CLIENT | Expect | If broken |
| --- | --- | --- | --- | --- |
| 5.1 | — | Leave the game, rejoin. | On rejoin: a new welcome, `!dag_mp_status` shows 2 peers again, mana and the switches restored, first person after `!dag_play`. | — |
| 5.2 | Keep fighting. | Join while a fight is on. | The client joins mid-fight; enemies target them. | — |
| 5.3 | — | `!dag_mp_lag 150`, then repeat 2.1, 3.1 and 3.4, then `!dag_mp_lag 0`. | Still playable: own movement instant, hits land (rewind), casts a bit later. | Note what felt worst. |
| 5.4 | INSERT | INSERT | "Issue #n marked" on both screens each time. | — |
| 5.5 | If there's time: swap host roles (the friend hosts) and repeat 1.3 to 3.4. | | | |

**After the session:** both run `scripts\mp-collect-logs.ps1` (the friend: `COLLECT-LOGS.bat`) and send the `DAG-logs-…zip` from the Desktop.

## Switches by symptom

| Symptom | Switch (host: `!dag_mp_feature <name> off`) |
| --- | --- |
| Someone's movement feels wrong, rubber-bands, slides | `direct_move` (vanilla movement for everyone) |
| Jump arcs on the other screen doubled, jittery, stuck in the air | `jump_sync` |
| Remote swing clips glitch or root the swinger | `swing_sync` |
| Projectiles shown twice / in the wrong place on the other screen | `proj_sync` |
| Hits land that shouldn't, or the target "teleports" back | `rewind` (or `!dag_mp_rewind <ms>` to tune) |
| Others' bow draws look stretched or frozen | `remote_playrate` |
| Detection feels wrong | `stealth` |
| Companions sprint to revive and break the fight | `revive` |
| Downed camera jumps to the wrong player | `spectate` |
| V moves the other player's companions | `companion_v` |
| (`cast_sync` is reserved: cast stages aren't relayed yet) | — |

## Issue sheet

Fill it from the "==== ISSUE #n" blocks in both players' logs.

| # | Time | Who | Step | What happened | Switch flipped |
| --- | --- | --- | --- | --- | --- |
| 1 | | | | | |
| 2 | | | | | |
| 3 | | | | | |
| 4 | | | | | |
| 5 | | | | | |
| 6 | | | | | |
