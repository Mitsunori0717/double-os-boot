@echo off
setlocal
chcp 65001 > nul
pushd "%~dp0" || exit /b 1
set "EDGEBOX_LAUNCH_DIR=%CD%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $principal=[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent(); if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { & '.\00-field-launcher.ps1'; exit $LASTEXITCODE }; $child=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -WorkingDirectory $env:EDGEBOX_LAUNCH_DIR -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File .\00-field-launcher.ps1' -Verb RunAs -PassThru -Wait; exit $child.ExitCode"
set "launchExit=%errorlevel%"
popd
pause
exit /b %launchExit%
