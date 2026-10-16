# Changelog

Versions follow `meta.lsx` (`major.minor.revision`). Every release names the game version it was tested on.

## Unreleased

- Jumping up a slope keeps the jump's full height over the slope instead of ending in a short hop (`data/movement.lua` `jump.slope_max_deg`, `!dag_jump_slope`).

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
