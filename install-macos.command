#!/bin/bash
# Kexvim 一键安装 (macOS) — 双击此文件运行

clear
echo "===================================="
echo "   Kexvim 一键安装 (macOS)"
echo "===================================="
echo

SAGE_DIR="$HOME/.sage"
REPO="https://gitee.com/moscowzk/kexvim-dev.git"

# 1. Node.js
if ! command -v node &>/dev/null; then
    echo "❌ 未安装 Node.js"
    echo "   请安装: https://nodejs.org"
    open https://nodejs.org
    read -p "按 Enter 退出..."
    exit 1
fi
echo "✅ Node.js $(node -v)"

# 2. Git
if ! command -v git &>/dev/null; then
    echo "❌ 未安装 Git"
    echo "   请安装 Xcode Command Line Tools: xcode-select --install"
    read -p "按 Enter 退出..."
    exit 1
fi

# 3. 下载代码
echo ""
echo ">> 下载代码..."
if [ -d "$SAGE_DIR/.git" ]; then
    cd "$SAGE_DIR" && git pull --ff-only
else
    mkdir -p "$SAGE_DIR"
    git clone "$REPO" "$SAGE_DIR"
fi
cd "$SAGE_DIR"

# 4. 装依赖
echo ""
echo ">> 安装依赖..."
npm install --ignore-scripts

# 5. 编译
echo ""
echo ">> 编译..."
npx tsc --noEmit
echo "✅ 编译通过"

# 6. API Key
ENV_FILE="$SAGE_DIR/data/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo ""
    echo ">> 配置 API Key"
    mkdir -p "$SAGE_DIR/data"
    read -p "输入 DeepSeek API Key: " DS_KEY
    if [ -n "$DS_KEY" ]; then
        cat > "$ENV_FILE" << EOF
DEEPSEEK_API_KEY=${DS_KEY}
SAGE_HOME=${SAGE_DIR}
EOF
        echo "✅ API Key 已保存"
    fi
fi

# 7. macOS launchd 服务（可选）
echo ""
echo ">> 是否创建开机自启服务？[y/N] "
read -r SETUP_LAUNCHD
if [ "$SETUP_LAUNCHD" = "y" ] || [ "$SETUP_LAUNCHD" = "Y" ]; then
    PLIST_DIR="$HOME/Library/LaunchAgents"
    mkdir -p "$PLIST_DIR"
    cat > "$PLIST_DIR/com.sage.app.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.sage.app</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(which npx)</string>
        <string>tsx</string>
        <string>${SAGE_DIR}/src/Main.ts</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${SAGE_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${SAGE_DIR}/data/sage.log</string>
    <key>StandardErrorPath</key>
    <string>${SAGE_DIR}/data/sage.log</string>
</dict>
</plist>
EOF
    launchctl load "$PLIST_DIR/com.sage.app.plist" 2>/dev/null || true
    echo "✅ 开机自启已设置 (com.sage.app)"
fi

echo ""
echo "═══════════════════════════════════════════════"
echo "  ✅ Kexvim 安装完成！"
echo ""
echo "  前台启动: cd ~/.sage && npm start"
echo "  TUI:      直接在终端打字和 Kexvim 对话"
echo "  后台管理: launchctl start/stop com.sage.app"
echo "═══════════════════════════════════════════════"
echo ""

read -p "是否立即启动 Kexvim？（y/N）: " START_NOW
if [ "$START_NOW" = "y" ] || [ "$START_NOW" = "Y" ]; then
    cd "$SAGE_DIR" && npm start
fi
