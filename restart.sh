#!/bin/bash
# Kexvim 重启脚本 (Linux/macOS)
# 用法: bash restart.sh

echo "正在重启 Kexvim..."

# Kill old process
pkill -f "node kexvim.js" 2>/dev/null
sleep 2

# Start new process
cd ~/.kexvim
nohup node kexvim.js > /dev/null 2>&1 &
sleep 1

if pgrep -f "node kexvim.js" > /dev/null; then
    echo "[✓] Kexvim 已重启"
else
    echo "[✗] 启动失败，检查 ~/.kexvim/data/.env 和日志"
fi
