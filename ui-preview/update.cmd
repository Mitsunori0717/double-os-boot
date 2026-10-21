@echo off
chcp 65001 > nul
rem Update this ui-preview folder from GitHub. Changed files are backed up to the backups folder first.
rem Everything runs on one line so cmd does not read this file again after it is replaced.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-preview.ps1" %* & echo. & pause & exit /b
