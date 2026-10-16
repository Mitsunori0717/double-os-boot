@echo off
chcp 65001 >nul
setlocal
title Edge Box セットアップ EXE の作成

echo ==============================================
echo  EdgeBox-Setup.exe を作ります
echo ==============================================
echo.

set "HERE=%~dp0"
set "OUT=%HERE%EdgeBox-Setup.exe"

powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%build-installer.ps1" -OutFile "%OUT%"
set "buildExit=%errorlevel%"

echo.
if not "%buildExit%"=="0" (
  echo 作成に失敗しました。上の原因と調査用ファイルを確認してください。
) else if exist "%OUT%" (
  echo 完成しました:
  echo   %OUT%
  echo.
  echo このファイルを新しい PC にコピーし、右クリック →「管理者として実行」で導入できます。
) else (
  echo 作成に失敗しました。上の表示を確認してください。
)
echo.
pause
exit /b %buildExit%
