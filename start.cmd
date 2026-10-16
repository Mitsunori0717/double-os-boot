@echo off
chcp 65001 > nul
cd /d "%~dp0"

rem Edge Box をワンクリックで起動する入口 (update.cmd と同じ場所に置いた起動コマンド)
rem 中身は windows-host\field-start.cmd と同じ: 管理者でなければ UAC で開き直し、
rem Edge Box があればそのまま起動し、無ければ作成してから起動して左画面に表示します
call "%~dp0windows-host\field-start.cmd"
