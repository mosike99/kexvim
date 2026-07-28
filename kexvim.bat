@echo off
chcp 65001 >nul
title Kexvim

set KEXVIM_DIR=%USERPROFILE%\.kexvim
set REPO_URL=https://gitee.com/moscowzk/kexvim

if /i "%1"=="init" goto :init
if /i "%1"=="update" goto :update
if /i "%1"=="restart" goto :restart
echo 用法: kexvim.bat {init^|update^|restart}
pause
exit /b 1

:init
if exist "%KEXVIM_DIR%\kexvim.js" (
    echo Kexvim 已安装
    pause
    exit /b 0
)

REM 检测 git
where git >nul 2>nul
if %errorlevel% equ 0 (
    echo [~] 克隆仓库...
    git clone --depth 1 %REPO_URL% "%KEXVIM_DIR%" || (echo [✗] 克隆失败 & pause & exit /b 1)
) else (
    echo [~] 下载 release 包...
    mkdir "%KEXVIM_DIR%" 2>nul
    curl -fsSL "%REPO_URL%/repository/archive/main.zip" -o "%TEMP%\kexvim.zip" || (echo [✗] 下载失败 & pause & exit /b 1)
    powershell -Command "Expand-Archive -Path '%TEMP%\kexvim.zip' -DestinationPath '%TEMP%\kexvim-tmp' -Force; Copy-Item '%TEMP%\kexvim-tmp\kexvim-main\*' '%KEXVIM_DIR%' -Recurse -Force; Remove-Item '%TEMP%\kexvim-tmp' -Recurse -Force; Remove-Item '%TEMP%\kexvim.zip' -Force"
)

REM API Key
if not exist "%KEXVIM_DIR%\data" mkdir "%KEXVIM_DIR%\data"
set /p KEY=请输入 DeepSeek API Key:
if not "%KEY%"=="" (
    echo DEEPSEEK_API_KEY=%KEY% > "%KEXVIM_DIR%\data\.env"
    echo KEXVIM_HOME=%KEXVIM_DIR% >> "%KEXVIM_DIR%\data\.env"
    echo [✓] API Key 已保存
)
echo [✓] 安装完成。运行 kexvim.bat restart 启动
pause
exit /b 0

:update
if not exist "%KEXVIM_DIR%" (echo [✗] 未安装 Kexvim & pause & exit /b 1)

where git >nul 2>nul
if %errorlevel% equ 0 (
    echo [~] git pull...
    cd /d "%KEXVIM_DIR%" && git pull --ff-only || (echo [✗] 拉取失败 & pause & exit /b 1)
) else (
    echo [~] 下载更新...
    curl -fsSL "%REPO_URL%/repository/archive/main.zip" -o "%TEMP%\kexvim.zip" || (echo [✗] 下载失败 & pause & exit /b 1)
    powershell -Command "Expand-Archive -Path '%TEMP%\kexvim.zip' -DestinationPath '%TEMP%\kexvim-tmp' -Force; Copy-Item '%TEMP%\kexvim-tmp\kexvim-main\kexvim.js' '%KEXVIM_DIR%' -Force; Remove-Item '%TEMP%\kexvim-tmp' -Recurse -Force; Remove-Item '%TEMP%\kexvim.zip' -Force"
)
echo [✓] 更新完成，正在重启...
goto :restart

:restart
if not exist "%KEXVIM_DIR%\kexvim.js" (echo [✗] 未安装 Kexvim & pause & exit /b 1)
echo [~] 停止旧进程...
taskkill /f /im node.exe 2>nul
timeout /t 2 /nobreak >nul
echo [~] 启动...
cd /d "%KEXVIM_DIR%"
start powershell -NoExit -Command "cd '%KEXVIM_DIR%'; node kexvim.js"
echo [✓] Kexvim 已启动
timeout /t 3 /nobreak >nul
