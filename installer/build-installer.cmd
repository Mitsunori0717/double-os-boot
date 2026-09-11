@echo off
chcp 932 >nul
setlocal
title EdgeBox セットアップ EXE の作成

echo ==============================================
echo  EdgeBox-Setup.exe を作ります
echo ==============================================
echo.

set "HERE=%~dp0"
set "OUT=%HERE%EdgeBox-Setup.exe"

powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%build-installer.ps1" -OutFile "%OUT%"

echo.
if exist "%OUT%" (
  echo 完成しました:
  echo   %OUT%
  echo.
  echo このファイルを新しい PC にコピーし、右クリック →「管理者として実行」で導入できます。
) else (
  echo 作成に失敗しました。上の表示を確認してください。
)
echo.
pause
