@echo off
chcp 65001 > nul
cd /d "%~dp0"

rem 設定コンソールを直接開く (実行ポリシーの影響を受けない入口)
net session > nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cpu-console.ps1"
if errorlevel 1 pause
