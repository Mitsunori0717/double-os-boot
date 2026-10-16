@echo off
chcp 65001 > nul
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-all.ps1" -Step 10 %*
set "setupExit=%errorlevel%"
exit /b %setupExit%
