@echo off
chcp 65001 > nul
cd /d "%~dp0"

rem GitHub の最新版に更新する (ZIP のダウンロードと展開を自動で行う)
powershell -NoProfile -ExecutionPolicy Bypass -File "update.ps1"
echo.
pause
