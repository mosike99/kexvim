@echo off
title Kexvim
setlocal enabledelayedexpansion

set "KEXVIM_DIR=%USERPROFILE%\.kexvim"
set REPO_URL=https://gitee.com/moscowzk/kexvim
set HAS_ERROR=0

REM 0. 确保 Node.js 可用（没有就自动下载便携版）
:ensure_node
where node >nul 2>nul
if %errorlevel% equ 0 goto :node_ok
if exist "%KEXVIM_DIR%\node.exe" (
    set "PATH=%KEXVIM_DIR%;%PATH%"
    goto :node_ok
)
echo [~] 正在下载 Node.js（首次运行需要）...
mkdir "%KEXVIM_DIR%" 2>nul
powershell -Command "Invoke-WebRequest -Uri 'https://nodejs.org/dist/v22.0.0/win-x64/node.exe' -OutFile '%KEXVIM_DIR%\node.exe'" >nul 2>nul
if not exist "%KEXVIM_DIR%\node.exe" (
    echo [x] Node.js 下载失败，请手动安装 https://nodejs.org
    pause & exit /b 1
)
set "PATH=%KEXVIM_DIR%;%PATH%"
echo [v] Node.js 就绪
:node_ok

REM 有参数 → 转发给 kexvim.js
if not "%1"=="" (
    if not exist "%KEXVIM_DIR%\kexvim.js" (echo [!] 还没安装，先双击此脚本 & pause & exit /b 1)
    node "%KEXVIM_DIR%\kexvim.js" %*
    pause
    exit /b 0
)

echo ===================================
echo        Kexvim
echo ===================================
echo.
echo 默认路径: %KEXVIM_DIR%
set /p CHANGE_PATH=改路径？(y/N):
echo !CHANGE_PATH!|findstr /i "^y$" >nul && (
    set /p KEXVIM_DIR=新路径:
    echo 使用: !KEXVIM_DIR!
)
echo.

REM 1. 下载 kexvim.js
if not exist "%KEXVIM_DIR%\kexvim.js" (
    echo [~] 下载 kexvim.js...
    mkdir "%KEXVIM_DIR%" 2>nul
    powershell -Command "Invoke-WebRequest -Uri '%REPO_URL%/raw/main/kexvim.js' -OutFile '%KEXVIM_DIR%\kexvim.js'" >nul 2>nul
    if exist "%KEXVIM_DIR%\kexvim.js" (
        echo [v] 下载完成
    ) else (
        echo [x] 下载失败，检查网络
        set HAS_ERROR=1
    )
)

REM 2. 配置 API Key
if not exist "%KEXVIM_DIR%\data\.env" (
    echo.
    echo [~] 首次运行，配置 API Key
    if not exist "%KEXVIM_DIR%\data" mkdir "%KEXVIM_DIR%\data"
    set /p KEY=请输入 DeepSeek API Key:
    if not "!KEY!"=="" (
        echo DEEPSEEK_API_KEY=!KEY!> "%KEXVIM_DIR%\data\.env"
        echo KEXVIM_HOME=%KEXVIM_DIR%>> "%KEXVIM_DIR%\data\.env"
        echo [v] API Key 已保存
    ) else (
        echo [!] 跳过，稍后运行: kexvim.bat init
    )
)

echo.

if %HAS_ERROR%==1 (
    echo [x] 安装未完成
) else (
    echo [v] Kexvim 就绪
    echo.
    echo   命令:
    echo     kexvim             启动
    echo     kexvim restart     重启
    echo     kexvim update      更新
    echo     kexvim --help      帮助
    echo.
    echo   再次双击此脚本即可启动
    echo.
    echo   启动试试: kexvim.bat restart
)

pause
