Dark and Gate - one-click installer
===================================

Installs Dark and Gate and everything it needs from a folder of downloads.
Windows, Steam version of Baldur's Gate 3.

1. Download these into ONE folder (leave them as zip / 7z / rar, or extract
   them there, either works):
     Script Extender (the updater)  https://github.com/Norbyte/bg3se/releases
     Ch4nKyy's Mod Loader           https://www.nexusmods.com/baldursgate3/mods/25474
     WASD Character Movement        https://www.nexusmods.com/baldursgate3/mods/781
     Native Camera Tweaks           https://www.nexusmods.com/baldursgate3/mods/945
     Mod Configuration Menu         https://www.nexusmods.com/baldursgate3/mods/9162
     AnimationUnlocker              https://www.nexusmods.com/baldursgate3/mods/16058
     Dark and Gate: DarkAndGate-<version>-mod.zip and -native.zip, and
       optionally -recommended-settings.zip
                                    https://github.com/nmello3301/dark-and-gate/releases
   Use Nexus's "Manual download" button. Do NOT add Native Mod Loader: Dark and
   Gate uses Ch4nKyy's Mod Loader, and two loaders load every native mod twice.

2. Start the game once to the main menu and quit (that creates your load
   order file), if you never have.

3. Put INSTALL.bat and install.ps1 into the same folder as the downloads.
   Close the game. Double-click INSTALL.bat.

It finds the game, backs up every file it replaces, installs everything,
puts Mod Configuration Menu > AnimationUnlocker > DarkAndGate at the end of
your load order (your other mods stay), turns the Script Extender console on,
and switches Dark and Gate on. It ends with a green READY, or a red list of
what is still missing with a link for each: download it into the same folder
and run INSTALL.bat again.

4. Start Baldur's Gate 3 in DirectX 11 (not Vulkan) and load a game.

Options (add them after INSTALL.bat in a Command Prompt):
  -WhatIf          show what would be installed, change nothing
  -KeepMySettings  keep your own Native Camera Tweaks / WASD settings
  -GameRoot "..."  the game folder, if it isn't found by itself

Undo: the backup folder it names (in %LOCALAPPDATA%\Larian Studios\
Baldur's Gate 3\DarkAndGate-backup-<time>) has RESTORE.txt with every file
it replaced or added.

If Windows Security removes version.dll (a known false positive for Ch4nKyy's
Mod Loader), the installer says so and prints the commands to restore it.
