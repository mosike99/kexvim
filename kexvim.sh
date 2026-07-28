#!/bin/bash
# Kexvim 管理工具
# 用法:  bash kexvim.sh {init|update|restart}
#        ./kexvim.sh {init|update|restart}

KEXVIM_DIR="$HOME/.kexvim"
REPO_URL="https://gitee.com/moscowzk/kexvim"

die() { echo "[✗] $1"; exit 1; }
info() { echo "[~] $1"; }

cmd_init() {
    if [ -f "$KEXVIM_DIR/kexvim.js" ]; then
        echo "Kexvim 已安装。要重新安装请先执行: rm -rf $KEXVIM_DIR"
        exit 0
    fi
    mkdir -p "$KEXVIM_DIR"

    # 下载
    if command -v git &>/dev/null; then
        info "克隆仓库..."
        git clone --depth 1 "$REPO_URL" "$KEXVIM_DIR" || die "克隆失败"
    else
        info "下载 release 包..."
        curl -fsSL "$REPO_URL/repository/archive/main.tar.gz" -o /tmp/kexvim.tar.gz || die "下载失败"
        tar xzf /tmp/kexvim.tar.gz -C /tmp && mv /tmp/kexvim-main/* "$KEXVIM_DIR/" && rm -rf /tmp/kexvim-main /tmp/kexvim.tar.gz
    fi

    # API Key
    mkdir -p "$KEXVIM_DIR/data"
    read -p "请输入 DeepSeek API Key: " key
    if [ -n "$key" ]; then
        echo "DEEPSEEK_API_KEY=$key" > "$KEXVIM_DIR/data/.env"
        echo "KEXVIM_HOME=$KEXVIM_DIR" >> "$KEXVIM_DIR/data/.env"
        echo "[✓] API Key 已保存"
    fi

    echo "[✓] 安装完成。运行: bash kexvim.sh restart"
}

cmd_update() {
    [ -d "$KEXVIM_DIR" ] || die "未安装 Kexvim（找不到 $KEXVIM_DIR）"
    cd "$KEXVIM_DIR" || die

    if command -v git &>/dev/null && [ -d .git ]; then
        info "git pull..."
        git pull --ff-only || die "拉取失败"
    else
        info "下载更新..."
        curl -fsSL "$REPO_URL/repository/archive/main.tar.gz" -o /tmp/kexvim.tar.gz || die "下载失败"
        tar xzf /tmp/kexvim.tar.gz -C /tmp
        cp /tmp/kexvim-main/kexvim.js .
        rm -rf /tmp/kexvim-main /tmp/kexvim.tar.gz
    fi
    echo "[✓] 更新完成"
    cmd_restart
}

cmd_restart() {
    [ -f "$KEXVIM_DIR/kexvim.js" ] || die "未安装 Kexvim"
    info "停止旧进程..."
    pkill -f "node.*kexvim.js" 2>/dev/null
    sleep 1
    info "启动新进程..."
    cd "$KEXVIM_DIR"
    nohup node kexvim.js > /dev/null 2>&1 &
    sleep 1
    if pgrep -f "node.*kexvim.js" > /dev/null; then
        echo "[✓] Kexvim 已在后台运行"
    else
        echo "[✗] 启动失败，检查 data/.env"
    fi
}

case "${1:-}" in
    init)    cmd_init ;;
    update)  cmd_update ;;
    restart) cmd_restart ;;
    *)       echo "用法: bash kexvim.sh {init|update|restart}" >&2; exit 1 ;;
esac
