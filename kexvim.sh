#!/bin/bash
DIR="${KEXVIM_HOME:-$HOME/.kexvim}"
REPO=https://gitee.com/moscowzk/kexvim

command -v node >/dev/null 2>&1 || { echo "Node.js required: https://nodejs.org"; exit 1; }

[ -f "$DIR/kexvim.js" ] || {
  mkdir -p "$DIR"
  echo "Downloading kexvim.js..."
  curl -fsSL "$REPO/raw/main/kexvim.js" -o "$DIR/kexvim.js" || exit 1
  echo "Downloading skills..."
  command -v git >/dev/null 2>&1 && {
    tmp=$(mktemp -d)
    git clone --depth 1 "$REPO.git" "$tmp" --single-branch 2>/dev/null
    [ -d "$tmp/skills" ] && cp -r "$tmp/skills" "$DIR/skills/"
    rm -rf "$tmp"
  }
}

exec node "$DIR/kexvim.js" "$@"
