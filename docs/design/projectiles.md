# Projectiles, bows and melee obstruction — design

**Status:** decided 2026-10-10 (see DECISIONS). Spells: projectile v1 in M1b (Fire Bolt + Fireball). Bows, crossbows and thrown weapons: M2.

## Why
- Being able to hit moving targets is required (developer: not hitting them is a dealbreaker).
- BG3 projectiles fly a scripted path to a target or point and can't be stopped mid-flight. A shot fired at a computed point therefore mismatches every mid-flight hit: the target steps into the path, gets hit, and the visual flies on through them.

## Shared projectile system (arrows AND spells)
1. **Flight (ours, server-authoritative):** position, velocity, gravity (big drop for arrows, little or none for Fire Bolt), drag, and a sphere radius per projectile (e.g. arrow 0.05 m, Fire Bolt 0.15 m, Fireball orb 0.3 m).
2. **Hit check every tick:** sweep the sphere from the previous to the current position, against world rays and against every character's cylinder at their **current** position. The first contact wins, anywhere along the flight. Sweeping matters because fast projectiles move 1–2 m per tick.
3. **Visual:** the game's own projectile entity, its position overridden every frame by the DLL along our path, and removed on our hit.
   - Fallback: the spell's trail / projectile effect attached to an invisible mover we drive.
   - Arrows stick into walls and targets (M2).
4. **Impact:** trigger an instant, projectile-free "impact" variant of the spell (on the hit character, or at the point for area spells), so BG3 still applies damage rolls, saves, statuses, resistances and hit VFX. The original projectile never deals damage itself, so nothing hits twice.

| Spell / weapon shape | Example | Model |
| --- | --- | --- |
| Projectile | arrows, Fire Bolt, Fireball orb | the system above |
| Instant ray | Ray of Frost, fast Eldritch Blast | crosshair line, or a very fast projectile |
| Homing | Magic Missile | stays homing (always hits in D&D) |
| Cone / area at the caster | Burning Hands, Thunderwave | shape test from the caster at cast time |
| Area at a point | Fireball impact, Cloud of Daggers | sphere / cylinder at the impact point |

A BG3 projectile fired at a point is allowed **only as a temporary test visual** (e.g. to try draw/release feel before the DLL arrow exists).

## Bows / crossbows / thrown (M2)
- **Bows:**
  - Hold LMB to draw; the draw clip freezes at full draw via the per-character play rate. Release to shoot.
  - Draw time per bow (e.g. shortbow 0.6 s, longbow 1.0 s) × stat modifiers.
  - Damage and speed scale with the draw fraction; no shot below ~30 %.
  - **Full draw holds forever** (no sway, no fatigue).
  - ~60 % move speed while drawing (Movement modifier, like casting).
  - HUD: a bow draw bar, styled separately from the spell bar (see [hud.md](hud.md)).
- **Crossbows:** no held draw; reload time instead; flatter, faster bolt.
- **Thrown weapons:** the same system, with a slower throw and a higher arc.
- **Knobs:** speed, gravity, drag, draw time, damage-by-draw curve, per weapon.

## Melee obstruction
- `wall = off | stop | bounce`, **default `stop`**: a swing whose path hits world geometry ends its damage window (no hitting through walls).
- Overhead swings and thrusts ignore side walls, so direction matters in corridors.
- `bounce` (stagger + recoil, Dark and Darker style) comes later, with the defence animations.
- **Parry and shield block reuse the same "swing obstructed" path**, adding their own reaction animations later (shield equipped for block, parry-capable weapon for parry).
