# M1b — Head-bone world position (Phase 0b, static analysis)

**Status:** answered statically (high confidence on layouts, medium-high on "live every frame"; a runtime self-check is specified below)
**Date:** 2026-10-09 · **Binary:** `bg3_dx11.exe` Patch 8 (Ghidra, read-only) · **SE:** v32 source

## Question

The pose arrays on `MeshBinding` (+0x10/+0x18) are skinning matrices
(`M = World × InverseWorld`), indexed by the mesh's bone bindings, so they
don't give a bone position directly. Is there a direct route to a model-space
(or world) bone transform from a `MeshBinding` the DLL already receives?

## Answer: yes. The engine keeps a Granny world pose per skeleton, and the skinning matrices are built from it each frame

`FUN_143a57270` (the per-frame MeshBinding pose update) swaps Pose1/Pose2 and then
calls `GrannyBuildIndexedCompositeBuffer` (`FUN_144a11e00` → `FUN_144a75cf0`):

```c
composite[i] = InverseWorld4x4(skel->Bones[idx[i]]) * worldPose->World4x4[idx[i]]
//  bone stride 0xA4, InverseWorld4x4 at bone+0x50; world 4x4 stride 0x40; out stride 0x30
```

That means `worldPose->World4x4[k]` is the bone's **model-space 4×4 transform**
that the skinning uses this frame. Its translation is the bone position. We
don't need a bind-pose inverse or a binding→skeleton map.

## Pointer chain (all offsets in bytes)

```
MeshBinding (Larian rf, what Lua already sends via tostring(Renderable.Mesh))
  +0x10  mat3x4* Pose1   (current after the update; the update swaps 0x10/0x18)
  +0x18  mat3x4* Pose2
  +0x20  u16     BoneCount
  +0x30  glm::mat4 Transform (column-major, translation = [12..14])
  +0xA0  int*    ToBoneIndices   (= granny_mesh_binding+0x24)  binding idx -> skeleton(+0xB8) bone idx
  +0xA8  int*    FromBoneIndices (= granny_mesh_binding+0x14)  binding idx -> skeleton(+0xC0) bone idx
  +0xB0  u16     binding bone count
  +0xB8  Skeleton* (SE ls Skeleton; the animated "to" skeleton)
  +0xC0  Skeleton* (the original "from" skeleton; == +0xB8 unless remapped)
  +0xC8  granny_mesh*
  +0xD0  u8 flags  (bit0 = remapped skeleton path)
  +0xD8  granny_mesh_binding*

Skeleton (SE GameDefinitions/Skeleton.h for 0x00..0xA0; offsets verified in code:
          Bones @+0x40 stride 8, Sockets Array @+0x88 (size @+0x94, stride 0x68),
          BoneCount u16 @+0x98)
  +0xD8  granny_skeleton*
  +0xE0  granny_world_pose*   (lazily created; FUN_143a1ef00)
  +0x100 granny_local_pose*

granny_skeleton (PACKED, size 0x28; FUN_144a1f480 allocs 0x28 + n*0xA4)
  +0x00 char* Name   +0x08 int BoneCount   +0x0C granny_bone* Bones   +0x14 int LODType   +0x18 variant ExtendedData

granny_bone (PACKED, stride 0xA4; type-def table at 0x145eb8940)
  +0x00 char* Name  +0x08 int ParentIndex  +0x0C transform LocalTransform (68 B)
  +0x50 float InverseWorld4x4[16]  +0x90 float LODError  +0x94 variant ExtendedData

granny_world_pose (PACKED)
  +0x00 int BoneCount   +0x04 float(*)[16] World4x4 (16-aligned buffer)   (+0x0C composite buffer)
  Granny 4x4 is row-vector: translation = floats [12],[13],[14] of the bone's 16.

granny_mesh_binding (PACKED, 0x2C; FUN_144a585b0 = GrannyNewMeshBinding)
  +0x00 mesh*  +0x08 int BoneCount  +0x0C fromSkel*  +0x14 int* FromIdx  +0x1C toSkel*  +0x24 int* ToIdx
granny_mesh: +0x30 BoneBindingCount, +0x34 BoneBindings* (stride 0x2C, char* BoneName at +0)
```

Selecting the skeleton and indices the composite actually uses (from `FUN_143a57270`):

```
remap = (*(u8*)(mb+0xD0) & 1)
skel  = remap ? *(mb+0xC0) : *(mb+0xB8)
idx   = remap ? *(int**)(mb+0xA8) : *(int**)(mb+0xA0)   // only needed for the self-check
```

## Recommended DLL algorithm

