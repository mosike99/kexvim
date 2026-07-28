#!/bin/bash
# Kexvim — 双击或命令行运行
# 自动检查状态：缺文件下载，缺 Key 提示输入，完成后打印常用命令

KEXVIM_DIR="${KEXVIM_HOME:-$HOME/.kexvim}"
REPO_URL="https://gitee.com/moscowzk/kexvim"
HAS_ERROR=0

# 传参 → 直接转发
if [ $# -gt 0 ]; then
    if [ ! -f "$KEXVIM_DIR/kexvim.js" ]; then
        echo "[✗] 未安装，先双击此脚本自动安装"
        exit 1
    fi
    exec node "$KEXVIM_DIR/kexvim.js" "$@"
fi

echo "==================================="
echo "       Kexvim"
echo "==================================="
echo ""
echo "默认安装路径: $KEXVIM_DIR"
read -p "是否更改路径？(y/N): " change_path
if [ "$change_path" = "y" ] || [ "$change_path" = "Y" ]; then
    read -p "输入新路径: " KEXVIM_DIR
    echo "使用路径: $KEXVIM_DIR"
fi
echo ""

# 1. 检查 kexvim.js
if [ ! -f "$KEXVIM_DIR/kexvim.js" ]; then
    echo "[~] 首次运行，下载 kexvim.js..."
    mkdir -p "$KEXVIM_DIR"
    curl -fsSL "$REPO_URL/raw/main/kexvim.js" -o "$KEXVIM_DIR/kexvim.js" || {
        echo "[✗] 下载失败，检查网络连接"
        HAS_ERROR=1
    }
    if [ -f "$KEXVIM_DIR/kexvim.js" ]; then
        echo "[✓] kexvim.js 已下载"
    fi
fi

# 2. 检查 API Key
if [ ! -f "$KEXVIM_DIR/data/.env" ]; then
    echo ""
    echo "[~] 首次运行，需要配置 API Key"
    mkdir -p "$KEXVIM_DIR/data"
    read -p "请输入 DeepSeek API Key: " key
    if [ -n "$key" ]; then
        echo "DEEPSEEK_API_KEY=$key" > "$KEXVIM_DIR/data/.env"
        echo "KEXVIM_HOME=$KEXVIM_DIR" >> "$KEXVIM_DIR/data/.env"
        echo "[✓] API Key 已保存"
    else
        echo "[!] 跳过，稍后可运行: bash kexvim.sh init"
    fi
fi

echo ""

if [ $HAS_ERROR -eq 1 ]; then
    echo "[✗] 安装未完成，请检查后重试"
else
    echo "[✓] Kexvim 已就绪"
    echo ""
    echo "  常用命令:"
    echo "    kexvim             启动"
    echo "    kexvim restart     重启"
    echo "    kexvim update      更新"
    echo "    kexvim --help      帮助"
    echo ""
    echo "  或直接双击此脚本启动"
    echo ""
    echo "  启动试试:  bash kexvim.sh restart"
fi
