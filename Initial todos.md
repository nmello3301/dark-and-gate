# Dark and Gate: initial setup checklist

Work top to bottom. Sections 1–4 are needed before the first coding session. The rest can wait until the milestone that needs it.

When something asks for a path, paste it into the **Machine paths** table in `CLAUDE.md`.

---

## 1. The game

- [x] Baldur's Gate 3 installed (Steam or GOG) and fully updated.
- [x] Launch it once with **no mods**, reach the main menu, quit.
- [x] Find the install folder and paste it into `CLAUDE.md`.
  - Steam default: `C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3`
  - Steam: right-click the game → Manage → Browse local files. Here is the path update CLAUDE.md accordingly: C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3
- [x] Back up your saves. Copy this whole folder somewhere safe: *(Done: copied into `Desktop\BG3 mod backup 2026-10-07_0201`.)*
  `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\PlayerProfiles\Public\Savegames`
- [x] Start a separate **dev save** you don't care about, so testing never touches your real playthroughs. *(Done: `DEV-SAVE`, before the Emerald Grove gate fight.)*
  - Stop near an easy fight; the goblins at the Blighted Village gate work well.
  - Give the character a longsword. Levels and spells for testing can be sorted out later with Script Extender console commands.

## 2. Modding tools

- [x] **BG3 Mod Manager** (LaughingLeader): download the latest release from GitHub, unzip it to a permanent folder, and point it at your game folder on first launch. I got it from github
- [x] **Script Extender**: in BG3 Mod Manager, use Tools → Download & Extract the Script Extender. I got it from github
- [x] **Turn on the Script Extender console.** In the game's `bin` folder, create `ScriptExtenderSettings.json`: *(Done by Claude.)*
  
  ```json
  {
    "CreateConsole": true
  }
  ```
  
  Check the [Script Extender README](https://github.com/Norbyte/bg3se) for the current option names; logging and debugger options live in the same file.
- [x] **Verify the Script Extender:** launch the game. A separate console window should open next to it. Quit. *(Verified: the console opens.)*
- [x] **Free accounts** on Nexus Mods and mod.io, for downloading the mods below.
- [x] **Mod Configuration Menu (MCM)**, v1.33 or newer (Nexus).
- [x] **AnimationUnlocker** (mod.io).
- [x] **Native Mod Loader** (kassent, Nexus) and **Native Camera Tweaks** (Ershin, Nexus). Follow Native Mod Loader's install steps exactly; it goes into the game's `bin` folder. *(Changed: we use Ch4nKyy's Mod Loader instead of Native Mod Loader; never install both. Camera Tweaks installed.)*
- [x] **WASD movement:** first check Settings → Controls in your game version. If there's no WASD option, install a WASD Character Movement mod from Nexus. This apparently requires a mod called Ch4nkyys mod loader. I'll add this to the folder as well.

I dropped the mods above into C:\Users\nicol\Desktop\Dark and Gate\downloaded_mods

- [x] **Load order in BG3 Mod Manager:** MCM first; everything else after it. Dark and Gate will go last once it exists. Export the load order to the game.
- [x] **Verify the mods:** launch the game, confirm MCM appears in the main menu, load the dev save, quit. *(Verified: MCM in the menu, WASD and camera tilt work in DEV-SAVE.)*
- [ ] **LSLib / Divine** (Norbyte, GitHub releases): download and unzip. Paste the path to `divine.exe` into `CLAUDE.md`. Claude uses it to pack the mod. *(Claude Code will download it in the first session; the cloud session can't reach GitHub downloads.)*

## 3. Dev tools

- [x] **Git for Windows.** Claude Code uses its Git Bash.
- [x] **VS Code** with the **Lua** extension (by sumneko), for reading the mod's code.
- [x] **A GitHub account and an empty private repo** (for example `dark-and-gate`). This is your backup and how friends will get builds later. I just created: https://github.com/nmello3301/dark-and-gate

## 4. Claude Code skills and plugins

- [ ] **Activate the project skills.** The four project skills are in `setup\skills\`; Claude Code only loads them from `.claude\skills\`. In PowerShell, from this folder:
  
  ```powershell
  New-Item -ItemType Directory -Force .claude | Out-Null
  Copy-Item -Recurse setup\skills .claude\skills
  ```
  
  Then you can delete the `setup` folder.
- [ ] **Check the project skills loaded.** Run `claude` in this folder and ask: *"Which project skills do you have?"* It should list `bg3-deploy-test`, `bg3-script-extender`, `bg3-spike` and `bg3-tuning-data`. If it doesn't, check the folder is exactly `.claude\skills\<skill-name>\SKILL.md`, then restart Claude Code.
- [ ] **Install the universal-modder plugin.** In Claude Code, run:
  
  ```
  /plugin marketplace add rehan-remade/universal-modder
  /plugin install universal-modder@universal-modder
  ```
  
  It adds game-modding skills: a BG3 engine playbook, reverse-engineering, game screenshots and automation, and showcase videos.
- [ ] **Check the plugin loaded.** Restart Claude Code, run `/plugin` and confirm universal-modder shows as installed and enabled.
- [ ] *(Optional; only for the plugin's `um` CLI tools)* Python 3.10+, `uv` and `ffmpeg`.
- [ ] *(Optional)* A fal API key (`FAL_KEY`), if you want AI-generated icons, textures or sounds later.

## 5. Fill in CLAUDE.md

- [x] Game install folder
- [ ] Path to `divine.exe`
- [x] Path to `BG3 Mod Manager.exe`
- [x] Your GitHub repo URL

## 6. First session

- [ ] Confirm section 4 is done: the four project skills and the universal-modder plugin both show up.
- [ ] Open a terminal in this folder: `cd "$HOME\Desktop\Dark and Gate"`, then run `claude`.
- [ ] Paste this as the first prompt:
  
  > Read CLAUDE.md and docs/DESIGN.md. Initialise git and connect it to my GitHub repo. Clone Brawl and the Script Extender into reference/, download LSLib (divine.exe) and put its path in CLAUDE.md. Scaffold the empty DarkAndGate Script Extender mod, write scripts/deploy.ps1, and get a "Dark and Gate loaded" line into the console and our log file. Then tell me exactly what to do in-game to confirm it.
- [ ] Once that works, start M0 spike #1 (input capture) with the `bg3-spike` skill.

---

## Later: when each milestone needs it

**M0, only if a spike needs native reverse engineering**

- [ ] Ghidra 12.1.3 and Java 21 (JDK).
- [ ] The [ghidra-mcp](https://github.com/bethington/ghidra-mcp) server, registered with Claude Code. Claude can walk you through it.

**M2 and M4: animations and the native UI tab**

- [ ] The **Baldur's Gate 3 Toolkit**: free for game owners on Steam and GOG. It's a large download. how do I get this
- [x] Blender, if we retarget or author swing animations. Sounds good we got it and we have the mcp enabled and battle tested.

**M6: multiplayer**

- [ ] At least one friend with BG3, the same Script Extender and the same mod list (BG3 Mod Manager can export and share a load order).
- [ ] A two-PC test session: you host, they join, both run the same Dark and Gate build.
