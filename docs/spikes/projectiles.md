# Projectiles: how-to study (static)

**Status:** 2026-10-12. Static study only: SE v32 source in `reference/bg3se`, the extracted vanilla stats and story in the scratchpad, and Ghidra (`bg3_dx11.exe`, GhidraMCP on :8089). Nothing here has been verified in-game. The design is in [design/projectiles.md](../design/projectiles.md).

Confidence tags: **[S]** read from source, data or a disassembled table. **[I]** inferred. **[?]** needs an in-game probe.

## TL;DR

- The **server** projectile is an ECS entity carrying `ServerProjectile` (`esv::Projectile`). Its fields are Lua-writable, including `RequestDelete`, `TargetPos` and the `Path` PathMover. **[S]**
- The **client** gets one create message holding the whole path settings, then **flies the path itself**. Only small update records follow, so moving the server's path after launch most likely does not move the visual. **[I]**
- SE has **no** shoot-projectile helper, no `Ext.Projectile`, and no projectile-hit event. Neither does Osiris (no `ShootProjectile`, no `ProjectileHit`). **[S]**
- The best visual is our existing native **Visual vtable hook** (the `VisualLift` pattern), applied to the client projectile's `Visual`. A Lua `Visual:SetWorldTranslate` per tick is the cheap probe and the fallback.
- **Impact without an animation:** use `Osi.CreateExplosion(target, spell, casterLevel, caster)` or `Osi.CreateExplosionAtPosition(x, y, z, spell, casterLevel, caster)` with a projectile-free "impact" clone of the spell built by `Ext.Stats.Create`. Vanilla uses these for mephit death bursts and traps.

## 1. How BG3 projectiles exist and move

### Server components (`BG3Extender/GameDefinitions/Components/Projectile.h`)

| Component (Lua name) | C++ | Line | Useful fields |
| --- | --- | --- | --- |
| `ServerProjectile` | `esv::Projectile` | 118–187 | `Caster`, `Source`, `TargetObject`, `HitObject`, `SourcePos`, `TargetPos`, `TargetObjectPos`, `LifeTime` (10), `FallbackTimer` (15), `HitInterpolation`, `Path` / `Path2` (`path::PathMover`), `ExplodeRadius`, `Spell`, `SpellCastUuid`, `MovingObject`, flags `RequestDelete`, `Launched`, `IsOnHold`, `IsTrap`, `IgnoreTargetChecks`, `IgnoreRoof`, `CanDeflect`, `IgnoreObjects`, `IgnoreSurfaces`, `Used`, `Success`, `ExplodeImmediate` (legacy `NoMovement`), `Template` (`ProjectileTemplate*`) |
| `ServerProjectileInitialization` | `esv::projectile::InitializationComponent` | 70–115 | `Data.{Projectile, StartPosition, TargetPosition, Spell, SpellCastUuid, Caster, Source, IgnoreObjects, CanDeflect, IsTrap, TargetObject, ExplodeRadius, NoMovement, Path?, MovementSettings?, MovingObject}`: the launch request before it is consumed **[I]** |
| `ServerProjectileSpell` | `esv::projectile::SpellComponent` | 61–68 | `Spell` (cast entity), `Target`, `Index` |
| `ProjectileSource` | `eoc::projectile::SourceInfoComponent` | 19–25 | `Spell`, `Entity` (shared `eoc` namespace, so it may exist on the client too **[?]**) |
| `ServerProjectileAttachment` | | 54–59 | `Attachment` |
| `ProjectileImpactEvent` (one-frame) | `esv::projectile::ImpactEventOneFrameComponent` | 189–196 | `Target`: the engine's own impact, one frame |
| `ServerProjectileCache` | `esv::spell_cast::ProjectileCacheComponent` | 244–252 | per-cast queue, `ProjectileDelayTimers` |

