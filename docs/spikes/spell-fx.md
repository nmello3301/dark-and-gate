# Spell prepare VFX and sounds

**Status:** 2026-10-10. Built, not verified in-game. Follows [genome-capture.md](genome-capture.md).

## Problem

Replaying BG3's select event (`e8545375…`) plays Gale's prepare / loop animation, but not the hand fire or the prepare sounds that vanilla targeting shows. Those aren't part of the animation event. They are separate spell stats, which vanilla's client targeting plays on its own:

| Stat | Fire Bolt | What it is |
| --- | --- | --- |
| `PrepareEffect` | `c88e9cfa-df92-477a-ae75-cbfb932350b4` | multi-effect resource (the hand fire) |
| `PrepareSound` | `Spell_Prepare_Damage_Fire_Gen_L1to3` | Wwise event, once |
| `PrepareLoopSound` | `Spell_Prepare_Damage_Fire_Gen_L1to3_Loop` | Wwise event, loops |
| `PrepareEffectBone` | (unset) | optional bone override |

- Fireball: `PrepareEffect` `fdbf8e88…`, with no prepare sounds in its own entry.
- In the prototype these sit right after the two `SpellAnimation` blocks: `PrepareEffect` at +0x288, then `PrepareSound`, `PrepareLoopSound` and `CastSound`, with `IsWeaponAttack` at +0x299. That matches SE's `field_299` legacy name. **[M]**

## Approach (`Client/Combat/SpellFx.lua`)

- **Effect:** `Ext.System.ClientEffectHandler:InitMultiEffect(info)`, which is SE's binding to BG3's own client effect system (`ecl::effect::HandlerSystem`, SE `Components/Effect.h`). Our guess at the info:
  - source, target and event provider = the caster (`Flags = HasEntity`);
  - `MultiEffectDefinition` = `PrepareEffect`;
  - `WeaponBones` = `PrepareEffectBone`;
  - scale 1.
- **Removal:** `DestroyMultiEffect(handle)` at cast or cancel.
- **Sounds:** `Ext.Audio.PostEvent(caster, PrepareSound)` and `(caster, PrepareLoopSound)`. At cast or cancel, `Ext.Audio.Stop(caster)` ends the loop. There is no per-event stop in SE, so this also cuts anything else playing on Gale at that instant.
- **Scope:** local only. Other players won't see or hear it until the MP pass.

## Vanilla reference (`!dag_spell_fx_watch on`)

The watcher is read-only. It logs every client effect handler the game creates or removes whose source, target or provider is the player, with its full init info, and names it when it matches a known spell's Prepare / Cast / Target / Hit / Preview effect. Compare a vanilla select against ours; if they differ, the next build copies vanilla's fields.

## Watcher result (2026-10-10)

`!dag_spell_fx_watch` logged **nothing** during a vanilla select / cancel / cast. Vanilla's prepare effect is therefore not a standalone `ClientEffectHandler` entity whose source, target or provider is the player. Our own `InitMultiEffect` does show the fire and plays the sounds (playtest). Not needed for now.
