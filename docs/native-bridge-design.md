# Lua ↔ native plugin bridge — design options

**For:** Nick · **Decide before:** writing the camera-follow hook.
**Author:** Claude · **Date:** 2026-10-08.

## The problem

The native plugin (M1a) does three kinds of work:

| What | Direction | Frequency | Latency req |
| --- | --- | --- | --- |
| Camera follow + mouselook | DLL reads config, writes camera transform | Every frame (~16 ms) | — DLL-only, no bridge needed |
| Bone world-position lookup | **Lua → DLL** on every melee-swing tick | 10-30 Hz during a swing | <0.5 ms per call acceptable |
| `SetAnimPlaySpeed(entity, mult)` / `CancelAnim(entity)` | **Lua → DLL** at swing boundaries | Few per second | ~1 ms acceptable |
| `RaycastHitNormal(from, to) → vec3` | **Lua → DLL** per hit check | 10-30 Hz during a swing | <0.5 ms per call acceptable |
| Config sync (which bone the camera attaches to, mouselook on/off) | **Lua → DLL** sparse | On MCM change | Any |

So three features need a real Lua→native call path with sub-ms latency; camera
follow itself doesn't.

## What the two reference mods do

**NCT** and **BG3WASD** don't bridge to Lua at all. They hook game functions
directly and read a TOML config. For us, camera follow is fine on that
model, but the bone lookup / anim control / raycast calls need Lua to
*ask the DLL* at specific moments, so a one-way "DLL reads config" is not
enough.

## Three bridge options

### Option 1: Osiris custom calls (recommended)

The DLL registers Osiris queries via SE's `CustomFunctionManager`. Lua
calls them as `Osi.<Name>(...)` like any other Osiris function.

```lua
local x, y, z = Osi.DAG_GetBoneWorldPos(entityUuid, "WPN_Blade_Tip")
Osi.DAG_SetAnimPlaySpeed(entityUuid, 2.0)
local hitUuid, nx, ny, nz = Osi.DAG_RaycastHitNormal(fx, fy, fz, tx, ty, tz)
```

**Pros:**
- Uses SE's documented extension point. Script Extender itself does this to
  add functions like `ProcCreateExplosion`.
- Osiris calls are in-process, native speed (sub-µs call overhead).
- Appears in `!dag_osidump` output automatically, so there's one place to
  grep the whole surface.

**Cons:**
- Osiris types are limited: integers, floats, strings. Vec3 return needs
  three OUT floats. We adapt by shape.
- Osiris function names are globally shared, so we prefix everything
  `DAG_` to avoid collisions.
- Osiris has an 8-arg hard cap (incl. output). We stay well under it.
- The DLL needs to find SE's exported `CustomFunctionManager::AddCall/AddQuery`
  entry points. SE v32 exposes these; version brittleness is low because
  the Osiris ABI is stable.

### Option 2: SE native-extension plugin API

SE 2.x supports loading "extension" DLLs that register directly into SE's
Lua state as `Ext.<Namespace>.Fn(...)`. Zero-copy, no Osiris indirection.

```lua
Ext.DarkAndGate.GetBoneWorldPos(entity, "WPN_Blade_Tip")  -- returns vec3 table
```

**Pros:**
- Lowest possible latency (direct Lua C-API call).
- Native vec3 / table returns, no Osiris string-float gymnastics.

**Cons:**
- SE's plugin ABI is **undocumented and version-brittle**. A spike against
  SE v32 is needed to even confirm the entry points still exist.
- Rebuild required when SE updates. We'd pin SE versions in CLAUDE.md.
- Not what NCT / WASD do — fewer references to copy from.

### Option 3: Memory-mapped IPC via a named shared memory region

DLL and SE both open a Windows named shared-memory region. Lua reads/writes
via `Ext.IO` or a tiny helper, DLL polls the region per frame.

**Pros:**
- No SE internals touched. Works no matter how SE evolves.
- Can batch many calls per tick, amortizing cost.

**Cons:**
- Latency: SE's `Ext.IO` is file-based, millisecond-ish round trip. True
  memory-mapped from Lua needs us to patch SE first — or ship an
  intermediate helper file, which is the slow version.
- Protocol work: we invent request/response framing, correlation IDs,
  lock-free queues or a mutex. Yet another thing to maintain.
- Hard to test — can't just call a function.

## Update 2026-10-08 (source check): Option 1 is harder than claimed

Source review of
`reference/bg3se/BG3Extender/Osiris/Shared/CustomFunctions.h` found that
`CustomFunctionManager::Register(std::unique_ptr<CustomCallBase>)` and
friends are **internal C++, not a public C ABI**. A third-party DLL
registering a custom Osiris call would need to:

