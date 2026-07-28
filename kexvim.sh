#!/bin/bash
# Kexvim 入口 — 轻量转发到 kexvim.js
# 用法:  bash kexvim.sh {init|update|restart}
KEXVIM_DIR="${KEXVIM_HOME:-$HOME/.kexvim}"
[ -f "$KEXVIM_DIR/kexvim.js" ] || { echo "[✗] 未安装。先运行: bash $0 init"; exit 1; }
exec node "$KEXVIM_DIR/kexvim.js" "$@"
