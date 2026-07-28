@echo off
chcp 65001 >nul
title Kexvim
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "KEXVIM_DIR=%USERPROFILE%\.kexvim"
set REPO_URL=https://gitee.com/moscowzk/kexvim
set HAS_ERROR=0

REM 有参数 → 直接转发
if not "%1"=="" (
    if not exist "%KEXVIM_DIR%\kexvim.js" (echo [✗] 未安装，先双击此脚本自动安装 & pause & exit /b 1)
    node "%KEXVIM_DIR%\kexvim.js" %*
    pause
    exit /b 0
)

echo ===================================
echo        Kexvim
echo ===================================
echo.
echo 默认安装路径: %KEXVIM_DIR%
set /p CHANGE_PATH=是否更改路径？(y/N):
if /i "!CHANGE_PATH!"=="y" (
    set /p KEXVIM_DIR=输入新路径:
    echo 使用路径: !KEXVIM_DIR!
)
echo.

REM 1. 检查 kexvim.js
if not exist "%KEXVIM_DIR%\kexvim.js" (
    echo [~] 首次运行，下载 kexvim.js...
    mkdir "%KEXVIM_DIR%" 2>nul
    powershell -Command "Invoke-WebRequest -Uri '%REPO_URL%/raw/main/kexvim.js' -OutFile '%KEXVIM_DIR%\kexvim.js'" >nul 2>nul
    if exist "%KEXVIM_DIR%\kexvim.js" (
        echo [✓] kexvim.js 已下载
    ) else (
        echo [✗] 下载失败，检查网络连接
        set HAS_ERROR=1
    )
)

REM 2. 检查 API Key
if not exist "%KEXVIM_DIR%\data\.env" (
    echo.
    echo [~] 首次运行，需要配置 API Key
    if not exist "%KEXVIM_DIR%\data" mkdir "%KEXVIM_DIR%\data"
    set /p KEY=请输入 DeepSeek API Key:
    if not "!KEY!"=="" (
        echo DEEPSEEK_API_KEY=!KEY!> "%KEXVIM_DIR%\data\.env"
        echo KEXVIM_HOME=%KEXVIM_DIR%>> "%KEXVIM_DIR%\data\.env"
        echo [✓] API Key 已保存
    ) else (
        echo [!] 跳过，稍后可运行: kexvim.bat init
    )
)

echo.

if %HAS_ERROR%==1 (
    echo [✗] 安装未完成，请检查后重试
) else (
    echo [✓] Kexvim 已就绪
    echo.
    echo   常用命令:
    echo     kexvim             启动
    echo     kexvim restart     重启
    echo     kexvim update      更新
    echo     kexvim --help      帮助
    echo.
    echo   或直接双击此脚本启动
    echo.
    echo   启动试试:  kexvim.bat restart
)

pause