- `path::PathMover` (`GameDefinitions/Base/ExposedTypes.h:177`) extends `Settings` (`:169`), which holds a Bezier3 or Bezier4 `Trajectory`, a `RotateMode`, and a `Velocity` that is Constant, Linear (`InitialSpeed`, `Acceleration`) or Mapped. The mover adds `SourcePosition`, `SourceRotation`, `TargetPosition`, `TargetRotation`, `InterpolateValue` (0..1), `ComputedTrajectoryValues[32]`, `ComputedVelocityValues` and `Initialized`. **[S]**
- **Writable from Lua:** none of these fields carry `[[bg3::readonly]]` (`make_property_map.py:596` is the only gate), so SE accepts the writes. Whether the engine honours a write mid-flight is **[?]**.
- **Client:** `ClientProjectile` is commented out in SE (`Enumerations/ECS.inl:1357`), so `ecl::Projectile` is not mapped. The client entity's generic components (`Visual`, `Transform`, `Effect`) should still be reachable **[?]**.

### Replication (Ghidra)

- `NETMSG_PROJECTILE_CREATE` / `_UPDATE` (`Enumerations/NetMessage.inl:73-74`) are registered in `FUN_14119a320`. Constructors: create at `0x1411e3070` (id `0x4e`), update at `0x1411e39a0` (id `0x4f`). Both carry an array of records at `+0x28`.
- **Create** serializer `0x1411e3150`: 0x1C8-byte records. Each holds handles, positions, a full path-settings block (`+0x58`, via `FUN_141154990`), more vec3s / quats at `+0xA8` and `+0xB8`, and flags. The client gets everything it needs to fly the path on its own. **[S]** layout, **[I]** meaning.
- **Update** serializer `0x1411e3a60`: 0x50-byte records made of a handle, a vec3 (`+0x08`), a 40-byte block (`+0x14`), a byte, a handle (`+0x40`) and a byte. This looks like an impact or state event, not a per-frame position stream. **[I]**
- **Consequence:** the client simulates its own copy of the path. Edits to the server `Path` after creation most likely never reach the visual. **[I]** Probe: write `TargetPos` / `Path.TargetPosition` on the server right after create and watch whether the visual changes course.

### Events

| Need | What exists |
| --- | --- |
| Projectile created | `Ext.Entity.OnCreate("ServerProjectile", fn)` / `OnCreateDeferred` (`Docs/API.md:913-933`). Also `"ServerProjectileInitialization"`, which fires before launch **[I]** |
| Projectile removed | `Ext.Entity.OnDestroy("ServerProjectile", fn)` (`API.md:937`) |
| Projectile hit | No SE event. `Ext.Events` on the server only has `DealDamage`, `DealtDamage`, `BeforeDealDamage`, `ExecuteFunctor` and `AfterExecuteFunctor` (`Lua/Server/ServerEvents.h:11-50`). `OnCreate("ProjectileImpactEvent")` may work, since it is a one-frame component **[?]** |
| Osiris | No projectile-hit event. The cast events are `CastedSpell`, `UsingSpell*` and `CastSpellFailed` (strings at `0x14586a540…`) |
| ECS system hooks | No projectile system is exposed to `OnSystemUpdate` (`Components/ExposedSystemTypes.inl`) |

## 2. Override the position every frame, and remove on our hit

### Lua (what exists)

| Action | API | Notes |
| --- | --- | --- |
| Find our projectile | Server: `OnCreate("ServerProjectile")`, then match `Caster` + `Spell` (or `SpellCastUuid`) | **[S]** API, **[?]** timing |
| Delete it cleanly | `proj.ServerProjectile.RequestDelete = true` | The engine's own flag. Whether it plays impact FX is **[?]** |
| Hard delete | `Ext.Entity.Destroy(handle)` (`Lua/Libs/Entity.inl:163-167`, module `:324`) | Raw ECS `DestroyEntity`; it bypasses the projectile manager, so it could crash. **Don't use it** |
| Steer the server path | Write `Path.TargetPosition` / `InterpolateValue` / `TargetPos` | Writable, but probably invisible to clients (§1). Only useful to keep the server copy from landing |
| Keep it alive | `LifeTime`, `FallbackTimer` | Writable **[?]** |
| Move the client visual | Client: `ent.Visual.Visual:SetWorldTranslate({x, y, z})` (SE `Render.h:77`, see [se-api-notes.md:70](../se-api-notes.md)) | Fights the engine's per-frame transform write (same problem as the visual lift), so it flickers if Tick runs first **[?]** |
| Spawn a projectile with a custom start and end | **None.** No `Ext.Projectile`, no `ShootProjectile` in SE (grep: zero hits). Osiris only has `CreateProjectileStrikeAt(Target, SpellID)` and `CreateProjectileStrikeAtPosition(X, Y, Z, SpellID)`, which drop a projectile from the sky, with no caster arg | The engine has behaviour-script `ShootProjectile`, `ShootProjectileAt` and `ShootLocalProjectile[At]` (strings `0x145754520`, `0x145753480`, `0x14576dda0`; registered in `FUN_1428d80f0` and `FUN_142a7b280`). They are not reachable from Lua or Osiris. The stats functor `FireProjectile(template)` (`Stats/Functors.h:570`) only fires from spell data |

