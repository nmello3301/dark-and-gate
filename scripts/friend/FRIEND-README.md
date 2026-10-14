# Dark and Gate: co-op playtest setup

Thanks for testing! This sets up your PC so you can join the host's game. It takes about 20 minutes, mostly downloads.

<!-- BUILD:BEGIN -->Build: (filled in when the host makes the package)<!-- BUILD:END -->

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
- Windows Security may flag `version.dll` (the mod loader) as **Trojan:Win32/Posilod.CA!cl**. It did on the host's PC. Mod loaders get flagged because they pose as a Windows file. If it's blocked, no native mods load. Only if you downloaded it from the Nexus link above: Windows Security > Virus & threat protection > **Protection history** > that entry > Actions > **Restore** (or Allow on device). INSTALL.bat warns you if this happened.
- **Only for 5 or more players:** Party Limit Begone, **SE version** pak (https://www.nexusmods.com/baldursgate3/mods/327). Everyone needs it then. Never use the "standalone" version: it writes into the game folder.

## 2. Run INSTALL.bat

1. Right-click the zip > **Extract All...**
2. Close the game. Double-click **INSTALL.bat** in the extracted folder. If Windows says "Windows protected your PC", click **More info** > **Run anyway**.
3. It copies the Dark and Gate files into place and checks everything from step 1. Anything red has a link next to it: fix it and run INSTALL.bat again.
   - The "Installed files" section must say **MATCH**: that means you have exactly the host's build.
   - If it says "access denied", right-click INSTALL.bat > **Run as administrator**.
4. If you install or update WASD or Native Camera Tweaks **after** this, run INSTALL.bat again. Their own settings file replaces ours.

Before replacing anything, INSTALL.bat backs it up to `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\DarkAndGate-backup-<date>\`.

## 3. Turn the mods on (load order)

1. Start the game once to the main menu and quit, if you never have.
2. Open **BG3 Mod Manager** and click **Refresh**.
3. Drag these from **Inactive** to **Active**, in this order, exactly like the host. Leave every other mod inactive:

<!-- HOST-LOAD-ORDER:BEGIN -->
1. **Mod Configuration Menu** (version 1.41.0.0)
2. **AnimationUnlocker** (version 1.0.5.5)
3. **DarkAndGate** (version 1.0.0.0)
<!-- HOST-LOAD-ORDER:END -->

4. **File > Export Order to Game** (Ctrl+E). Close the Mod Manager.

Run INSTALL.bat again afterwards if you want to check: its "Load order" list should be all green.

## 4. Launch and check the console

1. Launch from Steam and pick **DirectX 11** in the Larian launcher. The host plays DX11, and Vulkan is untested.
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
2. Open the newest `DarkAndGate-backup-<date>` folder in `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\`. `RESTORE.txt` there lists every file the installer touched: copy the backed-up ones back, and delete the ones marked NEW (`DarkAndGate.pak`, `DarkAndGate.dll`, and `ScriptExtenderSettings.json` if it was created).
3. The other mods: delete their files the same way you added them. Steam's **Verify integrity of game files** won't remove extra files, so this step is manual.
