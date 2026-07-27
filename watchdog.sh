#!/bin/bash
# Kexvim 看门狗 — 退出后自动重启
# 用法: nohup bash watchdog.sh > watchdog.log 2>&1 &

cd ~/.kexvim

while true; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 启动 kexvim..."
    node kexvim.js
    EXIT_CODE=$?
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] kexvim 退出 (code=$EXIT_CODE)，2 秒后重启..."
    sleep 2
done