The usual launch therefore stays `Osi.UseSpellAtPosition` toward a point. Our current flow does exactly this (`Server/Combat/SpellCast.lua:60-75`).

### Native (Ghidra)

- **Strings:** `esv::Projectile` is the only class-name string (`0x1457747c8`). There is no `ecl::Projectile`, no RTTI and no PathMover string, so the client projectile update **was not located** in this pass.
  - One `esv::Projectile` debug/describe method sits at `0x142ae31f0` (it reads `this+0x598`). Its 3-entry table at `0x145774be0` is a debug query table, not the component vtable.
- **Hook that fits without finding the projectile system:** the render `Visual` vtable hook we already have (`tools/native/src/Hooks/VisualLift.cpp`; [m1b-visual-lift.md](m1b-visual-lift.md)).
  - The engine pushes `TransformComponent` into the Visual through slot 5 `SetWorldTransform(Transform const&)`, with slot 2 `SetWorldTranslate` and slot 6 TRS.
  - The hook is filtered by `self`, so a `ProjectileVisual` table of `{visual ptr → our position and rotation}` slots in beside the lift:
    1. Client Lua finds the projectile's `Visual.Visual` pointer.
    2. It writes it to the DLL's config file with the launch parameters (`origin`, `velocity`, `gravity`, `t0`, `id`).
    3. The DLL evaluates the same ballistic curve per frame and replaces the translate (and the rotation, from the velocity) in slots 2, 5 and 6.
    4. Lua clears the entry when the server says "hit".
  - This also covers multiplayer: every client gets the launch through our net channel and runs the same curve.
- **Server hook:** not needed. Our sweep runs in Lua on the server; the server's projectile only has to exist and then be deleted.

## 3. Impact-only, projectile-free spell variants

### Creating them

- `Ext.Stats.Create(name, "SpellData", parent)` (`Docs/API.md:1387-1403`).
  - From a `StatsLoaded` listener no `:Sync()` is needed (`API.md:1450`). After a `reset`, call `:Sync()` on the server; we already do this in `Shared/SpellRange.lua:31`.
  - Create returns `nil` if the name exists, so on a `reset` use `Ext.Stats.Get` first.
- Vanilla models to copy:
  - `Projectile_Fireball_Trap` (`using "Projectile_Fireball"`; `UseCosts ""`; `SpellFlags "IsTrap;CanAreaDamageEvade;ImmediateCast;IsHarmful;IsEnemySpell"`).
  - `Projectile_DeathBurst_MagmaMephit`, the spell `CreateExplosionAtPosition` fires in `GLO_CombatNPCs` / `__PROC`.

| Clone | Parent | Changes |
| --- | --- | --- |
| `DAG_FireBolt_Visual` | `Projectile_FireBolt` | `SpellRoll ""`, `SpellSuccess ""`, `SpellFail ""`, `SpellProperties ""`, `TargetConditions ""`, `TargetRadius` = our range. Keeps `Trajectories`, `SpellAnimation`, `CastEffect` and `CastSound`, so the cast and the bolt look vanilla but do nothing if they land |
| `DAG_FireBolt_Impact` | `Projectile_FireBolt` | `UseCosts ""`; `SpellFlags` += `ImmediateCast`; `SpellRoll ""`. Damage moves to unconditional `SpellProperties "DealDamage(LevelMapValue(D10Cantrip),Fire,Magical);GROUND:SurfaceChange(Ignite);GROUND:SurfaceChange(Melt)"`, which is how `Projectile_MagicMissile` deals unrolled damage. Our aim decides the hit. Whether to keep the attack roll vs AC is a design call to log |
| `DAG_Fireball_Visual` | `Projectile_Fireball` | Same as the Fire Bolt visual clone, plus `ExplodeRadius "0"` and `AreaRadius "0"` |
| `DAG_Fireball_Impact` | `Projectile_Fireball` (or `_Trap`) | `UseCosts ""`; `+ImmediateCast`. Keeps the Dex save (`SourceSpellDC()`), `AreaRadius 4`, `ExplodeRadius 4` and `HitEffect` |

