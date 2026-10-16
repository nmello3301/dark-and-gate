# Changelog

Versions follow `meta.lsx` (`major.minor.revision`). Every release names the game version it was tested on.

## 0.4.0 (alpha), 2026-10-16

Built for BG3 4.1.1.7631656 (Steam, DirectX 11) with Script Extender v33. Still an alpha: play on a new save or a copy.

- Jumping up a slope keeps the jump's full height over the slope instead of ending in a short hop (`data/movement.lua` `jump.slope_max_deg`, `!dag_jump_slope`).
- **Meta-Points:** 8 points per level for every party member to put into STR, DEX, INT, WIS, CON and CHA, which scale melee / ranged / spell damage, bow draw, attack cooldown, cast time, max mana, shield block, jump height and move speed. Menu on **P**; Reset all points in camp; numbers in `Script Extender\DarkAndGate\metapoints.json` (`!dag_meta_reload`). Debug: `!dag_meta_grant`, `!dag_meta_set`, `!dag_meta_reset`, `!dag_meta_print`, `!dag_meta_selftest`, `!dag_meta_xp`.
- Below the swing's own length, a shorter melee cooldown plays the swing faster.
- The server computes cast times itself; `!dag_cast_time` sets both sides.
- No fall damage for the party (BG3's own Feather Fall boost on a hidden status).
- Spells cast under a roof no longer hit invisible shapes right in front of you.
- BG3's "Your turn" and other turn notices are hidden in real-time fights.
- **RPG Mode:** a fully cleared fight leaves a flag; switched ON with F, the fight's enemies come back (fresh copies with copies of their items) once you're 100 m away for 60 s. `data/rpgmode.lua` / `rpgmode.json`; `!dag_rpg_list`, `!dag_rpg_respawn`, `!dag_rpg_delete`.
- Mouse-look sensitivity slider on Dark and Gate's Camera tab in Mod Configuration Menu (`!dag_look_sens` without MCM).
- Fixed: mouse-look could stop when a fight started until MMB was pressed twice; the mod now notices and turns it back on by itself.
- Fixed: a character at 0 HP could stay on their feet, ignore every hit and never die (BG3 sometimes drops its downed state a moment after a down). 0 HP now always means downed, with the bleed-out and revive.
- Offline checks: `scripts\test-lua.ps1` (every Lua file compiles; Meta-Points self-test).

## 0.1.0 (alpha), 2026-10-15

First public build, on Nexus Mods. Tested on BG3 4.1.1.7631656 (Steam, DirectX 11) with Script Extender v33, from the nautiloid through the Emerald Grove.

- First person with mouse-look; the body turns with the camera.
- Real-time fights on Brawl's real-time engine; enemies use our combat rules and pick the nearest threat.
- Melee: 3-hit swing chain, hits checked along the swing, head / torso / limb zones, server-validated damage.
- Spells: BG3's own spells on a 1–0 hotbar, channelled (2 s) and released at the crosshair; a mana pool replaces spell slots; class casting animations.
- Bows and crossbows: 3 s draw, arrows with drop, crossbow reload; enemy archers draw the same way.
- Real jump, walk / run, crouch to sneak; WASD movement inside fights.
- Downed, bleed-out and revive; companions Follow / Wait / Camp.
- First-person HUD: health and mana orbs, hotbar, cast and draw bars; Prepare Hotbar menu.
- Co-op foundations: per-player first person, host-validated combat, a build check between players (`!dag_mp_status`).
- `!dag_play` turns the whole mod on and is remembered on that PC.
