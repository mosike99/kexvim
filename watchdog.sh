#!/bin/bash
# Kexvim 看门狗 — 退出后自动重启，支持优雅停止
#
# 启动:  bash watchdog.sh
# 停止:  touch ~/.kexvim/.stop_watchdog && kill <PID>
# 状态:  pgrep -f "watchdog.sh" > /dev/null && echo "运行中"

cd ~/.kexvim

cleanup() {
    echo "[watchdog] 收到退出信号，正在关闭 kexvim..."
    kill $KEXVIM_PID 2>/dev/null
    rm -f .stop_watchdog
    exit 0
}

trap cleanup SIGTERM SIGINT SIGHUP

while true; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 启动 kexvim..."
    node kexvim.js &
    KEXVIM_PID=$!
    wait $KEXVIM_PID

    # 检查停止标记
    if [ -f .stop_watchdog ]; then
        rm -f .stop_watchdog
        echo "[watchdog] 检测到停止标记，退出"
        exit 0
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] kexvim 退出，2 秒后重启..."
    sleep 2
done
