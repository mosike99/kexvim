#!/bin/bash
# Kexvim 一键安装脚本 (Linux/macOS)
# 从公开 Release 仓浅克隆，无 zip 文件
# 用法: bash <(curl -s https://gitee.com/moscowzk/kexvim/raw/main/install.sh)

set -e

KEXVIM_DIR="$HOME/.kexvim"
REPO="https://gitee.com/moscowzk/kexvim.git"

# 检测 OS
OS="linux"
[[ "$(uname)" == "Darwin" ]] && OS="macos"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║      Kexvim 安装程序 ($OS)           ║"
echo "╚══════════════════════════════════════╝"
echo ""

# 0. 检查 Node.js
if ! command -v node &>/dev/null; then
    echo "❌ 未安装 Node.js"
    echo "   安装: curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"
    echo "   nvm install 22"
    exit 1
fi
NODE_VER=$(node -v | sed 's/v//' | cut -d. -f1)
if [ "$NODE_VER" -lt 18 ]; then
    echo "❌ Node.js 版本过低（当前 $(node -v)），需要 v18+"
    exit 1
fi
echo "✅ Node.js $(node -v)"

# 1. 检查 Git
if ! command -v git &>/dev/null; then
    echo "❌ 未安装 Git"
    if [ "$OS" = "macos" ]; then
        echo "   安装: xcode-select --install"
    else
        echo "   安装: sudo apt-get install git 或 sudo yum install git"
    fi
    exit 1
fi

# 2. 克隆
echo ""
echo ">> 第 1 步：下载 Kexvim"
rm -rf "$KEXVIM_DIR"
git clone --depth 1 "$REPO" "$KEXVIM_DIR"
echo "✅ 下载完成"

# 3. 配置 API Key
echo ""
echo ">> 第 2 步：配置 API Key"
mkdir -p "$KEXVIM_DIR/data"
ENV_FILE="$KEXVIM_DIR/data/.env"
if [ ! -f "$ENV_FILE" ]; then
    read -r -p "输入 DeepSeek API Key (留空跳过): " DS_KEY
    if [ -n "$DS_KEY" ]; then
        cat > "$ENV_FILE" << EOF
DEEPSEEK_API_KEY=${DS_KEY}
KEXVIM_HOME=${KEXVIM_DIR}
EOF
        echo "✅ API Key 已保存"
    fi
fi

# 4. OS 服务
echo ""
echo ">> 第 3 步：系统服务"
if [ "$OS" = "linux" ] && command -v systemctl &>/dev/null; then
    SYSTEMD_DIR="$HOME/.config/systemd/user"
    mkdir -p "$SYSTEMD_DIR"
    cat > "$SYSTEMD_DIR/kexvim.service" << EOF
[Unit]
Description=Kexvim AI Assistant
After=network-online.target

[Service]
Type=simple
ExecStart=$(which node) $KEXVIM_DIR/kexvim.js
WorkingDirectory=$KEXVIM_DIR
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload 2>/dev/null || true
    loginctl enable-linger "$USER" 2>/dev/null || true
    echo "✅ systemd 服务已创建"
elif [ "$OS" = "macos" ]; then
    PLIST_DIR="$HOME/Library/LaunchAgents"
    mkdir -p "$PLIST_DIR"
    cat > "$PLIST_DIR/com.kexvim.app.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.kexvim.app</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(which node)</string>
        <string>${KEXVIM_DIR}/kexvim.js</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${KEXVIM_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF
    launchctl load "$PLIST_DIR/com.kexvim.app.plist" 2>/dev/null || true
    echo "✅ launchd 服务已创建"
else
    echo "   跳过（前台启动即可）"
fi

echo ""
echo "═══════════════════════════════════════════════"
echo "  ✅ Kexvim 安装完成！"
echo ""
echo "  启动:     cd ~/.kexvim && npm start"
echo "═══════════════════════════════════════════════"
echo ""

read -r -p "是否立即启动 Kexvim？（y/N）: " START_NOW
if [ "$START_NOW" = "y" ] || [ "$START_NOW" = "Y" ]; then
    cd "$KEXVIM_DIR" && npm start
fi
