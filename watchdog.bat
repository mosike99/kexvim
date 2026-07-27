@echo off
chcp 65001 >nul
title Kexvim 看门狗

cd /d "%USERPROFILE%\.kexvim"

:Loop
echo [%date% %time%] 启动 kexvim...
node kexvim.js
if exist "%USERPROFILE%\.kexvim\.stop_watchdog" (
    del "%USERPROFILE%\.kexvim\.stop_watchdog"
    echo [%date% %time%] 看门狗已停止
    timeout /t 3 /nobreak >nul
    exit /b 0
)
echo [%date% %time%] kexvim 退出，2 秒后重启...
timeout /t 2 /nobreak >nul
goto Loop
