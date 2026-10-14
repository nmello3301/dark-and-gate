@echo off
rem Dark and Gate friend installer: runs install.ps1 next to this file.
rem Extra arguments are passed on, e.g.  INSTALL.bat -WhatIf
rem                                  or  INSTALL.bat -GameRoot "D:\Games\Baldurs Gate 3"
title Dark and Gate - install
if exist "%~dp0install.ps1" goto run
echo.
echo install.ps1 is not next to INSTALL.bat.
echo Extract the WHOLE zip first: right-click the zip, choose "Extract All...",
echo then double-click INSTALL.bat inside the extracted folder.
echo.
pause
exit /b 1

:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
