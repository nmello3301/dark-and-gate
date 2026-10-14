# Dark and Gate: co-op playtest setup

Thanks for testing! This sets up your PC so you can join the host's game. It takes about 20 minutes, mostly downloads.

<!-- BUILD:BEGIN -->Build: (filled in when the host makes the package)<!-- BUILD:END -->

## 0. Windows Security: two file exclusions (read this first)

Windows Security can quarantine two of the files you're about to install, although they're harmless:

- `bin\version.dll` (Ch4nKyy's Mod Loader). It works by posing as a Windows file so the game loads it, which is also a malware trick. On the host's PC Windows Security removed it as **Trojan:Win32/Posilod.CA!cl**, a guess by its cloud machine learning rather than a known virus, and then no native mod loaded. Its source is public: https://github.com/Ch4nKyy/Ch4nKyys_Mod_Loader
- `bin\NativeMods\DarkAndGate.dll` (this mod). It's new and unsigned, so Windows has no reputation for it yet.

Add a **file exclusion** for each: Windows Security > Virus & threat protection > **Manage settings** (under "Virus & threat protection settings") > **Exclusions**: Add or remove exclusions > **Add an exclusion** > **File**, then pick the file.

- The file picker only accepts files that exist: add `version.dll` right after you put it in `bin` (step 1), and `DarkAndGate.dll` right after INSTALL.bat (step 2), before you start the game.
- Exclude only these two files: never the whole game folder, `bin`, or a drive. Exclude `version.dll` only if you downloaded it from the Nexus link in step 1.

**If something gets quarantined anyway:** Windows Security > Virus & threat protection > **Protection history** > open the entry > Actions > **Restore**. Only for these two files (`version.dll`, `DarkAndGate.dll`). If anything else from this setup shows up there, don't restore it: tell the host.

## 1. Install these mods first (same versions as the host)

You need a free Nexus Mods account to download. If the version below isn't the main download, open the mod's **Files** tab and look under **Old files**.

| # | Mod | Version | Where it goes | Link |
|---|---|---|---|---|
| 1 | Script Extender (the updater) | newest (host: v33) | `DWrite.dll` into the game's `bin` folder | https://github.com/Norbyte/bg3se/releases |
| 2 | Ch4nKyy's Mod Loader | 1.0.0 | `version.dll` into `bin` | https://www.nexusmods.com/baldursgate3/mods/25474 |
| 3 | WASD Character Movement | 1.9.9 | `bin\NativeMods` | https://www.nexusmods.com/baldursgate3/mods/781 |
| 4 | Native Camera Tweaks | 2.4.5 (main file, not the GUI) | `bin\NativeMods` | https://www.nexusmods.com/baldursgate3/mods/945 |
| 5 | Mod Configuration Menu | 1.41.0 | Mods folder (pak) | https://www.nexusmods.com/baldursgate3/mods/9162 |
| 6 | AnimationUnlocker | 1.0.5.5 | Mods folder (pak) | https://www.nexusmods.com/baldursgate3/mods/16058 |
| 7 | BG3 Mod Manager | newest | anywhere (it's a program) | https://github.com/LaughingLeader/BG3ModManager/releases |

- **Finding `bin`:** in Steam, right-click Baldur's Gate 3 > Manage > Browse local files, then open `bin`. Make a folder called `NativeMods` inside it if there isn't one.
- **The Mods folder:** press Win+R, paste `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods` and press Enter. Or drag the pak into BG3 Mod Manager, which copies it there.
- **Don't** install "Native Mod Loader" as well. Two loaders load everything twice.
- **Right after** you put `version.dll` into `bin`: add its exclusion (step 0). If it has already vanished, Windows Security took it: see step 0, "If something gets quarantined anyway". INSTALL.bat says MISSING for a vanished file.
- **Only for 5 or more players:** Party Limit Begone, **SE version** pak (https://www.nexusmods.com/baldursgate3/mods/327). Everyone needs it then. Never use the "standalone" version: it writes into the game folder.

## 2. Run INSTALL.bat

1. Start the game once to the main menu and quit, if you never have (that creates your player profile).
2. Right-click the zip > **Extract All...**
3. Close the game. Double-click **INSTALL.bat** in the extracted folder. If Windows says "Windows protected your PC", click **More info** > **Run anyway**.
4. It finds the game by itself (any Steam library, on any drive) and:
   - copies the Dark and Gate files into place, plus the host's settings for Native Camera Tweaks, WASD and the Script Extender (console and logging on);
   - checks your game version (it must be the host's: `bg3_dx11.exe` **4.1.1.7631656**) and every mod from step 1;
   - checks the load order (**Mod Configuration Menu > AnimationUnlocker > DarkAndGate**). If yours differs, it asks **"Fix it now?"**: press Enter (or Y) and it sets it for you. Any other mods you had active are turned off for co-op; the backup keeps your old list.
5. At the end it says a green **READY**, or a red list of what's missing with a link for each. Fix those and run INSTALL.bat again until it says READY.
   - The "Installed files" section must say **MATCH**: that means you have exactly the host's build.
   - If it says "access denied", right-click INSTALL.bat > **Run as administrator**.
   - If it can't find the game, it asks for the folder. In Steam: right-click Baldur's Gate 3 > Manage > Browse local files, and copy the path from the address bar.
6. **Now** add the exclusion for `bin\NativeMods\DarkAndGate.dll` (step 0), before you start the game.
7. If you install or update WASD or Native Camera Tweaks **after** this, run INSTALL.bat again. Their own settings file replaces ours.

Before replacing anything (including your `ScriptExtenderSettings.json`, the camera settings and your load order), INSTALL.bat backs it up to `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\DarkAndGate-backup-<date>\`.

## 3. The load order (INSTALL.bat does this for you)

INSTALL.bat sets it when you answer Y. If it couldn't (it tells you why), do it by hand:

1. Open **BG3 Mod Manager** and click **Refresh**.
2. Drag these from **Inactive** to **Active**, in this order, exactly like the host. Leave every other mod inactive:

<!-- HOST-LOAD-ORDER:BEGIN -->
1. **Mod Configuration Menu** (version 1.41.0.0)
2. **AnimationUnlocker** (version 1.0.5.5)
3. **DarkAndGate** (version 1.0.0.0)
<!-- HOST-LOAD-ORDER:END -->

3. **File > Export Order to Game** (Ctrl+E). Close the Mod Manager.

Run INSTALL.bat again afterwards: its "Load order" list should be all green and it should end with READY.

## 4. Launch and check the console

1. Launch from Steam and pick **DirectX 11** in the Larian launcher (the box next to PLAY). **Not Vulkan:** the host plays DX11, and Dark and Gate's native part only works in the DirectX 11 game.
2. A black **Script Extender console** window opens next to the game. If it doesn't, hold **Shift** while the game starts.
3. To type a command: click the console window and press **Enter**. You'll see `S >>`. Type `client` and press Enter, and it changes to `C >>`. Now type the command. Alt+Tab switches between the game and the console.

## 5. Join the host

- **2 to 4 players:** accept the host's Steam invite, or choose **Multiplayer > Direct Connect** and paste the code or IP the host sends you.
- **5 or more players:** join from the **LAN** tab, or the host forwards port **23253** (TCP and UDP) and you type the host's IP into Direct Connect.
- After you've joined, type `!dag_mp_status` in the console (in `C >>`). `client.log` should say you are **p2** and "same build as the host". If a message says **"your build differs from the host's"**, stop and tell the host.

## 6. First person

The host usually turns it on for everyone. If your view isn't first-person, type `client`, then `!dag_play` in the console.

## 7. When something goes wrong while playing

- Press **INSERT** the moment it happens. That marks the time in the log, so we can find it later.
- Or type `!dag_note what happened` in the console (in `C >>`), e.g. `!dag_note my sword went through the goblin`.

## 8. Send your logs

After playing (it also works with the game still open), double-click **COLLECT-LOGS.bat**. A file called `DAG-logs-....zip` appears on your **Desktop**. Send it to the host on Discord or similar.

## 9. Uninstall

1. In BG3 Mod Manager, move DarkAndGate back to Inactive and **Export Order to Game** again.
2. Open the `DarkAndGate-backup-<date>` folders in `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\`, newest first (each run of INSTALL.bat that changed something made one). `RESTORE.txt` in each lists every file that run touched: copy the backed-up ones back (`ScriptExtenderSettings.json`, the `.toml` files, `modsettings.lsx`), and delete the ones marked NEW (`DarkAndGate.pak`, `DarkAndGate.dll`).
3. Remove the two exclusions from step 0 (same Exclusions page > the file > Remove).
4. The other mods: delete their files the same way you added them. Steam's **Verify integrity of game files** won't remove extra files, so this step is manual.
