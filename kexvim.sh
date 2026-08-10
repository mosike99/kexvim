#!/bin/bash
# kexvim 一键安装/启动脚本（Linux/macOS，对齐 kexvim.bat 语义）
# 幂等：已在运行不重启；缺失才下载/装依赖/init；已完整安装不打印安装横幅
set -u

DIR="${KEXVIM_HOME:-$HOME/.kexvim}"
REPO=https://gitee.com/moscowzk/kexvim
NODEVER=v22.18.0

# ---------- 1. Node.js 检测/下载（node:sqlite 需要 >=22.5） ----------
download_node() {
    OS=$(uname -s)
    ARCH=$(uname -m)
    case "$OS" in
        Linux)  NODE_OS=linux;  EXT=tar.xz ;;
        Darwin) NODE_OS=darwin; EXT=tar.gz ;;
        *) echo "[X] Unsupported OS: $OS"; exit 1 ;;
    esac
    case "$ARCH" in
        x86_64|amd64) NODE_ARCH=x64 ;;
        arm64|aarch64) NODE_ARCH=arm64 ;;
        *) echo "[X] Unsupported arch: $ARCH"; exit 1 ;;
    esac
    echo "[~] Downloading Node.js $NODEVER ($NODE_OS-$NODE_ARCH)..."
    mkdir -p "$DIR"
    curl -fsSL "https://nodejs.org/dist/$NODEVER/node-$NODEVER-$NODE_OS-$NODE_ARCH.$EXT" -o "$DIR/node.$EXT" || { echo "[X] Node download failed"; exit 1; }
    rm -rf "$DIR/node"
    mkdir -p "$DIR/node"
    if [ "$EXT" = "tar.xz" ]; then
        tar -xJf "$DIR/node.$EXT" -C "$DIR/node" --strip-components=1
    else
        tar -xzf "$DIR/node.$EXT" -C "$DIR/node" --strip-components=1
    fi
    rm -f "$DIR/node.$EXT"
}

NODEEXE=""
if command -v node >/dev/null 2>&1; then
    NODEEXE=$(command -v node)
elif [ -x "$DIR/node/bin/node" ]; then
    NODEEXE="$DIR/node/bin/node"
    export PATH="$DIR/node/bin:$PATH"
fi
[ -z "$NODEEXE" ] && download_node

# 版本检查：Node <22.5 重下（与 bat 1b 段一致）
if ! "$NODEEXE" -e "process.exit(parseInt(process.versions.node.split('.')[1]) >= 5 ? 0 : 1)" 2>/dev/null; then
    echo "[~] Node too old ($("$NODEEXE" -v)), re-downloading $NODEVER..."
    rm -rf "$DIR/node"
    download_node
fi

NPMCMD=npm
[ -x "$DIR/node/bin/npm" ] && NPMCMD="$DIR/node/bin/npm"

# ---------- 2. 下载 kexvim.js / package.json / skills（缺失时） ----------
[ -f "$DIR/kexvim.js" ] || {
    echo "[~] Downloading kexvim.js..."
    mkdir -p "$DIR"
    curl -fsSL "$REPO/raw/main/kexvim.js" -o "$DIR/kexvim.js" || { echo "[X] kexvim.js download failed"; exit 1; }
}
[ -f "$DIR/package.json" ] || {
    echo "[~] Downloading package.json..."
    mkdir -p "$DIR"
    curl -fsSL "$REPO/raw/main/package.json" -o "$DIR/package.json" || { echo "[X] package.json download failed"; exit 1; }
}
[ -d "$DIR/skills" ] || {
    echo "[~] Downloading skills..."
    if command -v git >/dev/null 2>&1; then
        mkdir -p "$DIR/skills"
        tmp=$(mktemp -d)
        git clone --depth 1 "$REPO.git" "$tmp" --single-branch >/dev/null 2>&1
        [ -d "$tmp/skills" ] && cp -r "$tmp/skills/." "$DIR/skills/"
        rm -rf "$tmp"
    fi
}

# ---------- 3. 安装依赖（缺失时，kexvim.js 需要 cron/js-yaml/ws/MCP SDK） ----------
if [ ! -d "$DIR/node_modules/cron" ]; then
    echo "[~] Installing dependencies..."
    (cd "$DIR" && "$NPMCMD" install --omit=dev --no-audit --no-fund) || {
        echo "[X] npm install failed. Please install Node.js v22+ from https://nodejs.org"
        exit 1
    }
fi

# ---------- 4. 首次 init（幂等标记：data/.env；必须 cd 安装目录防 cwd 漂移） ----------
if [ ! -f "$DIR/data/.env" ]; then
    echo
    echo "[~] kexvim not initialized yet. Running first-time setup..."
    echo "[~] You will be prompted for your API key. Keep this terminal open."
    echo
    cd "$DIR" || exit 1
    "$NODEEXE" "$DIR/kexvim.js" init
    if [ ! -f "$DIR/data/.env" ]; then
        echo
        echo "[X] API Key not configured, install incomplete. Re-run this script or: kexvim init"
        exit 1
    fi
    echo "[~] 初始化完成"
    echo
    echo "================================================"
    echo "  安装完成。请查看上方日志确认"
    echo "  「kexvim 已就绪 / Web UI: 8788」后关闭本终端"
    echo "================================================"
fi

# ---------- 4b. 参数透传（kexvim.sh restart / stop / status ...） ----------
if [ $# -gt 0 ]; then
    cd "$DIR" || exit 1
    exec "$NODEEXE" "$DIR/kexvim.js" "$@"
fi

# ---------- 5. 探活：心跳新鲜(90s)=RUNNING；兜底查 daemon 进程 ----------
KEXVIM_STATE=STOPPED
if [ -d "$DIR/data" ]; then
    STATE=$("$NODEEXE" -e "try{const s=require('fs');const st=s.statSync(process.argv[1]+'/data/daemon.heartbeat');if(Date.now()-st.mtimeMs<90000)process.stdout.write('RUNNING');else process.stdout.write('STOPPED')}catch{process.stdout.write('STOPPED')}" "$DIR" 2>/dev/null)
    [ "$STATE" = "RUNNING" ] && KEXVIM_STATE=RUNNING
fi
# 兜底：心跳非 RUNNING 时查 daemon 进程（kexvim.js --daemon，排除 dev.mjs）——进程在=在运行，绝不误杀
if [ "$KEXVIM_STATE" != "RUNNING" ]; then
    if pgrep -af "kexvim.js --daemon" 2>/dev/null | grep -v "dev.mjs" >/dev/null; then
        KEXVIM_STATE=RUNNING
    fi
fi

echo
if [ "$KEXVIM_STATE" = "RUNNING" ]; then
    echo "[~] kexvim 已在运行"
else
    echo "[~] kexvim 未运行，正在启动..."
    cd "$DIR" || exit 1
    "$NODEEXE" "$DIR/kexvim.js" restart
    echo
    echo "  kexvim 已启动"
    echo "  Web UI:  http://localhost:8788"
    echo "-----------------------------------------------"
    echo "  Commands:"
    echo "    kexvim restart    Restart kexvim (daemon + web)"
    echo "    kexvim stop       Stop kexvim"
    echo "    kexvim status     Show status"
    echo "    kexvim init       Configure API key"
    echo "    kexvim install    Auto-start on boot"
    echo "    kexvim sessions   List sessions"
    echo "================================================"
fi

# ---------- 6. 保持终端（交互场景不自动关闭；非 tty 直接退出） ----------
if [ -t 0 ]; then
    echo
    read -r -p "Press Enter to close..."
fi
