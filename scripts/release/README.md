# Dark and Gate {{VERSION}} (alpha)

First-person, real-time action combat for Baldur's Gate 3. Swing your weapon, cast BG3's own spells at the crosshair, draw a bow, and fight enemies that move and attack in real time.

> **Alpha.** This is an early, work-in-progress build. Expect bugs, rough edges, and balance that changes between versions. Play on a new save or a copy of one, never on a playthrough you care about.

## What it does

- **First person** with mouse-look. Your body turns with the camera. Mouse-look speed: the "Mouse-look sensitivity" slider on Dark and Gate's Camera tab in Mod Configuration Menu.
- **Real-time fights.** No turns: enemies and companions act on their own clocks. The real-time engine is Brawl's (credits below).
- **Melee:** left click swings a 3-hit chain. Hits are checked along your swing in front of you, with head, torso and limb zones.
- **Spells:** BG3's own spells on a 1–0 hotbar. Press the key to channel the spell (2 seconds), then left click releases it at the crosshair. A mana pool that refills over time replaces spell slots.
- **Bows and crossbows:** hold left click to draw (3 seconds), release to shoot. Arrows drop over distance. Enemy archers draw the same way.
- **Movement:** a real jump, walk / run, and crouch to sneak.
- **Downed and revive:** at 0 HP you go down and bleed out; hold F next to a downed ally to revive them.
- **Companions:** Follow, Wait or go to Camp (V).
- **HUD:** health and mana orbs, the hotbar, and cast / draw bars.
- **Co-op** (early): every player gets first person and real-time combat, and the host's game decides every hit.

## Requirements

