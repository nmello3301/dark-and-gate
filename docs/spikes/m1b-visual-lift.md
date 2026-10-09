# M1b — Visual-only body lift for the jump (Phase 0c)

**Status:** static analysis done, not yet verified in-game
**Date:** 2026-10-09 · **Binary:** `bg3_dx11.exe` Patch 8 (Ghidra, image base 0x140000000) · **SE:** v32 source

## Question

Can the DLL raise the local player's **rendered** body by +y metres for about 1 s,
on the client only, without touching the server or physics position? If so,
where do we hook so the lift survives until render?

## Answer (short)

Yes. Every character Visual gets its world position from **one virtual call**:
`Visual::SetWorldTransform` (vtable slot 5). `ls::VisualSystem` makes that call
whenever the entity's `ls::TransformComponent` changes. `Visual::SetWorldTranslate`
and `SetWorldTransform` also push the new transform down to:

- every renderable (skinned mesh);
- every attachment (hair, weapon, armour).

That means lifting the root Visual lifts the whole character.

**Recommended:** patch the player Visual's vtable at runtime (slots 2, 5 and 6) and
add the lift inside the hooks. Then call the original `SetWorldTranslate` once per
frame from the existing UpdateCamera hook, so the lift animates while the engine
isn't writing (standing still). Details below.

## Findings

### Visual vtable and slots (MoveableObject order, bg3se `Render.h`)

| Slot | Offset | Function | Address (RVA) | Notes |
| --- | --- | --- | --- | --- |
| 0 | +0x00 | `GetRTTI` → `0x1001` | `0x140e86450` (0xe86450) | Byte pattern `B8 01 10 00 00 C3` is **unique** in the exe, with exactly one xref: the vtable. |
| 2 | +0x10 | `SetWorldTranslate(vec3 const&)` | `0x143c64c30` (0x3c64c30) | See "What slot 2 does" below. |
| 3 | +0x18 | `SetWorldRotate` | `0x143c64cf0` | |
| 4 | +0x20 | `SetWorldScale` | `0x143c64da0` | |
| 5 | +0x28 | `SetWorldTransform(Transform const&)` | `0x143c65100` (0x3c65100) | Early-outs when the new value equals the current one (eps 1.19e-7, `FUN_141a108e0`). Otherwise copies it to `this+8`, then works like slot 2, using slot 5 on each child. |
| 6 | +0x30 | `SetWorldTransform(t, r, s)` | `0x143c64ed0` | |

What slot 2 does, in order:

1. Writes `this+0x18`.
2. Calls `FUN_143c6f860`, which rebuilds the world matrix and re-registers the
   object in the scene, under the scene SRWLock.
3. Calls slot 2 on every `ObjectDescs[i].Renderable` (array at `+0x98`, count at
   `+0xA4`, stride 0x10).
4. Calls `FUN_143c68f40` on every Attachment (array at `+0xB8`, count at `+0xC4`,
   stride 0x30), which recomputes the attachment's world transform from the
   parent's.

**Base `ls::Visual` vtable: `0x14588cb30`.** Slots 2, 5 and 6 are **shared** with
three derived vtables: `0x1458ba9e8`, `0x1458c30f8` and `0x1458d2e98`. These are
inferred from the xrefs (`0x1458ba9f8`, `0x1458c3108` and `0x1458d2ea8` point at
slot 2), so the player's Visual may use any of them. Don't hard-code the vtable.
At runtime:

