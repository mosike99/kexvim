#!/bin/bash
# Kexvim 更新 (macOS) — 双击此文件运行

clear
echo "===================================="
echo "    更新 Kexvim..."
echo "===================================="

cd ~/.kexvim 2>/dev/null || {
    osascript -e 'display dialog "未找到 ~/.kexvim，先运行安装脚本" buttons {"确定"} default button 1'
    exit 1
}

echo "[~] 拉取最新代码..."
git pull || {
    osascript -e 'display dialog "拉取失败，检查网络" buttons {"确定"} default button 1'
    exit 1
}
echo "[✓] 更新完成"

echo "[~] 重启..."
pkill -f "node kexvim.js" 2>/dev/null
sleep 2
nohup node kexvim.js > /dev/null 2>&1 &

sleep 1
if pgrep -f "node kexvim.js" > /dev/null; then
    echo "✅ Kexvim 已重启"
    osascript -e 'display notification "Kexvim 已更新并重启" with title "Kexvim"'
else
    echo "❌ 启动失败"
fi

echo ""
read -p "按 Enter 关闭此窗口..."
