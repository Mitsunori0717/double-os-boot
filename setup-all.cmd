@echo off
chcp 65001 > nul
call "%~dp0setup\setup-all.cmd" %*
exit /b %errorlevel%
