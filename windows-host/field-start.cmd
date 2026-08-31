@echo off
chcp 65001 > nul
cd /d "%~dp0"

rem EdgeBox (FIELD system) をワンクリックで起動する入口
rem VM があればそのまま起動し、無ければ作成してから起動します
net session > nul 2>&1
if errorlevel 1 (
    echo 管理者として開き直します...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "00-field-launcher.ps1"
echo.
pause
