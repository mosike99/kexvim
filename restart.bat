@echo off
chcp 65001 >nul
title Kexvim 重启

echo ====================================
echo    正在重启 Kexvim...
echo ====================================

REM 杀掉旧进程
taskkill /f /im node.exe 2>nul 2>&1

REM 等 2 秒
timeout /t 2 /nobreak >nul

REM 启动
cd /d "%USERPROFILE%\.kexvim"
start powershell -NoExit -Command "cd '%USERPROFILE%\.kexvim'; npm start"

echo [✓] Kexvim 已重启
timeout /t 3 /nobreak >nul
