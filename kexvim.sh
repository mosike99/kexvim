#!/bin/bash
# Kexvim — 双击或命令行运行
# 双击自动安装/启动；传参 {init|update|restart} 执行对应操作

KEXVIM_DIR="${KEXVIM_HOME:-$HOME/.kexvim}"
REPO_URL="https://gitee.com/moscowzk/kexvim"

# 有参数 → 直接转发
if [ $# -gt 0 ]; then
    [ -f "$KEXVIM_DIR/kexvim.js" ] || { echo "[✗] 未安装，双击此脚本自动安装"; exit 1; }
    exec node "$KEXVIM_DIR/kexvim.js" "$@"
fi

# 无参数 → 自动模式
if [ ! -f "$KEXVIM_DIR/kexvim.js" ]; then
    echo "[~] 首次运行，下载 kexvim.js..."
    mkdir -p "$KEXVIM_DIR"
    curl -fsSL "$REPO_URL/raw/main/kexvim.js" -o "$KEXVIM_DIR/kexvim.js" || { echo "[✗] 下载失败"; read -p "按 Enter 退出"; exit 1; }
    echo "[✓] 下载完成"
fi

if [ -f "$KEXVIM_DIR/data/.env" ]; then
    echo "[~] 启动 Kexvim..."
    node "$KEXVIM_DIR/kexvim.js" restart
else
    echo "[~] 首次运行，配置 API Key..."
    node "$KEXVIM_DIR/kexvim.js" init
    echo ""
    node "$KEXVIM_DIR/kexvim.js" restart
fi