- `SpellAnimation`, `CastTextEvent` and `HitAnimationType` don't matter for an explosion; the explosion path plays no caster animation. **[I]**
- Leave `SpellAnimation` intact on the visual clones; that's our cast animation.

### Applying them without a caster animation

Osiris signatures were read from the builtin registration table in Ghidra (`FUN_1436b0c00`; type codes 1 = INTEGER, 3 = REAL, 4 = STRING, 5 = GUIDSTRING) and matched against the story `__PROC.txt:2819-2827`.

| Call | Args | Registered at | Fit |
| --- | --- | --- | --- |
| `CreateExplosion` | 4: `(GUIDSTRING Target, STRING SpellID, INTEGER CasterLevel, GUIDSTRING Caster)` | `0x1436ba54d` | **Single-target impact.** No caster animation; the caster is credited **[I]**; uses the clone's `ExplodeRadius`. Whether radius 0 hits only `Target` is **[?]** |
| `CreateExplosionAtPosition` | 6: `(REAL X, Y, Z, STRING SpellID, INTEGER CasterLevel, GUIDSTRING Caster)` | `0x1436ba633` | **Area impact** (Fireball) and wall or ground hits |
| `CreateProjectileStrikeAt` / `…AtPosition` | 2 `(Target, SpellID)` / 4 `(X, Y, Z, SpellID)` | `0x1436ba753` / `0x1436ba800` | No caster, so no credit or DC. Don't use |
| `UseSpell` | 5: `(Caster, SpellID, Target, Target2, INTEGER WithoutMove)` (the 3-arg PROC wrapper exists) | `0x1436c6928` | Plays the caster's cast animation (queued action). Keep it for the **launch** only |
| `UseSpellAtPosition` | 6 (ROADMAP) | `0x1436c6a2b` | Launch toward a point (current code) |
| `ApplyDamage` | 4: `(Object, INTEGER Damage, STRING DamageType, GUIDSTRING Source)` | `0x1436c6dc3` | Flat damage only: no save, no statuses, no hit VFX. Last resort |
| `Ext.Stats.ExecuteFunctors(functors, Ext.Stats.PrepareFunctorParams("Target"))` | `Lua/Libs/StatFunctors.inl:36,87`; module `Stats.inl:683` | | Runs `SpellSuccess` functors directly, with no roll or save step and no hit FX. Advanced fallback **[?]** |

`CasterLevel` drives `LevelMapValue(D10Cantrip)` scaling **[I]**: pass the caster's level.

### How our cast works today (fit)

- Client: arm (`SpellArm`), then release (`CastSpellRequest {spell, targetUuid?, hitPoint?, withMana}`).
- Server (`SpellCast.lua:119-175`): cast-time check, then `Mana.TrySpend`, then `StopScriptedAnim`, then `Osi.UseSpell` / `UseSpellAtPosition`, trying each arity (`callFirst`).
- The new flow keeps that call and swaps in the `_Visual` clone aimed at a far point along the crosshair. The `_Impact` clone runs only from our hit.

## 4. Speeds and trajectories

- `Projectile_FireBolt`: `Trajectories "792ba497-a6ea-46bc-81cb-deb78e4dd9d3"`. `Projectile_Fireball`: `"f5855e43-2e8f-4971-b8c2-7faa36e3381b"`. Both from `Shared/Stats/Generated/Data/Spell_Projectile.txt:1037,1866`; they are `ProjectileTemplate` root templates.
- Speed lives on the template (`RootTemplates.h:543-581`): `VelocityMode` (Constant / Linear / Mapped), `InitialSpeed`, `Acceleration`, `CurveResourceId`, `ProjectilePath` (Bezier3 / Bezier4 / Pathfind) with its Distance / Offset / Shift ranges, plus `LifeTime`, `TrailFX`, `ImpactFX`, `BeamFX`, `CastBone`, `DestroyTrailFXOnImpact` and `RotateMode`.
- The templates aren't extracted, so the **values are unknown**. Read them in-game, on either side:
  `_D(Ext.Template.GetTemplate("792ba497-a6ea-46bc-81cb-deb78e4dd9d3"))` (`API.md:1798`). `OverrideableProperty` pushes as a plain value.
  - Put the result in `data/` as `speed_mps` per projectile.
