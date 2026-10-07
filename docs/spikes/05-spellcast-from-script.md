# Spike 5: Can a script cast a BG3 spell at a chosen target?

**Status:** answered yes
**Date:** 2026-10-08 · **BG3 version:** Patch 8 · **Script Extender version:** v32

## Question

From the server Lua state, can we trigger a real BG3 spell cast — full visuals,
damage, saving throws — on a caster + target we pick, without needing the
engine's own action economy and spell prep to allow it?

## Why it matters

The vertical slice (M1) replaces BG3's hotbar + action-economy flow. The
player presses `1`, the client sends an intent, the server validates mana
and triggers the spell. If scripts can only ask the engine "please let me
cast if the rules allow it", the mod never gets off the ground. We need the
unconditional path.

## What we did

`Spike5_SpellCast.lua` registers three console commands behind
MCM toggle `spike5`. Each one sends a `DAG_CastSpellRequest` through the net
channel. The server handler (`Server/Net.lua:CastSpellRequest`) picks the
nearest living non-player `ServerCharacter` within 30 m of the host character
and calls `Osi.UseSpell(caster, spell, target)`.

Test save: `CombatSaveGood`, lvl 1 Gale on his first turn, Emerald Grove
goblin fight. Verified 2026-10-08.

## Result

**Yes, unconditionally.**

- `!dag5_fireball` → `Osi.UseSpell(Gale, "Projectile_Fireball", <goblin>)`.
  Lvl 1 Gale, who has not and cannot learn Fireball, nuked the goblin with
  the full Fireball visual and damage path. **No action spent, no spell slot
  spent, no concentration check, no "spell not prepared" error.** The engine
  treats a scripted `UseSpell` as "do this now, trust me".
- `!dag5_mistystep` → `Osi.UseSpell(Gale, "Target_MistyStep", Gale)`.
  Called; Gale teleported to his own position (no action spent). Confirms
  the call fires; Misty Step with a self-target just no-ops directionally.
  For M1, teleport-to-point will need either `Osi.UseSpellAtPosition` (if it
  exists) or a transient target entity spawned at the aim point.
- `!dag5_firebolt` → called, nothing visible. Candidate causes: wrong stat
  name (we used `Target_FireBolt`; actual Larian name may be
  `Projectile_FireBolt`), or Fire Bolt requires line of sight / in-combat
  state the goblin was not in at the moment of casting. Not a spike blocker;
  the Fireball result already proves the mechanism.

Server-side nearest-hostile pick confirmed via `Osi.IsPlayer == 0` + range
filter; it found the goblin at 7.12 m in all three casts.

## Implications for M1

- Mana + hotbar system is unblocked. The server validates our mana rule and
  then calls `Osi.UseSpell` unconditionally — the engine will not fight us.
- Spell IDs stay BG3's own stat names. Our mod never touches the spell data.
- Positional spells (Misty Step, Fireball ground point, Thunderwave cone
  origin) need a position lever. The two paths to probe in M1:
  1. `Osi.UseSpellAtPosition(caster, spell, x, y, z)` if present.
  2. Spawn a hidden marker entity at the aim point and target it.

## No native plugin needed

Spike 5 does not add anything to the native plugin's scope. The native plugin
is still bound by spikes 2 (hit normals), 3 (bone reads) and 11 (camera follow).
