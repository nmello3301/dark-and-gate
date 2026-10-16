@echo off
rem Dark and Gate installer: installs the prerequisites and Dark and Gate from
rem the downloads in this folder (runs install.ps1 next to this file).
rem Extra arguments are passed on, e.g.  INSTALL.bat -WhatIf
rem                                  or  INSTALL.bat -KeepMySettings
rem                                  or  INSTALL.bat -GameRoot "D:\SteamLibrary\steamapps\common\Baldurs Gate 3"
title Dark and Gate - install
if exist "%~dp0install.ps1" goto run
echo.
echo install.ps1 is not next to INSTALL.bat.
echo Extract the WHOLE installer zip into your downloads folder first, then
echo double-click INSTALL.bat there.
echo.
pause
exit /b 1

:run
rem A plain PowerShell call: it runs install.ps1 from this folder, nothing is
rem hidden, encoded or downloaded. "-ExecutionPolicy Bypass" applies to this
rem one run only (Windows blocks unsigned scripts by default); it changes no
rem setting on the PC.
echo Running: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
