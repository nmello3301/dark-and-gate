# Lua ↔ native plugin bridge — design

**Decided:** 2026-10-08. See `DECISIONS.md` for the one-liner.

## The problem

The native plugin (M1a) does three kinds of work:

| What | Direction | Frequency | Latency req |
| --- | --- | --- | --- |
| Camera follow + mouselook | DLL reads config, writes camera transform | Every frame (~16 ms) | — DLL-only, no bridge needed |
| Bone world-position lookup | DLL-owned (blade-path check lives in C++) | 10-30 Hz during a swing | sub-ms |
| `SetAnimPlaySpeed(entity, mult)` / `CancelAnim(entity)` | DLL-owned (driven by hit events) | Few per second | sub-ms |
| `RaycastHitNormal(from, to) → vec3` | DLL-owned (part of the hit check) | 10-30 Hz during a swing | sub-ms |
| Config sync (which bone the camera attaches to, mouselook on/off) | **Lua → DLL** sparse | On MCM change | Any |
| Hit events (victim UUID, zone, direction) | **DLL → Lua** per hit | 1-5 Hz during combat | ~10 ms |

## What the two reference mods do

NCT and BG3WASD don't bridge to Lua at all. They hook game functions
directly and read a TOML config. We follow the same pattern.

## Design

**DLL-autonomous. Lua talks to the DLL only through a shared config
file and a batched event file.**

The DLL owns everything that touches engine state Lua can't reach:
camera, mouselook, bone transforms, animation playback, physics
raycast normals, and the blade-path hit check itself. Lua owns intent
(hotbar press, swing-start trigger), server truth (mana, hotbar state,
saves), and spawn/apply via `Osi.*`.

### Communication paths

- **Lua → DLL config.** Lua writes
  `Script Extender/DarkAndGate/native-config.toml`. The DLL hot-reloads
  it (same pattern as NCT's `WatchForConfigChanges`). Covers which
  bone the camera tracks, MCM toggles, swing speed overrides, and
  anything else that changes at human speed.

- **DLL → Lua events.** The DLL appends newline-delimited JSON to
  `Script Extender/DarkAndGate/native-events.ndjson`. Lua polls once
  per `Ext.OnNextTick` and drains. Batching makes the ms-latency of
  file I/O a non-issue even during a swing.

- **Smoke test (M1a kickoff).** DLL writes
  `Script Extender/DarkAndGate/native-version.txt` on load; Lua reads
  it at SessionLoaded and logs the version. `!dag_native_version`
  re-reads on demand. Zero per-call bridging to prove the DLL loaded.
  Already landed; see `tools/native/src/main.cpp` and
  `Shared/NativeBridge.lua`.

### Decisions settled

(a) **DLL-autonomous architecture.** No per-call Lua↔DLL path. The
blade-path hit check and bone reads run in C++, where the engine
state they need is reachable; Lua gets batched hit events.

(b) **Symbol prefix:** `DAG_`. Applies to the DLL's exports, event
JSON type names (`DAG_Hit`, `DAG_SwingComplete`), and config-file
sections (`[dag.camera]`). Keeps everything greppable to the mod.

(c) **DLL error convention.** For functions that can fail, the DLL
emits a `DAG_Error` event with `{ op, reason }` and no magic return
values. For callbacks that must return a number, success = 0 and any
non-zero is a stage code the Lua side maps to a human string. No
separate error channel — the ndjson is the channel.

(d) **Hooking toolkit:** DKUtil, matching NCT and BG3WASD. Lets us
crib pattern-scan signatures straight from `reference/BG3_NativeCameraTweaks`
and `reference/BG3WASD` instead of hand-rolling MinHook calls.

### Why this works

- Zero SE internals touched. DLL and Lua evolve independently.
- Same pattern NCT and BG3WASD use (both are DLL-autonomous), so
  hook templates copy over cleanly.
- Config-file latency doesn't matter — settings change at human speed.
- Event-batching makes file I/O fine even at swing frequency.
- "Server owns truth" still holds: the authoritative hit arrives in
  Lua as an event, and Lua validates mana / HP from there.

### Open risk

The blade-path hit check lives in C++. More C++ code than a Lua-first
design would need, and the per-swing timing logic is harder to iterate
on in C++ than in Lua. Mitigation: push as much *tuning* data as
possible out of the DLL into `data/weapons/*.lua` + the config file,
so the DLL executes a timing table rather than hard-coding numbers.
