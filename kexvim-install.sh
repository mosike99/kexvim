#!/bin/bash
# ============================================================
#  kexvim installer (minimal) - 2026-09-09
#  This script does ONLY:
#    1. ensure Node.js >=22.5 (the sole dependency installed here)
#    2. download kexvim.js (skip when present)
#    3. launch the installer process: node kexvim.js bootstrap
#       (deps + example configs + init + start)
#  With arguments it forwards them to kexvim.js directly.
# ============================================================
set -u
DIR="${KEXVIM_HOME:-$HOME/.kexvim}"
REPO="${KEXVIM_REPO:-https://gitee.com/moscowzk/kexvim}"
NODEVER=v22.18.0

download_node() {
    local NODE_OS NODE_ARCH EXT
    case "$(uname -s)" in Darwin) NODE_OS=darwin ;; *) NODE_OS=linux ;; esac
    case "$(uname -m)" in arm64|aarch64) NODE_ARCH=arm64 ;; *) NODE_ARCH=x64 ;; esac
    EXT=tar.gz
    echo "[~] Downloading Node.js $NODEVER ($NODE_OS-$NODE_ARCH)..."
    curl -fsSL "https://nodejs.org/dist/$NODEVER/node-$NODEVER-$NODE_OS-$NODE_ARCH.$EXT" -o "$DIR/node.$EXT" || { echo "[X] Node download failed"; exit 1; }
    rm -rf "$DIR/node"
    tar -xzf "$DIR/node.$EXT" -C "$DIR" && mv "$DIR/node-$NODEVER-$NODE_OS-$NODE_ARCH" "$DIR/node"
    rm -f "$DIR/node.$EXT"
}

mkdir -p "$DIR"

# -- 1. Node.js >=22.5 (node:sqlite); portable copy auto-downloaded when missing/too old
NODEEXE=""
[ -x "$DIR/node/bin/node" ] && NODEEXE="$DIR/node/bin/node"
[ -z "$NODEEXE" ] && command -v node >/dev/null 2>&1 && NODEEXE="$(command -v node)"
if [ -z "$NODEEXE" ] || ! "$NODEEXE" -e "const v=process.versions.node.split('.').map(Number);process.exit(v[0]>22||(v[0]===22&&v[1]>=5)?0:1)" 2>/dev/null; then
    [ -n "$NODEEXE" ] && echo "[~] Node too old ($("$NODEEXE" -v)), re-downloading $NODEVER..."
    download_node
    NODEEXE="$DIR/node/bin/node"
fi

# -- 2. kexvim code (skip download when present)
if [ ! -f "$DIR/kexvim.js" ]; then
    echo "[~] Downloading kexvim.js..."
    curl -fsSL "$REPO/raw/main/kexvim.js" -o "$DIR/kexvim.js" || { echo "[X] kexvim.js download failed"; exit 1; }
fi

cd "$DIR" || exit 1

# -- 3. run: args passthrough; no args -> installer process
if [ $# -gt 0 ]; then
    exec "$NODEEXE" "$DIR/kexvim.js" "$@"
fi
"$NODEEXE" "$DIR/kexvim.js" bootstrap
RC=$?
# keep the window readable when launched from a double-click
if [ -t 0 ]; then
    echo
    read -r -p "Press Enter to close..." _
fi
exit $RC
