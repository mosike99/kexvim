#!/bin/bash
DIR="${KEXVIM_HOME:-$HOME/.kexvim}"
REPO=https://gitee.com/moscowzk/kexvim

command -v node >/dev/null 2>&1 || { echo "Node.js required: https://nodejs.org"; exit 1; }

[ -f "$DIR/kexvim.js" ] || { mkdir -p "$DIR"; curl -fsSL "$REPO/raw/main/kexvim.js" -o "$DIR/kexvim.js" || exit 1; }
[ -f "$DIR/watchdog.js" ] || curl -fsSL "$REPO/raw/main/watchdog.js" -o "$DIR/watchdog.js" 2>/dev/null

exec node "$DIR/watchdog.js" "$@"
