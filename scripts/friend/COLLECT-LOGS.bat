@echo off
rem Dark and Gate: zip this PC's logs onto the Desktop (works while the game runs).
title Dark and Gate - collect logs
if exist "%~dp0mp-collect-logs.ps1" goto run
echo.
echo mp-collect-logs.ps1 is not next to COLLECT-LOGS.bat.
echo Extract the WHOLE zip first, then run COLLECT-LOGS.bat from the extracted folder.
echo.
pause
exit /b 1

:run
rem A plain PowerShell call (see INSTALL.bat): it only reads logs and writes
rem one zip to the Desktop. "-ExecutionPolicy Bypass" is for this run only.
echo Running: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0mp-collect-logs.ps1" -Reveal %*
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0mp-collect-logs.ps1" -Reveal %*
echo.
pause
