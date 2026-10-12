# Interaction, companions, map, targeted spells, RPG mode (decided 2026-10-12, developer)

Open questions are marked **(?)**.

## Interacting in first person: the F key
- **Everything interactive goes through F:** talking to NPCs, looting, doors, levers, picking up items, climbing (ladders, vines, ledges), etc.
- **Highlight:** the interactive object or character under the crosshair is highlighted (outline / glow). Nothing is highlighted if it isn't interactive.
- **Press F = start the interaction at once.** No channel, no hold, no loading bar.
- Must reach the vanilla interaction (dialogue starts, loot window opens, lever toggles, the climb starts) exactly as clicking it would.
- **F priority:** a downed ally in revive range wins: hold F for 3 s = revive (combat-rules.md). Otherwise, a tap of F = interact with the object under the crosshair.
- Vanilla panels (dialogue, loot, trade, inventory…) pause first-person mouse-look and give the cursor back; closing them returns to first person.

## Companion control
- **One key toggles the companion mode cycle:** Follow player -> Wait -> Go to camp -> Follow… (?) Key: suggest **V** (the roadmap already names V for this).
- Companions keep reviving downed players as their highest priority (combat-rules.md).

## Map and fast travel
- **M opens the vanilla map.** Fast travel works normally (waypoints, the travel prompt).
- While the map (or any vanilla panel) is open, first person releases the mouse and pauses our input capture; it restores when the panel closes.

## Targeted spells (pick enemies / allies)
- Spells that let you **select targets** (e.g. multi-target enemy spells, buffs on chosen allies) keep BG3's **targeting line indicator** over each selected character.
- **Selection = hover the crosshair over a character** (with the spell armed). (?) How a target gets added and the cast confirmed: suggested
  - LMB on a hovered valid target adds it (shown with the line indicator);
  - the cast fires automatically once the spell's max target count is reached (and the cast time is READY);
  - pressing the hotbar key again fires early with fewer targets;
  - RMB cancels.
- **No dodge, no block** once targeted: the spell resolves as in vanilla. Saves and chances (e.g. Sleep) roll normally and the effect applies.
- **Line of sight:** you can't select a character behind a wall or cover. **Already-selected targets that move behind cover are STILL affected.**
- (?) Range: BG3's spell range for targeted spells (projectile spells have no range cap)?
- If the vanilla HUD is hidden in first person, keep (or rebuild) the target line/marker so it stays visible.

## Far future — "RPG mode" (backlog, not scheduled)
- **Camps respawn:** once ALL players have left an area for **15 in-game minutes**, the camps there respawn.
  - Respawning never undoes progress: quest and story completion flags stay, so it can't block finishing the game.
  - Story / unique NPCs are excluded.
- **Battlefield flag:** after every full fight, a small flag on a pole appears in the middle of the battlefield.
  - Interacting with it (F) **turns on RPG mode** for that fight: its enemies revive and stand still until aggroed.
  - Fights in RPG mode still give XP.
- The developer will rework stats to fit this later.
- (?) Loot from respawned or revived enemies: none / reduced / normal?
- Watch out: XP farming balance; respawns must not re-trigger dialogues, cutscenes or quest scripts.
