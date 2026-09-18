@echo off
rem EdgeBox-Setup.exe の中から呼ばれる導入の入口
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
