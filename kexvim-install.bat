@echo off
chcp 65001 >nul
set NODE_NO_WARNINGS=1
if defined KEXVIM_HOME (set "DIR=%KEXVIM_HOME%") else (set "DIR=%USERPROFILE%\.kexvim")
set REPO=https://gitee.com/moscowzk/kexvim
set NODEVER=v22.18.0

REM ============================================================
REM  kexvim installer (minimal) - 2026-09-09
REM  This script does ONLY:
REM    1. ensure Node.js >=22.5 (the sole dependency installed here)
REM    2. download kexvim.js (skip when present)
REM    3. launch the installer process: node kexvim.js bootstrap
REM       (deps + example configs + shell exe + init + start)
REM  With arguments it forwards them to kexvim.js directly.
REM ============================================================

REM -- 1. Node.js >=22.5 (node:sqlite); portable copy auto-downloaded when missing/too old
set "NODEEXE=%DIR%\node\node.exe"
if not exist "%NODEEXE%" set "NODEEXE=node"
"%NODEEXE%" -e "const v=process.versions.node.split('.').map(Number);process.exit(v[0]>22||(v[0]===22&&v[1]>=5)?0:1)" >nul 2>nul
if errorlevel 1 (
    echo [~] Downloading Node.js %NODEVER%...
    mkdir "%DIR%" 2>nul
    powershell -NoProfile -Command "iwr 'https://nodejs.org/dist/%NODEVER%/node-%NODEVER%-win-x64.zip' -OutFile '%DIR%\node.zip'" >nul 2>nul
    powershell -NoProfile -Command "Expand-Archive -Path '%DIR%\node.zip' -DestinationPath '%DIR%' -Force" >nul 2>nul
    if exist "%DIR%\node" rmdir /s /q "%DIR%\node"
    move /y "%DIR%\node-%NODEVER%-win-x64" "%DIR%\node" >nul 2>nul
    del "%DIR%\node.zip" 2>nul
    set "NODEEXE=%DIR%\node\node.exe"
)

REM -- 2. kexvim code (skip download when present)
if not exist "%DIR%\kexvim.js" (
    echo [~] Downloading kexvim.js...
    mkdir "%DIR%" 2>nul
    powershell -NoProfile -Command "iwr '%REPO%/raw/main/kexvim.js' -OutFile '%DIR%\kexvim.js'" >nul 2>nul
)

cd /d "%DIR%"

REM -- 3. run: args passthrough; no args -> installer process
if not "%~1"=="" goto forward
"%NODEEXE%" "%DIR%\kexvim.js" bootstrap
goto keep

:forward
"%NODEEXE%" "%DIR%\kexvim.js" %*
exit /b %errorlevel%

REM window stays open for double-click runs (no args)
:keep
timeout /t 10 >nul 2>nul
goto keep
