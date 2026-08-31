@echo off
chcp 65001 > nul
cd /d "%~dp0"

rem 画面が黒いまま操作できないときの復旧 (管理者にしないこと: デスクトップを通常権限で起動するため)
powershell -NoProfile -ExecutionPolicy Bypass -File "99-fix-black-screen.ps1"
echo.
pause
