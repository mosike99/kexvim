@echo off
set "DIR=%USERPROFILE%\.kexvim"
set REPO=https://gitee.com/moscowzk/kexvim

REM 1. Check / install Node.js
where node >nul 2>nul || (
    if not exist "%DIR%\node.exe" (
        echo [~] Downloading Node.js...
        mkdir "%DIR%" 2>nul
        powershell -Command "iwr 'https://nodejs.org/dist/v22.0.0/win-x64/node.exe' -OutFile '%DIR%\node.exe'" >nul 2>nul
    )
    set "PATH=%DIR%;%PATH%"
)

REM 2. Download kexvim.js if missing
if not exist "%DIR%\kexvim.js" (
    echo [~] Downloading kexvim.js...
    mkdir "%DIR%" 2>nul
    powershell -Command "iwr '%REPO%/raw/main/kexvim.js' -OutFile '%DIR%\kexvim.js'" >nul 2>nul
)

REM 3. Launch
if not exist "%DIR%\data\.env" goto :setup
if not "%1"=="" goto :args

:run
powershell -WindowStyle Hidden -Command "Start-Process -WindowStyle Hidden -FilePath 'node' -ArgumentList '\"%DIR%\kexvim.js\"' -WorkingDirectory '%DIR%'" >nul 2>&1
echo Kexvim started in background
echo Press any key to close this window
pause >nul
exit /b 0

:setup
node "%DIR%\kexvim.js" %*
if exist "%DIR%\data\.env" (
    echo.
    echo Kexvim ready. Press any key to start
    pause >nul
    powershell -WindowStyle Hidden -Command "Start-Process -WindowStyle Hidden -FilePath 'node' -ArgumentList '\"%DIR%\kexvim.js\"' -WorkingDirectory '%DIR%'" >nul 2>&1
)
exit /b 0

:args
node "%DIR%\kexvim.js" %*
pause
