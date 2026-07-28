@echo off
title Kexvim
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "KEXVIM_DIR=%USERPROFILE%\.kexvim"
set REPO_URL=https://gitee.com/moscowzk/kexvim
set HAS_ERROR=0

REM With args -> forward to kexvim.js
if not "%1"=="" (
    if not exist "%KEXVIM_DIR%\kexvim.js" (echo [!] Not installed. Double-click this script first. & pause & exit /b 1)
    node "%KEXVIM_DIR%\kexvim.js" %*
    pause
    exit /b 0
)

echo ===================================
echo        Kexvim
echo ===================================
echo.
echo Default: %KEXVIM_DIR%
set /p CHANGE_PATH=Change? (y/N):
echo !CHANGE_PATH!|findstr /i "^y$" >nul && (
    set /p KEXVIM_DIR=New path:
    echo Using: !KEXVIM_DIR!
)
echo.

REM 1. Check kexvim.js
if not exist "%KEXVIM_DIR%\kexvim.js" (
    echo [~] Downloading kexvim.js...
    mkdir "%KEXVIM_DIR%" 2>nul
    powershell -Command "Invoke-WebRequest -Uri '%REPO_URL%/raw/main/kexvim.js' -OutFile '%KEXVIM_DIR%\kexvim.js'" >nul 2>nul
    if exist "%KEXVIM_DIR%\kexvim.js" (
        echo [v] Downloaded
    ) else (
        echo [x] Download failed
        set HAS_ERROR=1
    )
)

REM 2. Check API Key
if not exist "%KEXVIM_DIR%\data\.env" (
    echo.
    echo [~] First run - need API Key
    if not exist "%KEXVIM_DIR%\data" mkdir "%KEXVIM_DIR%\data"
    set /p KEY=Enter DeepSeek API Key:
    if not "!KEY!"=="" (
        echo DEEPSEEK_API_KEY=!KEY!> "%KEXVIM_DIR%\data\.env"
        echo KEXVIM_HOME=%KEXVIM_DIR%>> "%KEXVIM_DIR%\data\.env"
        echo [v] API Key saved
    ) else (
        echo [!] Skipped. Run: kexvim.bat init
    )
)

echo.

if %HAS_ERROR%==1 (
    echo [x] Setup incomplete
) else (
    echo [v] Kexvim ready
    echo.
    echo   Commands:
    echo     kexvim             start
    echo     kexvim restart     restart
    echo     kexvim update      update
    echo     kexvim --help      help
    echo.
    echo   Or double-click again to start
    echo.
    echo   Try: kexvim.bat restart
)

pause
