@echo off
chcp 65001 >nul
set NODE_NO_WARNINGS=1
set "DIR=%USERPROFILE%\.kexvim"
set REPO=https://gitee.com/moscowzk/kexvim
set NODEVER=v22.18.0

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

REM 1b. Verify bundled node meets minimum version (node:sqlite needs >=22.5)
if exist "%DIR%\node\node.exe" (
    "%DIR%\node\node.exe" -e "process.exit(parseInt(process.versions.node.split('.')[1]) >= 5 ? 0 : 1)" >nul 2>nul
    if errorlevel 1 (
        echo [~] Node too old, re-downloading %NODEVER%...
        rmdir /s /q "%DIR%\node" 2>nul
        powershell -NoProfile -Command "iwr 'https://nodejs.org/dist/%NODEVER%/node-%NODEVER%-win-x64.zip' -OutFile '%DIR%\node.zip'" >nul 2>nul
        powershell -NoProfile -Command "Expand-Archive -Path '%DIR%\node.zip' -DestinationPath '%DIR%' -Force" >nul 2>nul
        move /y "%DIR%\node-%NODEVER%-win-x64" "%DIR%\node" >nul 2>nul
        del "%DIR%\node.zip" 2>nul
    )
)

REM 2. Download kexvim.js if missing
if not exist "%DIR%\kexvim.js" (
    echo [~] Downloading kexvim.js...
    mkdir "%DIR%" 2>nul
    powershell -Command "iwr '%REPO%/raw/main/kexvim.js' -OutFile '%DIR%\kexvim.js'" >nul 2>nul
)

REM 2b. Download package.json if missing
if not exist "%DIR%\package.json" (
    echo [~] Downloading package.json...
    mkdir "%DIR%" 2>nul
    powershell -Command "iwr '%REPO%/raw/main/package.json' -OutFile '%DIR%\package.json'" >nul 2>nul
)

REM 2c. Download skills if missing
if not exist "%DIR%\skills" (
    echo [~] Downloading skills...
    where git >nul 2>nul && (
        mkdir "%DIR%\skills" 2>nul
        powershell -NoProfile -Command "$tmp = Join-Path $env:TMP 'kexvim-skills'; if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }; git clone --depth 1 '%REPO%.git' $tmp --single-branch 2>$null; if (Test-Path (Join-Path $tmp 'skills')) { Copy-Item (Join-Path $tmp 'skills\*') '%DIR%\skills\' -Recurse -Force }; Remove-Item $tmp -Recurse -Force"
    )
)

REM 2d. Locate bundled portable node/npm (if downloaded); else fall back to system commands
set "NODEEXE=%DIR%\node\node.exe"
set "NPMCMD=%DIR%\node\npm.cmd"

REM 3. Install dependencies if missing (kexvim.js needs external modules: cron/js-yaml/ws/MCP SDK)
if not exist "%DIR%\node_modules\cron" (
    echo [~] Installing dependencies...
    cd /d "%DIR%"
    if exist "%NPMCMD%" (
        call "%NPMCMD%" install --omit=dev --no-audit --no-fund
    ) else (
        call npm install --omit=dev --no-audit --no-fund
    )
    if errorlevel 1 (
        echo [X] npm install failed. Please install Node.js v22+ from https://nodejs.org
        pause
        exit /b 1
    )
)

REM 4. First-run init (idempotent marker: data/.env, same as kexvim.js init)
if not exist "%DIR%\data\.env" (
    echo.
    echo [~] kexvim not initialized yet. Running first-time setup...
    echo [~] You will be prompted for your API key. Keep this window open.
    echo.
    REM 必须先 cd 到安装目录：kexvim.js init 按 cwd 回溯找项目根（data 定位规则），
    REM 不 cd 会解析到 bat 所在目录（如 D:\kexvim）→ 配置写错位置（2026-08-10 实锤 cwd 漂移）。
    REM cd to the install dir first: kexvim.js resolves data by walking up from cwd,
    REM so a bare double-click would write config next to the bat (cwd drift, proven).
    cd /d "%DIR%"
    if exist "%NODEEXE%" (
        "%NODEEXE%" "%DIR%\kexvim.js" init
    ) else (
        node "%DIR%\kexvim.js" init
    )
    if not exist "%DIR%\data\.env" (
        echo.
        echo [X] API Key 未配置，安装未完成。请重新运行本脚本，或执行: kexvim init
        pause
        exit /b 1
    )
    echo [~] 初始化完成
)

REM 4b. Explicit args passthrough (kexvim.bat restart / stop / status ...)
if not "%~1"=="" (
    cd /d "%DIR%"
    if exist "%NODEEXE%" (
        "%NODEEXE%" "%DIR%\kexvim.js" %*
    ) else (
        node "%DIR%\kexvim.js" %*
    )
    exit /b %errorlevel%
)

REM 5. Detect running state (pid file + process liveness, same as kexvim status)
set "KEXVIM_STATE=STOPPED"
if exist "%DIR%\data" (
    if exist "%NODEEXE%" (
        "%NODEEXE%" -e "try{const s=require('fs');const p=+s.readFileSync(process.argv[1]+'/data/kexvim.pid','utf8');process.kill(p,0);process.stdout.write('RUNNING')}catch{process.stdout.write('STOPPED')}" "%DIR%" > "%DIR%\data\_state.tmp" 2>nul
    ) else (
        node -e "try{const s=require('fs');const p=+s.readFileSync(process.argv[1]+'/data/kexvim.pid','utf8');process.kill(p,0);process.stdout.write('RUNNING')}catch{process.stdout.write('STOPPED')}" "%DIR%" > "%DIR%\data\_state.tmp" 2>nul
    )
    set /p KEXVIM_STATE=<"%DIR%\data\_state.tmp"
    del "%DIR%\data\_state.tmp" >nul 2>nul
)

echo.
echo %KEXVIM_STATE% | findstr /i "RUNNING" >nul
if not errorlevel 1 (
    echo [~] kexvim 已在运行
) else (
    echo [~] kexvim 未运行，正在启动...
    cd /d "%DIR%"
    if exist "%NODEEXE%" (
        "%NODEEXE%" "%DIR%\kexvim.js" restart
    ) else (
        node "%DIR%\kexvim.js" restart
    )
)

REM 6. Print web address + command cheat-sheet
echo.
echo ================================================
echo   安装完成。窗口保持打开，请查看上方日志确认
echo   「kexvim 已就绪 / Web UI: 8788」后手动关闭本窗口
echo ================================================
echo   kexvim 已就绪
echo   Web UI:  http://localhost:8788
echo ------------------------------------------------
echo   常用命令:
echo     kexvim restart    重启 kexvim（daemon + web）
echo     kexvim stop       停止 kexvim
echo     kexvim status     查看运行状态
echo     kexvim init       重新配置 API Key
echo     kexvim install    设置开机自启
echo     kexvim sessions   查看历史会话
echo ================================================
cmd /k
