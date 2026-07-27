#!/bin/bash
# Kexvim 看门狗 (macOS) — 双击或在终端运行

cd ~/.kexvim

cleanup() {
    echo "[watchdog] 关闭 kexvim..."
    kill $KEXVIM_PID 2>/dev/null
    rm -f .stop_watchdog
    exit 0
}

trap cleanup SIGTERM SIGINT

while true; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 启动 kexvim..."
    node kexvim.js &
    KEXVIM_PID=$!
    wait $KEXVIM_PID

    if [ -f .stop_watchdog ]; then
        rm -f .stop_watchdog
        echo "kexvim 已停止"
        read -p "按 Enter 关闭此窗口..."
        exit 0
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] kexvim 退出，2 秒后重启..."
    sleep 2
done
