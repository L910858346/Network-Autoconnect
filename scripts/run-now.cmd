@echo off
chcp 65001 >nul
setlocal
echo ==== 联通校园网自动连接（手动运行） ====
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\src\Connect-CampusNet.ps1" %*
set RC=%ERRORLEVEL%
echo.
echo [退出码] %RC%   （0=已联网  1=超时未认证  2=没有无线网卡）
echo.
pause
