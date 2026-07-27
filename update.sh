#!/bin/bash
# Kexvim 更新脚本 (Linux/macOS)
# 用法: bash update.sh

echo "===================================="
echo "    更新 Kexvim..."
echo "===================================="

cd ~/.kexvim 2>/dev/null || { echo "[✗] 未找到 ~/.kexvim，先运行安装脚本"; exit 1; }

# 有 git 就走 git pull，没有就重下 zip
if command -v git &>/dev/null && [ -d .git ]; then
    echo "[~] git pull 拉取最新代码..."
    git pull --ff-only || { echo "[✗] 拉取失败"; exit 1; }
else
    echo "[~] 下载最新 release..."
    rm -rf /tmp/kexvim-update
    mkdir -p /tmp/kexvim-update
    curl -fsSL "https://gitee.com/moscowzk/kexvim/repository/archive/main.tar.gz" -o /tmp/kexvim-update/repo.tar.gz 2>/dev/null \
      || { echo "[✗] 下载失败"; exit 1; }
    tar xzf /tmp/kexvim-update/repo.tar.gz -C /tmp/kexvim-update 2>/dev/null
    rsync -a /tmp/kexvim-update/kexvim/ . 2>/dev/null || cp -r /tmp/kexvim-update/kexvim/* .
    rm -rf /tmp/kexvim-update
fi
echo "[✓] 更新完成"

echo "[~] 重启..."
pkill -f "node kexvim.js" 2>/dev/null
sleep 2
nohup node kexvim.js > /dev/null 2>&1 &

sleep 1
if pgrep -f "node kexvim.js" > /dev/null; then
    echo "[✓] Kexvim 已重启"
else
    echo "[✗] 启动失败"
fi