Windows PC, Steam version of BG3, **DirectX 11** (the native part doesn't work under Vulkan). Tested on game version 4.1.1.7631656.

| Mod | Tested version | Where it goes | Link |
| --- | --- | --- | --- |
| Script Extender (the updater) | v33 | `DWrite.dll` into the game's `bin` folder | https://github.com/Norbyte/bg3se/releases |
| Ch4nKyy's Mod Loader | 1.0.0 | `version.dll` into `bin` | https://www.nexusmods.com/baldursgate3/mods/25474 |
| WASD Character Movement | 1.9.9 | `bin\NativeMods` | https://www.nexusmods.com/baldursgate3/mods/781 |
| Native Camera Tweaks | 2.4.5 (main file) | `bin\NativeMods` | https://www.nexusmods.com/baldursgate3/mods/945 |
| Mod Configuration Menu | 1.41.0 | Mods folder, through BG3 Mod Manager | https://www.nexusmods.com/baldursgate3/mods/9162 |
| AnimationUnlocker | 1.0.5.5 | Mods folder, through BG3 Mod Manager | https://www.nexusmods.com/baldursgate3/mods/16058 |
| BG3 Mod Manager | newest | anywhere (it's a program) | https://github.com/LaughingLeader/BG3ModManager/releases |

- **Finding `bin`:** in Steam, right-click Baldur's Gate 3 > Manage > Browse local files, then open `bin`. Create a `NativeMods` folder inside it if there isn't one.
- Don't install **Native Mod Loader** as well as Ch4nKyy's. Two loaders load everything twice.

## Install


Dark and Gate comes as two downloads, plus optional settings. Always use the same version of both.

1. Install everything in the requirements table.
2. **The mod file** (`DarkAndGate-{{VERSION}}-mod.zip`): open BG3 Mod Manager and drag the zip onto it (or File > Import Mod). Move **DarkAndGate** to the Active list, **below** Mod Configuration Menu and AnimationUnlocker. Then File > **Export Order to Game** (Ctrl+E).
   Vortex should handle this file like any other pak mod, but only BG3 Mod Manager has been tested.
3. **The native file** (`DarkAndGate-{{VERSION}}-native.zip`): extract it into the game folder (the one that contains `bin`), so that you end up with `bin\NativeMods\DarkAndGate.dll`.
4. **Recommended settings** (optional, `DarkAndGate-{{VERSION}}-recommended-settings.zip`): the Native Camera Tweaks and WASD Character Movement settings the mod is tested with (mouse-look on, camera pitch unlocked, first-person field of view). First back up your own `bin\NativeMods\BG3NativeCameraTweaks.toml` and `BG3WASD.toml`. Then extract the zip into the game folder and let it replace them. Reinstalling or updating either mod puts its own defaults back.
5. **Turn on the Script Extender console.** In `bin`, open (or create) `ScriptExtenderSettings.json` and make sure it contains `"CreateConsole": true`. A new file looks like this:
   ```json
   {
       "CreateConsole": true
   }
   ```

## First launch

1. Start the game and pick **DirectX 11** in the Larian launcher (the box next to PLAY).
2. A black **Script Extender console** window opens next to the game. If it doesn't, check step 5 above.
3. Load a save, or start a new game.
4. Click the console window and press **Enter**; the prompt shows `S >>`. Type `client` and press Enter; it changes to `C >>`. Type `!dag_play` and press Enter.
5. You're now in first person, and fights run in real time. Your PC remembers this: from now on it turns on by itself when you load a game.

Alt+Tab switches between the game and the console.

**To turn it off:** in the console (`C >>`), `!dag_play off` leaves first person, and `!dag_rt off` brings turn-based fights back.

## Controls

| Key | Action |
| --- | --- |
| W A S D | Move |
| Mouse | Look and aim |
| Left Shift | Walk / run |
| Space | Jump |
| C | Crouch (sneak) |
| Left click | Swing · release a channelled spell · hold to draw a bow |
| Right click | Cancel the spell you're channelling |
| 1 – 0 | Hotbar: press to channel that slot's spell; the same key again cancels it |
| Q | Swap melee and ranged weapons |
| R | Reload a crossbow |
| T / Y | Drink a health / mana potion |
| F | Interact, talk, loot · hold next to a downed ally to revive them |
| V | Companions: Follow / Wait / Camp |
| M | BG3's map (fast travel works) |
| Middle mouse | Free the cursor / back to mouse-look |
| I or Tab | BG3's panels, with the **Prepare Hotbar** menu beside them (H pins it) |
| P | Meta-Points menu |

## Meta-Points

Every party member gets **8 Meta-Points per level** (96 at level 12), also on an existing save. They're separate from BG3's ability scores, which they never change, and only scale this mod's combat:

| Stat | What it improves |
| --- | --- |
| STR | Melee damage (up to ×4), bow draw time (down to instant) |
| DEX | Ranged damage (up to ×4), attack cooldown (down to ×0.1; swings get faster) |
| INT | Spell damage (up to ×4), max mana (up to ×5) |
| WIS | Cast time (2 s down to instant) |
| CON | Shield block (40 % up to 85 %), jump height (up to ×10) |
| CHA | Move speed (up to ×4) |

- **P** opens the menu (first or third person): − / + per stat, the value of every effect now and after, **Confirm** to lock the points, **Reset** to drop the pending ones. You get a notice when a level-up brings points.
- **Reset all points** refunds everything, **in camp only**.
- Companions get their own points. While they're on AI, damage, block, bow draw and cast time count; attack cooldown, jump and move speed only work while you control them (marked * in the menu).
- Jump height and move speed apply only in first person. There is no fall damage for your party in this mod, so high jumps never hurt.
- The numbers are in `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\DarkAndGate\metapoints.json` (made on first launch). Edit it, then type `!dag_meta_reload` in the console (`C >>`); delete it to get the defaults back. Settings: `respec_mode` (`camp`, `anywhere`, `off`), `hotkey`, `min_action_interval` (the shortest cast / draw / cooldown, 0.05 s), `enemy_hp_mult` and `enemy_damage_mult` (1.0).

## Multiplayer

Co-op is built but has had very little testing so far; it's what's being worked on next.

- Every player needs the same version of both Dark and Gate files and of every requirement.
- 2–4 players: normal BG3 co-op. 5–8 players: everyone also needs Party Limit Begone, **SE version** (https://www.nexusmods.com/baldursgate3/mods/327).
- Each player types `!dag_play` once. `!dag_mp_status` (in `C >>`) checks that everyone runs the same build as the host.

## Known issues

- Only Act 1 has been played with the mod so far (the nautiloid through the Emerald Grove). Later areas are untested.
- With real-time fights turned off (`!dag_rt off`), swing animations are skipped, and the camera can dip under the map while casting.
- Bards and Sorcerers use a default casting animation, because BG3 has no class casting set for them (a Bard gets the violin one).
- Windows Security can flag **Ch4nKyy's Mod Loader** (`version.dll`) as `Trojan:Win32/Posilod.CA!cl`. That is a cloud machine-learning guess about DLL loaders in general, not a known virus. If `version.dll` disappears from `bin`, no native mod loads: restore it from Windows Security > Protection history. `DarkAndGate.dll` is new and unsigned, so it can be flagged the same way. The loader's source code is public (https://github.com/Ch4nKyy/Ch4nKyys_Mod_Loader), and so is this mod's.

## Reporting bugs

The mod writes its logs to `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\DarkAndGate\` (paste that into the Win+R box). Attach `client.log` and `server.log` to your report, on the Nexus Bugs tab or as a GitHub issue.

To mark the moment something goes wrong, type `!dag_note what happened` in the console (`C >>`). For example: `!dag_note my sword went through the goblin`.

## Uninstall

1. **Give your save its reaction settings back first.** The mod turns BG3's reaction prompts off (Shield, Counterspell and the like) and keeps your own settings in the save. Load the save, type `!dag_rt off` in the console (`C >>`), and save.
2. In BG3 Mod Manager, move DarkAndGate back to Inactive and **Export Order to Game** again.
3. Delete `bin\NativeMods\DarkAndGate.dll` and the `DarkAndGate-*` text files beside it.
4. If you used the recommended settings, put your backed-up `.toml` files back.
5. Optional: delete `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\DarkAndGate` (the mod's settings and logs).

BG3 lists Dark and Gate as a missing mod when you load a save made with it. That's why you should play on a copy.

## Credits

- **Brawl** by tinybike (GPL-3.0): the real-time fight engine and AI loop are imported from it. https://github.com/tinybike/Brawl
- **Script Extender** by Norbyte, **Native Camera Tweaks** by ersh1, **Ch4nKyy's Mod Loader** by Ch4nKyy, **Mod Configuration Menu** by Volitio, and the authors of **WASD Character Movement** and **AnimationUnlocker**. Dark and Gate depends on these, but doesn't include them.
- Approaches learned from **QSAT** and **BG3AF** (studied, not copied).
- Inspired by **Dark and Darker** and **Blade & Sorcery**. No assets, animations or sounds from either game are used.

**AI disclosure:** Dark and Gate is designed, directed and playtested by Nick. Most of its code was written with Anthropic's Claude (Claude Code). The HUD art was generated with OpenAI's image model.

## License

GPL-3.0-or-later (see `LICENSE` and `NOTICE`). Source code: https://github.com/nmello3301/dark-and-gate

Baldur's Gate 3 and its assets are the property of Larian Studios.
