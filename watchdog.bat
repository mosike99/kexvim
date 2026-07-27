@echo off
chcp 65001 >nul
title Kexvim 看门狗

cd /d "%USERPROFILE%\.kexvim"

:Loop
echo [%date% %time%] 启动 kexvim...
node kexvim.js
echo [%date% %time%] kexvim 退出，2 秒后重启...
timeout /t 2 /nobreak >nul
goto Loop
