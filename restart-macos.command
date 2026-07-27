#!/bin/bash
# Kexvim 重启 (macOS) — 双击此文件运行

clear
echo "===================================="
echo "    正在重启 Kexvim..."
echo "===================================="

# Kill old process
pkill -f "node kexvim.js" 2>/dev/null
sleep 2

# Start new process
cd ~/.kexvim
nohup node kexvim.js > /dev/null 2>&1 &

sleep 1
if pgrep -f "node kexvim.js" > /dev/null; then
    echo "✅ Kexvim 已重启"
    osascript -e 'display notification "Kexvim 已重启" with title "Kexvim"'
else
    echo "❌ 启动失败，检查 ~/.kexvim/data/.env"
fi

echo ""
read -p "按 Enter 关闭此窗口..."
