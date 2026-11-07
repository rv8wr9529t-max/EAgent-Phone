@echo off
chcp 65001 >nul
cd /d "%~dp0"
title EAgent 手机遥控服务
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=[IO.File]::ReadAllText('%~dp0Agent_runtime.txt',[Text.Encoding]::UTF8); & ([scriptblock]::Create($c)) -ScriptRootDir '%~dp0' %~1 %~2 %~3 %~4 %~5 %~6"
pause