```c
// Once per selection (POV enable, mesh list change, every ~1 s if invalid):
bool ResolveHead(uintptr_t mb, Head* h) {
    u8 flags; uintptr_t skel, gskel, bones; int n;
    read(mb+0xD0,&flags);
    skel  = ptr(mb + ((flags & 1) ? 0xC0 : 0xB8));
    gskel = ptr(skel+0xD8);  n = i32(gskel+0x08);  bones = ptr_unaligned(gskel+0x0C);
    if (!skel || !gskel || n <= 0 || n > 512) return false;
    // name search, first hit wins: "Head_M", "Head", "Neck_M" (log all names on !dag_pov_dump)
    for k in 0..n-1: name = ptr(bones + k*0xA4); if strcmp(name, want)==0 -> h->bone = k
    h->skel = skel; h->mb = mb; return h->bone >= 0;
}

// Every frame, in the vt[0x58] commit:
bool HeadWorld(Head* h, float out[3]) {
    uintptr_t wp = ptr(h->skel + 0xE0);            if (!wp) return false;
    int cnt = i32(wp+0);                            if (h->bone >= cnt) return false;
    float* W = ptr_unaligned(wp+4);                 // float[cnt][16]
    float t[3] = { W[h->bone*16+12], W[h->bone*16+13], W[h->bone*16+14] };  // model space
    float mt[16]; read(h->mb+0x30, mt);            // MeshBinding.Transform (column-major)
    out = mt * (t,1);                               // -> world
    return Finite3(out) && PlausibleHead(out, root);
}
```

All reads go through `SafeMem` (SEH). Every pointer above is read-only.

## Runtime self-check (log once per selection, so a wrong guess shows in native.log)

1. **World pose is the live skinning source.** Take binding index `i = 0..min(8,count)`,
   `k = idx[i]`, and compute `C = InverseWorld4x4(bone k) * W[k]` (row-vector
   multiply). Compare its 3×4 transpose with `Pose1[i]` **and** `Pose2[i]`
   (the buffers swap every update). If either matches within 1e-3 → log
   `HEAD check: worldpose LIVE`. If not → log the max error and fall back to
   the existing pivot path.
2. **Space.** If `W[root]` translation ≈ `MeshBinding.Transform` translation (< 5 cm),
   the pose is already world-space: skip the multiply. Otherwise it's model-space
   (expected, since Granny `BuildWorldPose` was called with Offset4x4 = NULL).
   Keep the existing `PlausibleHead` gate either way.
3. **Bone name.** Log the chosen name/index and `out - root`. Expect y ≈ 1.5–1.7 m
   for Gale, and the value should move during attack clips.

## Notes / caveats

- `+0xE0` is lazily created on the first `FUN_143a1ef00` call; a null pointer means
  "not animated yet". Treat it as a read failure and keep using the pivot fallback.
- Reading from the camera commit may be one frame behind the animation update.
  That's fine for the eye.
- The Lua `sock` value (head socket BoneIndex from `Visual.SkeletonSlots[].Skeleton.Sockets`)
  indexes this same skeleton. A socket also carries a local `Transform` (Skeleton
  socket stride 0x68), so `Dummy_HeadFX` = socket transform × `W[sock.BoneIndex]` if a
  socket-exact point is ever wanted.
- The Skeleton pointer could also come straight from Lua (`tostring(slot.Skeleton)`),
  but deriving it from the MeshBinding needs no Lua change.
- The same chain gives `GetBoneWorldPos(entity, boneName)` for weapon bones later.

## A/B and steadiness stats (2026-10-09, movement round)

- `!dag_pov_anchor head|pivot` (`bone` still works). Both anchors share the look-down slide; at rest the head eye equals the pivot eye through the calibrated `eyeUpAuto` (`eye_up` defaults to 0).
- Every frame the DLL takes the eye's offset from the engine pivot, with the look-down slide and the jump lift removed. It logs every 3 s as `CAM delta anchor=… src=… frames=… avg=… max=… jerk=… smooth=… jump=…`. The same numbers are on the status line (`delta=`, `deltaMax=`, `jerk=`).
- In pivot mode that offset is constant, so the numbers are ~0. In head mode they measure the head's motion relative to the body: `avg` / `max` per frame, and `jerk` = the largest second difference, which is where raw pose jitter shows.
- `!dag_pov_smooth <0..0.9>` adds light exponential smoothing of the head's offset from the pivot. It is off by default and only needed if `jerk` / the playtest shows jitter.
- Per jump: `JUMP lift seq=… liftSrc=body|body+camera-fill|camera-only anchor=… boneFrames=… bodyFrames=… fillFrames=… maxMissing=… maxBodyErr=…`.
