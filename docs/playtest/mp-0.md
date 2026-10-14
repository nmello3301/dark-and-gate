# Playtest MP-0: diagnostics + solo check

**Build:** 2026-10-13, MP-0 (docs/design/multiplayer.md).
- DLL: `SelfCheck.cpp` (exe kind, hook self-check, build stamp) and log tags.
- Lua: `Shared/Version.lua`, `Client/MP.lua`, `Server/MP.lua` (version handshake, `!dag_mp_status`, log tags).

**Goal:** single-player is unchanged, and the diagnostics report correctly. Nothing about co-op gameplay changed in this pass.

Claude reads the logs; you only say if anything felt different from before.

## Solo (single player)

1. Launch BG3 and load **DEV-SAVE** in first person.
2. Play a minute as usual: walk, bunny hop, look around standing still (the body turns past 30°), swing at a goblin (`!dag_goblins`), cast Fire Bolt, open a chest with F.
   - **Expect:** everything as in the last session.
3. Client console: `!dag_mp_status`.
   - **Expect** (client.log): "MP status: I am user 65536 (peer 1, host) …", one peer (p1, the host) with a ping of a few ms, "1 peer(s) said hello".

**Log lines Claude checks:**
- **native.log:**
  - `Native: Dark and Gate 0.1.0 scaffold loaded, build <git>-<time>`;
  - `SELFCHECK: exe bg3_dx11.exe, 104354368 bytes, sha256 6fa3cd43e1ade63c... -> vanilla (the Patch 8 build this DLL was made for); PLB patch bytes not known yet`;
  - `SELFCHECK: N patterns: N found in memory, N unique in the exe file, N at the same address, 0 overlap PLB's changes`. One pattern may show 2 matches: the recorder's string table, harmless;
  - `SELFCHECK: 5 of 5 fixed RVAs look right`;
  - after the welcome, lines tagged `[Native p1-host]`.
- **client.log:** `MP: hello -> server: …`, `MP: welcome: user 65536 (peer 1, Osiris user 65537), character …`, `MP: same build as the host`; then lines tagged `[Client p1 host]`.
- **server.log:** `MP: server registered … host runs …`, `MP: hello from p1 (user 65536, Osiris 65537, the host's own client) … -> matches the host`.

## Optional: two machines (handshake only)

Only if a second PC is at hand. Do it as the **joining** player first.

1. Copy the host's `DarkAndGate.pak` and `bin\NativeMods\DarkAndGate.dll` to the second PC (don't rebuild), with the same SE, loader, BG3WASD, NCT and MCM. Join the host's game.
2. On the joining PC: `!dag_mp_status`.
   - **Expect:** you are p2 (user 131072), both peers listed with their versions and pings, no mismatch.
3. Optional mismatch test: rebuild on one machine only, join, and check that the toast "your build differs from the host's (mod_build …)" shows on the joining PC and "Player p2 … runs a different Dark and Gate build" on the host.

Co-op gameplay is **not** expected to work yet: remote players' swings and casts still act on the host's character (blocker B1, fixed in MP-1).