- Stats-side timing: `ProjectileDelay` and `CastTargetHitDelay` (Magic Missile: 100) exist; Fire Bolt and Fireball set neither.

## 5. Fallback visuals

| Option | Plausibility |
| --- | --- |
| **Lua `Visual:SetWorldTranslate` on the real client projectile, each `Tick`** | Good probe and first fallback. It may jitter because the engine rewrites the transform each frame. The trail follows only if it is parented to the Visual **[?]** |
| `Ext.System.ClientEffectHandler:InitMultiEffect` with `SourceEffect.Flags = HasPosition` (`Effect.h:7-13,22-37`) using the template's `TrailFX` | Proven to spawn effects (our prepare FX, [spell-fx.md](spell-fx.md)), but a position-flagged effect is static. Moving it needs an entity whose transform we move; client entities from `Ext.Entity.Create` have no Visual or Transform **[?]** |
| `Osi.PlayEffectAtPosition(fx, x, y, z[, scale])` repeated (server, 30 Hz, replicated) | Works, but gives a dotted trail with net cost. Debug only |
| Invisible item via `Osi.CreateAt` + `Osi.TeleportToPosition` per tick | Server-replicated teleports at 30 Hz look choppy, and the item still needs an attached effect. Poor |

## Recommendation (v1)

**(a) Visual**
1. On release, the server casts the **`_Visual` clone** with `Osi.UseSpellAtPosition` at a point ~150 m along the aim ray. This keeps vanilla cast animation, cast FX, sound and trail, and the clone has no functors.
2. The server broadcasts `ProjectileLaunch {id, caster, spell, origin, velocity, gravity, radius, t0}` on our net channel.
3. Each client finds the new projectile entity (probe: `OnCreate("ProjectileSource")` or `"Visual"` filtered by `ProjectileSource.Entity == caster`). It then hands the `Visual.Visual` pointer and the launch parameters to the DLL, which overrides slots 2, 5 and 6 per frame along our curve.
4. Probe step zero uses Lua `SetWorldTranslate` per Tick before any DLL work.

**(b) Removal at our hit**
1. The server sweep (ours) finds contact.
2. The server sets `ServerProjectile.RequestDelete = true` on the matched entity (from `OnCreate("ServerProjectile")`, matched by `Caster` + `Spell`) and broadcasts `ProjectileHit {id, pos}`.
3. Clients drop the override.
4. Guard: because the visual clone is aimed 150 m out and has `LifeTime` raised, it never lands first. If it does, it does nothing.

**(c) Impact**
- Character hit: `Osi.CreateExplosion(target, "DAG_FireBolt_Impact", level, caster)`.
- Fireball, or a wall or ground hit: `Osi.CreateExplosionAtPosition(x, y, z, "DAG_Fireball_Impact", level, caster)`.
- The clones are created in `StatsLoaded` with `Ext.Stats.Create` and are built from data (`data/spells.lua`: `visual_clone` and `impact_clone` overrides per spell).

**Risks / to probe, in order**
1. The client keeps its own path. Does writing the server `Path` / `TargetPos` move the visual? (Expect no.)
2. Does `RequestDelete` remove the client projectile and trail promptly, and does it fire `ImpactFX`?
3. Does `CreateExplosion` with `ExplodeRadius 0` hit only the target, credit the caster (aggro, XP, `SourceSpellDC`), and scale by `CasterLevel`?
4. Can client Lua find the projectile entity and its `Visual` (`ProjectileSource` on the client)?
5. Does the trail effect follow an overridden Visual, or the `Transform`? If it follows the Transform, the DLL must also write the client `Transform`, or we need the client projectile update (not located yet).
6. If the client path ends before our hit (our sim slower than the template speed), the client may self-terminate. Mitigate with the far aim point, and match `InitialSpeed`.
7. `Ext.Entity.Destroy` on projectiles: avoid it.
