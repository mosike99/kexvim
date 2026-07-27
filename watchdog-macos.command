#!/bin/bash
# Kexvim 看门狗 (macOS) — 双击或在终端运行

cd ~/.kexvim

while true; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 启动 kexvim..."
    node kexvim.js
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] kexvim 退出，2 秒后重启..."
    sleep 2
done
