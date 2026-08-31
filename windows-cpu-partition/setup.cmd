@echo off
chcp 65001 > nul
cd /d "%~dp0"

rem PowerShell の実行ポリシーに関係なく動かすための入口 (ダブルクリックで実行できます)
net session > nul 2>&1
if errorlevel 1 (
    echo 管理者として開き直します...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo ダウンロード由来のブロック (Mark of the Web) を解除しています...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -File -Recurse | Unblock-File -ErrorAction SilentlyContinue"

echo デスクトップに『CPU割り当て』アイコンを作成しています...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cpu-console.ps1" -Setup
echo.
pause
