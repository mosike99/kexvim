@echo off
chcp 65001 >nul
title Kexvim 更新

echo ====================================
echo    更新 Kexvim...
echo ====================================

cd /d "%USERPROFILE%\.kexvim"

echo [~] 拉取最新代码...
git pull
if %errorlevel% neq 0 (
    echo [✗] 拉取失败，检查网络或 Git 配置
    pause
    exit /b 1
)
echo [✓] 更新完成

echo [~] 重启...
taskkill /f /im node.exe 2>nul
timeout /t 2 /nobreak >nul
start powershell -NoExit -Command "cd '%USERPROFILE%\.kexvim'; npm start"

echo [✓] Kexvim 已重启
timeout /t 3 /nobreak >nul
