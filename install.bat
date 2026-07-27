@echo off
chcp 65001 >nul
title Sage 安装程序
setlocal enabledelayedexpansion

echo ====================================
echo    Sage 一键安装 (Windows)
echo ====================================
echo.

set SAGE_DIR=%USERPROFILE%\.sage

REM 1. 检查 Node.js
where node >nul 2>nul
if %errorlevel% neq 0 (
    echo [!] 未安装 Node.js，请从 https://nodejs.org 下载 LTS 版
    start https://nodejs.org
    pause
    exit /b 1
)

for /f "tokens=1 delims=v" %%a in ('node -v') do set node_ver=%%a
echo [✓] Node.js v%node_ver%
echo.

REM 2. 检查 git
where git >nul 2>nul
if %errorlevel% neq 0 (
    echo [!] 未安装 Git，请从 https://git-scm.com/download/win 下载
    start https://git-scm.com/download/win
    pause
    exit /b 1
)

REM 3. 从公开 Release 仓克隆（浅克隆，只有最新文件）
echo [~] 下载 Sage...
if exist "%SAGE_DIR%" rmdir /s /q "%SAGE_DIR%"
git clone --depth 1 https://gitee.com/moscowzk/sage.git "%SAGE_DIR%"
echo [✓] 下载完成

REM 4. 配置 API Key
set ENV_FILE=%SAGE_DIR%\data\.env
if not exist "%ENV_FILE%" (
    echo.
    echo [~] 配置 API Key
    if not exist "%SAGE_DIR%\data" mkdir "%SAGE_DIR%\data"
    set /p DS_KEY=请输入 DeepSeek API Key: 
    if not "!DS_KEY!"=="" (
        echo DEEPSEEK_API_KEY=!DS_KEY!> "%ENV_FILE%"
        echo [✓] API Key 已保存
    )
)

REM 5. 桌面快捷方式
set SHORTCUT=%USERPROFILE%\Desktop\Sage.lnk
if not exist "%SHORTCUT%" (
    powershell -Command "$WS = New-Object -ComObject WScript.Shell; $SC = $WS.CreateShortcut('%SHORTCUT%'); $SC.TargetPath = 'powershell.exe'; $SC.Arguments = '-NoExit -Command cd ''%SAGE_DIR%''; npm start'; $SC.Description = 'Sage AI Assistant'; $SC.Save()"
    if exist "%SHORTCUT%" echo [✓] 桌面快捷方式已创建
)

echo.
echo ====================================
echo  安装完成！
echo  双击桌面 [Sage] 快捷方式启动
echo  或终端: cd %SAGE_DIR% ^&^& npm start
echo ====================================
echo.

set /p START_NOW=是否立即启动 Sage？（y/N）: 
if /i "!START_NOW!"=="y" (
    start powershell -NoExit -Command "cd '%SAGE_DIR%'; npm start"
)

pause
