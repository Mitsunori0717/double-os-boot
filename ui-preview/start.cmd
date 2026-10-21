@echo off
setlocal
rem Edge Box UI preview: every screen in one window. Saving a preview file reopens it automatically.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0preview.ps1"
if errorlevel 1 pause