1. Read `vptr = *(void**)playerVisual`.
2. Check that `vptr[0]()` returns `& 0x1001 == 0x1001` (it is a pure getter, so
   it's safe to call).
3. Check that `vptr[2]` is the function whose first bytes are
   `48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57 48 83 EC 20 F2 0F 10 02`,
   and that `vptr[5]` starts with
   `48 89 6C 24 20 56 48 83 EC 20 F3 0F 10 15 ?? ?? ?? ?? 48 8B EA 48 8D 51`.
4. `VirtualProtect` the three slots and swap them.

The patch affects every Visual of that class, so the hook body must be a cheap
`this == g_playerVisual` test.

### Visual field offsets (match the bg3se layout)

- `+0x08` WorldTransform: quat `+0x08`, **Translate `+0x18`** (Y = height at `+0x1C`), Scale `+0x24`
- `+0x30` LocalTransform*, `+0x38` Scene*
- `+0x98` ObjectDescs (Array, size at `+0xA4`); `+0xB8` Attachments (Array, size at `+0xC4`)

### Who writes the character's visual position

1. `ls::TransformSystem` (type-id global `DAT_146058cbc`, registered at
   `FUN_143ae1200`, update `FUN_143c77120`) stores the `TransformComponent`. It
   records translate, rotate and scale changes in hash sets (`FUN_143c78110` →
   `FUN_143c78980/78a40/78b20`).
2. `ls::VisualSystem` (type id `DAT_14604c88c`, registered at `FUN_143ae1820`
   with a dependency on TransformSystem, update `FUN_143bf39d0`):
   - runs a query (view `DAT_14613f2f4`) over (`VisualComponent`, `TransformComponent`);
   - calls **`Visual->vt[+0x28](visual, &transform)`**: `mov rdi,[rax+0x28]` at
     `0x143bf3d47`, `call rdi` at `0x143bf3d93`.

   The query appears to visit only entities whose transform changed. While the
   character moves, the lift is rewritten **every frame**. While it stands still,
   **nothing rewrites it**: a lift written once stays until we remove it.
3. A deferred path, `FUN_143ae1b10`, also uses `vt[+0x28]` for queued visual
   transforms. The slot 5 hook covers it too.

The server, physics and pathing never read the client Visual, so the lift is
purely cosmetic. Other players don't see it. That is fine for M1b; co-op would
need each client to apply the lift for remote jumpers.

### Frame ordering (medium-low confidence)

- `ecl::CameraSystem` (type id `DAT_146058d2c`, registered at `FUN_140738a70`)
  updates via `FUN_14075d250` → `FUN_141e0a160`, which holds our UpdateCamera
  call site at `0x141e0b65c`. That is the anchor `488D8DF8040000E8…E9AFFDFFFF`
  at `0x141e0b661`.
- CameraSystem's dependency list contains TransformSystem,
  `ecl::character_creation::System`, `ecl::TurnOrderSystem` and
  `ecl::FadeLegacyRequestsSystem`.
- **No direct dependency on `ls::VisualSystem` was found in either direction.**
  Both run after TransformSystem, so their order (or whether they run in
  parallel on ECS worker threads) can't be settled statically.
- Rendering pulls from the scene after the ECS frame, so any write made during
  the frame's update is visible in that frame.

So writing the lift **only** from the UpdateCamera hook could be overwritten in
the same frame, while the character moves, if VisualSystem runs later. Hence the
recommended design below: the hook lifts **inside** the engine's own write, so
order doesn't matter.

**Threading caveat.** Calling the original slot 2 from the camera hook could race
with VisualSystem's slot 5 call if the two run on different worker threads. Both
would write consistent values (base + lift), but the scene re-registration in
`FUN_143c6f860` takes only a shared SRWLock. Before relying on it, measure this
in-game (step 4 of the test plan). If the threads differ, do the per-frame
refresh only when the engine has not written the player Visual this frame.

### Knock-on effects

- **Head bone and MeshBinding.** Slot 2/5 propagate to the renderables, so the
  mesh world transform, and therefore any bone world position computed as
  mesh × pose, **already includes the lift**.
  - If the camera anchors on the head bone, **don't add the lift to the eye a
    second time**.
  - The engine camera pivot (`cam+0x24`) follows `TransformComponent`, not the
    Visual. With the pivot or mesh fallback, the eye needs `+lift` explicitly.
- **Cloth and physics proxies** may see a sudden +y and wobble. That suits a
  floaty jump; just watch for it.
- **Bounds and culling** are updated by `FUN_143c6f860`, so the character
  doesn't vanish when lifted.

## Recommended implementation

**(a) A vtable hook on the player Visual, plus a per-frame refresh from the UpdateCamera hook.**

1. **Lua** (`FullPov.lua` or the jump module) adds `visual=<hex>` to
   `native-pov.txt`. The value is `tostring(ent.Visual.Visual)` parsed with the
   existing `addrOf()`, the same way as the MeshBinding addresses. It also adds
   the jump state: `jump_t0`, `jump_dur` and `jump_h`, or simply `lift=<m>` at
   10 Hz. The DLL should compute the curve itself for smoothness, so pass
   `jump_start_ms`, `jump_dur_ms` and `jump_height`.
2. **DLL `Hooks/VisualLift.cpp`:**
   - When `visual` changes, validate it as described in "Visual vtable and slots",
     then patch slots 2, 5 and 6 of `*(void**)visual`, keeping the originals.
     Patch once per vtable and never unpatch; the hooks are pass-through when
     the lift is 0.
   - `Hook_SetWorldTransform(self, const Transform* t)`: if `self != g_visual`
     or `lift == 0`, call the original. Otherwise:
     - `g_base = t->Translate` (the engine's unlifted value);
     - copy `t` and add `lift` to `translate.y`;
     - call the original with the copy;
     - set `g_writtenThisFrame = frameNo`.

     Slots 2 and 6 work the same way.
   - In `pov::OnFrame` (the UpdateCamera hook), while `lift` is changing or has
     just returned to 0:
     - if the engine didn't write this frame, call
       `orig_SetWorldTranslate(g_visual, g_base + (0, lift, 0))`;
     - `g_base` is captured from `self+0x18` the first time the jump starts
       (minus any lift we applied).
   - When the jump ends, write `g_base` once with lift 0, and clear.
   - Drop `g_visual` when Lua stops sending it, so a stale pointer after a
     reload or character swap is never touched.
3. **Camera.**
   - Eye on the `pivot` or `mesh` fallback: add `lift` to `eye.y`.
   - Eye on the head bone: don't add it (it's already included).

**Cheaper in-game probe first (no DLL change).** SE binds `Visual:SetWorldTranslate`
as `P_FUN` (`Render.h:77`), which calls slot 2. From the client console, while
standing still:

```lua
local v = Ext.Entity.GetAllEntitiesWithComponent("ClientControl")[1].Visual.Visual
local t = v.WorldTransform.Translate
v:SetWorldTranslate({t[1], t[2] + 0.5, t[3]})
```

- Expect the whole body, hair and weapon to float 0.5 m and stay there while you
  stand still.
- Walking should snap it back down, because VisualSystem rewrites slot 5.

If that is what happens, the static analysis is confirmed. A Lua-only `Tick`
refresh is a fallback, but it will flicker while moving if Tick runs before
VisualSystem.

**Fallback (c):** if the vtable patch fails validation, use a camera-only lift and
log `camera-only jump`.

## Test plan for the implementation

1. Run the Lua probe above. The body floats while still and snaps back when you walk.
2. With the DLL hook, run a jump while standing still, then while walking forward:
   - one smooth arc each time;
   - no flicker;
   - weapon, hair and armour stay attached.
3. Spin in place during the jump. The lift is applied in world Y, so rotation is unaffected.
4. Log `GetCurrentThreadId()` and a frame counter in the slot 5 hook (player Visual
   only) and in `pov::OnFrame`. This settles two things:
   - ordering: VisualSystem before or after the camera within a frame;
   - threading: same thread or not.

   Record both answers here.