1. Pattern-scan SE's binary to find the `CustomFunctionManager` singleton.
2. Match SE's internal types (`STDString`, `FunctionHandle`, custom base
   classes with vtables) exactly, including vtable layouts that drift
   between SE releases.

Doable, but version-brittle enough to belong behind a dedicated spike,
not inside the M1a critical path. **Option 1 is deferred unless a later
spike proves it clean.**

## My recommendation (revised)

**Option A (new): DLL-autonomous, Lua talks only via SE's existing net
channels + a shared config file.**

The DLL owns everything that touches engine state Lua can't reach —
camera, mouselook, bone transforms, animation playback, physics raycast
normals. Lua owns intent (hotbar press, swing-start trigger), server
truth (mana, hotbar state, saves), and spawn/apply via `Osi.*`.

Communication:
- **Lua → DLL config:** Lua writes a small JSON/TOML into
  `Script Extender/DarkAndGate/native-config.toml`. The DLL hot-reloads
  it (same pattern as NCT's `WatchForConfigChanges`). Covers "which bone
  the camera tracks", MCM toggles, swing speed overrides.
- **DLL → Lua events:** The DLL fires an Osiris event (via a hooked
  game function) or writes a line to a watched file. Lua subscribes.
  For high-frequency hit events we batch: DLL appends to
  `native-events.ndjson`; Lua polls once per `Ext.OnNextTick` and drains.
- **Smoke test (M1a kickoff):** DLL writes
  `Script Extender/DarkAndGate/native-version.txt` on load; Lua reads
  it at SessionLoaded, logs it, exposes `!dag_native_version`. Zero
  per-call bridging needed to prove the DLL loaded.

**Pros:**
- Zero SE internals touched. DLL and Lua side evolve independently.
- Same pattern NCT and BG3WASD use (both are DLL-autonomous).
- Config-file latency doesn't matter — settings change at human speed.
- Event-batching makes the ms-latency of file I/O a non-issue even at
  swing frequency (DLL emits per hit; Lua drains at tick granularity).

**Cons:**
- The blade-path hit check moves from Lua into C++. More C++ code; the
  "server owns truth" rule stays intact because the authoritative hit
  arrives in Lua as an event and Lua still validates mana / HP there.
- Can't do per-frame bone lookup from Lua (we don't need to — the
  check happens in the DLL, which already has bone access).

**Options 1 / 2 / 3 revisited** below in case Option A turns out to feel
wrong once we hit M1b combat work.

Concrete C ABI the DLL exports (shaped as Osiris queries):

```c++
// Returns 1 on hit (OUT bone position valid), 0 otherwise.
EXPORT int DAG_GetBoneWorldPos(const char* entity_uuid, const char* bone_name,
                               float* out_x, float* out_y, float* out_z);

// Returns 1 if the entity accepted the speed write.
EXPORT int DAG_SetAnimPlaySpeed(const char* entity_uuid, float mult);
EXPORT int DAG_CancelAnim(const char* entity_uuid);

// Returns 1 on hit; out_uuid is the hit entity (empty string for geometry).
EXPORT int DAG_RaycastHitNormal(float fx, float fy, float fz,
                                float tx, float ty, float tz,
                                char* out_uuid, int out_uuid_cap,
                                float* out_nx, float* out_ny, float* out_nz);

// Camera config: Lua pushes which bone to track; DLL picks it up next frame.
// Called sparsely from MCM / Spike11b when the dev tunes.
EXPORT int DAG_SetCameraTargetBone(const char* bone_name);
EXPORT int DAG_SetMouselookEnabled(int enabled);
```

Each one is wrapped by SE's `OsiFunctionProvider` into an Osiris query the
Lua side invokes as `Osi.DAG_*`. The DLL side owns the hook machinery
(camera, mouse) and the bone/anim/raycast implementations.

**Smoke test for the bridge before camera follow:** DLL exports
`DAG_Ping()` returning the DLL version. Lua calls it, logs the version. If
the bridge works, every other function follows the same mould.

## Open points — tell me before I build

1. **Osiris vs. SE-extension (Option 1 vs. 2).** I lean 1 unless you want
   to spend a spike up front proving 2 is practical.
2. **Function prefix.** `DAG_` for Dark and Gate? Or `NAG_` (Native and
   Gate)? Or just drop the prefix and prefix in the Lua wrapper only?
3. **Error handling.** Osiris queries return exactly one row or zero. For
   "failed" cases the DLL returns a zeroed OUT vec3 and `0` for the
   success flag. OK or do you want a separate error channel?
4. **Build toolchain.** DKUtil (used by NCT + WASD) or raw MinHook? DKUtil
   gives us pattern-scanning helpers; MinHook is minimal. I'd use DKUtil
   so we can crib hook signatures straight from NCT.
