@echo off
set "DIR=%USERPROFILE%\.kexvim"
set REPO=https://gitee.com/moscowzk/kexvim
set NODEVER=v22.0.0

REM 1. Check / install Node.js (full zip with npm)
where node >nul 2>nul || (
    if not exist "%DIR%\node\node.exe" (
        echo [~] Downloading Node.js %NODEVER%...
        mkdir "%DIR%" 2>nul
        powershell -NoProfile -Command "iwr 'https://nodejs.org/dist/%NODEVER%/node-%NODEVER%-win-x64.zip' -OutFile '%DIR%\node.zip'" >nul 2>nul
        powershell -NoProfile -Command "Expand-Archive -Path '%DIR%\node.zip' -DestinationPath '%DIR%' -Force" >nul 2>nul
        move /y "%DIR%\node-%NODEVER%-win-x64" "%DIR%\node" >nul 2>nul
        del "%DIR%\node.zip" 2>nul
    )
    set "PATH=%DIR%\node;%PATH%"
)

REM 2. Download kexvim.js + package.json if missing
if not exist "%DIR%\kexvim.js" (
    echo [~] Downloading kexvim.js...
    mkdir "%DIR%" 2>nul
    powershell -Command "iwr '%REPO%/raw/main/kexvim.js' -OutFile '%DIR%\kexvim.js'" >nul 2>nul
    powershell -Command "iwr '%REPO%/raw/main/package.json' -OutFile '%DIR%\package.json'" >nul 2>nul
    echo [~] Downloading skills...
    where git >nul 2>nul && (
        mkdir "%DIR%\skills" 2>nul
        powershell -NoProfile -Command "$tmp = Join-Path $env:TMP 'kexvim-skills'; if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }; git clone --depth 1 '%REPO%.git' $tmp --single-branch 2>$null; if (Test-Path (Join-Path $tmp 'skills')) { Copy-Item (Join-Path $tmp 'skills\*') '%DIR%\skills\' -Recurse -Force }; Remove-Item $tmp -Recurse -Force"
    )
)

REM 3. Install dependencies if missing (kexvim.js needs external modules: cron/js-yaml/ws/MCP SDK)
if not exist "%DIR%\node_modules\cron" (
    echo [~] Installing dependencies...
    cd /d "%DIR%"
    call "%DIR%\node\npm.cmd" install --omit=dev --no-audit --no-fund
    if errorlevel 1 (
        echo [X] npm install failed. Please install Node.js v22+ from https://nodejs.org
        pause
        exit /b 1
    )
)

REM 4. Launch (multi-thread: watchdog + agent + guardian)
"%DIR%\node\node.exe" "%DIR%\kexvim.js" %*
