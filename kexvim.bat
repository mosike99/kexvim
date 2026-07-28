@echo off
chcp 65001 >nul
title Kexvim
set "SCRIPT_DIR=%~dp0"
set "KEXVIM_DIR=%USERPROFILE%\.kexvim"

REM 如果传了参数（init/update/restart），直接转发
if not "%1"=="" goto :run

REM 没传参数 → 自动模式
:auto
if exist "%KEXVIM_DIR%\kexvim.js" (
    if exist "%KEXVIM_DIR%\data\.env" (
        echo [~] 启动 Kexvim...
        node "%KEXVIM_DIR%\kexvim.js" restart
    ) else (
        echo [~] 首次运行，配置 API Key...
        node "%KEXVIM_DIR%\kexvim.js" init
        echo.
        node "%KEXVIM_DIR%\kexvim.js" restart
    )
) else (
    echo [~] 首次运行，下载 kexvim.js...
    mkdir "%KEXVIM_DIR%" 2>nul
    powershell -Command "Invoke-WebRequest -Uri 'https://gitee.com/moscowzk/kexvim/raw/main/kexvim.js' -OutFile '%KEXVIM_DIR%\kexvim.js'"
    if not exist "%KEXVIM_DIR%\kexvim.js" (
        echo [✗] 下载失败，检查网络
        pause & exit /b 1
    )
    echo [✓] 下载完成
    node "%KEXVIM_DIR%\kexvim.js" init
    echo.
    node "%KEXVIM_DIR%\kexvim.js" restart
)
pause
exit /b 0

:run
node "%KEXVIM_DIR%\kexvim.js" %*
pause
