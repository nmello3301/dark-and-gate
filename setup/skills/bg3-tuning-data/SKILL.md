---
name: bg3-tuning-data
description: Change DarkAndGate's tuning data — weapon families and swing timings, hit zones, mana formula and spell costs, damage reduction, AI archetypes and encounter overrides — keeping data/, MCM defaults and docs/DESIGN.md in sync. Use for any balance or "make X faster/stronger" request.
---

# Tuning data

All balance numbers live in `mod/DarkAndGate/data/`. Changing a number is a data change, never a Lua change.

## Files

| File | Holds | Design doc section |
| --- | --- | --- |
| `weapon_families` | The 10 families, which BG3 weapons map to each, and each chain step: wind-up, active window, recovery, combo window, movement slow, turn-rate limit, reach, max targets, stagger power, damage scale | Melee combat system |
| `hit_zones` | Head, torso and limb multipliers; leg-hit slow | Melee combat system |
| `blocking` | Shield arc, weapon block %, parry window, blocking movement penalty | Melee combat system |
| `mana` | Pool formula (base, per caster level, per modifier), regen formula, cost per spell level, Warlock multipliers, conversions, AI mana reserve | Mana system |
| `spell_overrides` | Per-spell exceptions: cast time, custom cost, targeting rule | Spellcasting |
| `damage` | AC-to-damage-reduction slope and cap, crit chances, advantage/disadvantage rules | Damage and rules rebalance |
| `ai_archetypes` | Melee, ranged, caster, healer behaviour thresholds | Companions and AI |
| `encounter_overrides` | Encounters that start turn-based or need special handling, by act | Campaign compatibility |

Create a file only when the first system that needs it is built. Choose one format for all of them in M0 and record it in `DECISIONS.md`.

## Changing a number

1. Find the current value and where the design doc states it.
2. Make the change in `data/`. If an MCM setting exposes it, its default comes from `data/`, so check the MCM entry still reads it.
3. If the change moves a design number (anything in a design doc table or formula), update `docs/DESIGN.md` and add a line to `docs/DECISIONS.md` with the reason, for example "Fireball cost 32 → 36: three casts per fight felt too strong at level 5".
4. Check the side effects with the developer:
   - For mana: recompute the worked-examples table (pool, regen, empty-to-full time, what a full pool buys) and show the before and after.
   - For swings: say how the change affects damage per second for that family, compared with the others.
5. Give one short playtest that shows the difference (`bg3-deploy-test`).

## Guardrails

- Mana: keep empty-to-full at roughly 60–90 s for full casters at every level unless the developer decides otherwise; flag any change that breaks it.
- Swings: light 0.4–0.5 s, medium 0.6–0.75 s, heavy 0.9–1.1 s total. Flag changes outside those bands.
- Damage reduction cap stays at or below 45% unless decided otherwise.
- Never balance by editing BG3's own spell or weapon stats in place. Overrides go in our mod's files only.
