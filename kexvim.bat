@echo off
chcp 65001 >nul
title Kexvim
set KEXVIM_DIR=%USERPROFILE%\.kexvim
if not exist "%KEXVIM_DIR%\kexvim.js" (
    echo [✗] 未安装。先运行: kexvim.bat init
    pause & exit /b 1
)
node "%KEXVIM_DIR%\kexvim.js" %*
