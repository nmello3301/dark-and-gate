# Nexus Mods upload sheet

Everything the Nexus "Add a mod" form asks for, ready to paste. The developer uploads and presses Publish; a new mod page stays unpublished (hidden) until then. Before you start, work through the release checklist in [../release.md](../release.md) "Nexus release".

Field names below may not match Nexus's form exactly; the form changes now and then.

## Mod details

| Field | Value |
| --- | --- |
| Game | Baldur's Gate 3 |
| Name | `Dark and Gate - First-Person Real-Time Combat (Alpha)` |
| Version | `0.5.0` |
| Language | English |
| Author | Nick |
| Category | Gameplay (or Overhauls / Combat, if the list has a better fit) |
| Adult content | No |
| Description | paste [description.bbcode](description.bbcode) |

**Summary** (short text under the title):

> First-person, real-time action combat for BG3: swing your weapon, cast BG3's own spells at the crosshair, draw bows, and use a mana pool instead of spell slots, alone or in co-op. Early alpha; play on a new save.

**Tags:** First Person, Combat, Gameplay, Multiplayer/Co-op, Real-time (whichever exist).

**AI tags (required, don't skip):** Nexus moderates mods that don't disclose AI use. Pick the AI tags that match:
- AI-generated **code** (most of the code was written with Claude);
- AI-generated **art / images / textures** (the HUD art, made with OpenAI's image model);
- AI-generated **promotional media** only if a page image or video is AI-made. In-game screenshots are not.

## Images

At least one image; the first is the thumbnail. Use real in-game screenshots (Steam's F12 saves them under Steam's screenshots folder), 16:9:
1. first-person melee with the HUD visible, mid-swing at a goblin;
2. a spell channelled at the crosshair (Fire Bolt or Fireball);
3. a bow at full draw;
4. a co-op shot, once there is one.

A 20–45 s clip later (the `showcase-video` skill) goes in the Videos tab, and the description can embed it.

## Files

Upload all three from `build\release\` (made by `scripts\make-release.ps1`).

| File | Name on Nexus | Category | Version | Description |
| --- | --- | --- | --- | --- |
| `DarkAndGate-0.5.0-mod.zip` | Dark and Gate - mod | Main | 0.5.0 | The mod itself (pak + info.json). Drag into BG3 Mod Manager and load it below Mod Configuration Menu and AnimationUnlocker. Needs the native file below, same version. |
| `DarkAndGate-0.5.0-native.zip` | Dark and Gate - native DLL | Main | 0.5.0 | Required. First person, camera and movement hooks. Extract into the game folder so you get bin\NativeMods\DarkAndGate.dll. Needs Ch4nKyy's Mod Loader. DirectX 11 only. |
| `DarkAndGate-0.5.0-recommended-settings.zip` | Recommended camera + WASD settings | Optional | 0.5.0 | The Native Camera Tweaks and WASD Character Movement settings the mod is tested with. Back up your own BG3NativeCameraTweaks.toml and BG3WASD.toml first, then extract into the game folder. |

If the form asks about mod manager support: the mod file works with BG3 Mod Manager (and should work with Vortex). The native and settings files are a manual install.

## Requirements

**Nexus mods** (add each by its page):

| Mod | Note |
| --- | --- |
| Ch4nKyy's Mod Loader (25474) | Loads DarkAndGate.dll. Don't add Native Mod Loader as well. |
| WASD Character Movement (781) | |
| Native Camera Tweaks (945) | Main file, not the GUI |
| Mod Configuration Menu (9162) | |
| AnimationUnlocker (16058) | |

**Off-site:**

| Name | URL | Note |
| --- | --- | --- |
| BG3 Script Extender | https://github.com/Norbyte/bg3se/releases | The updater DWrite.dll in bin |
| BG3 Mod Manager | https://github.com/LaughingLeader/BG3ModManager/releases | To install and order the mod |

**Optional:** Party Limit Begone (327), only for 5–8 player co-op, SE version.

## Permissions and credits

Dark and Gate is GPL-3.0-or-later, and Brawl's code inside it is GPL-3.0, so the permissions are open, on GPL terms.

| Permission | Setting |
| --- | --- |
| Upload to other sites | Yes, under GPL-3.0 with credit |
| Modify / improve | Yes, under GPL-3.0 with credit |
| Convert to other games | Yes, under GPL-3.0 with credit |
| Use assets in your own files | Yes, under GPL-3.0 with credit (the HUD art is AI-generated; see NOTICE) |
| Use in files that are sold | No |
| Use in files that earn Donation Points | Yes, with credit |

**Custom permission instructions:**

> Dark and Gate is free software under the GNU GPL v3.0 or later. You may copy, modify and redistribute it under the same license, with credit, keeping the source available: https://github.com/nmello3301/dark-and-gate. It includes code from tinybike's Brawl (GPL-3.0); keep that credit too.

**Credits field:**

> tinybike (Brawl, the real-time fight engine and AI loop), Norbyte (Script Extender), ersh1 (Native Camera Tweaks), Ch4nKyy (Mod Loader), Volitio (Mod Configuration Menu), the authors of WASD Character Movement and AnimationUnlocker. Approaches learned from QSAT and BG3AF. Code written with Anthropic's Claude (Claude Code); HUD art generated with OpenAI's image model.

**Donation Points:** your choice; GPL allows either.

## After publishing

1. Put the Nexus link in the repo README ("Download it from Nexus Mods").
2. Send tinybike the message in [../tinybike-message.md](../tinybike-message.md) (the repo is public now).
3. Tick the release items in [../ROADMAP.md](../ROADMAP.md) and tag the commit: `git tag v0.5.0`, `git push origin v0.5.0`.
