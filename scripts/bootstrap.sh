#!/usr/bin/env bash
# kanbario bootstrap — 開発環境の前提条件をチェック
set -euo pipefail

GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
NC="\033[0m"

ok()   { printf "${GREEN}✓${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}⚠${NC} %s\n" "$1"; }
err()  { printf "${RED}✗${NC} %s\n" "$1"; }

echo "kanbario 依存チェック"
echo "===================="

# Xcode
if xcode-select -p >/dev/null 2>&1; then
    ok "Xcode: $(xcodebuild -version 2>/dev/null | head -1)"
else
    err "Xcode が未インストール。App Store から入れてください"
    exit 1
fi

# worktrunk
if command -v wt >/dev/null 2>&1; then
    wt_version="$(WORKTRUNK_BIN_PATH="$(command -v wt || true)" wt --version 2>/dev/null | head -1 || echo 'unknown')"
    ok "worktrunk: $wt_version"

    # JSON 出力対応チェック
    if wt list --format=json >/dev/null 2>&1; then
        ok "  wt list --format=json: OK"
    else
        warn "  wt list --format=json が動かない。worktrunk を更新してください"
    fi
else
    err "worktrunk 未インストール。brew install worktrunk で入れてください"
    echo "   あるいは: cargo install worktrunk"
fi

# claude (real binary、cmux wrapper を避けて探す)
real_claude=""
IFS=':' read -ra paths <<< "$PATH"
for p in "${paths[@]}"; do
    candidate="$p/claude"
    if [[ -x "$candidate" && "$candidate" != *"cmux.app"* && "$candidate" != *"kanbario.app"* ]]; then
        real_claude="$candidate"
        break
    fi
done

if [[ -n "$real_claude" ]]; then
    ok "claude (real): $real_claude"
    "$real_claude" --version 2>&1 | head -1 | sed 's/^/    /'
else
    warn "real claude binary が見つからない (cmux の shim 以外の claude)"
    echo "   npm install -g @anthropic-ai/claude-code で入れてください"
fi

# zig (libghostty build 用、Milestone D で必要)
if command -v zig >/dev/null 2>&1; then
    ok "zig: $(zig version 2>&1 | head -1)"
else
    warn "zig 未インストール (libghostty build で必要、Milestone D 時点で必須)"
    echo "   brew install zig"
fi

# 現在 cmux の中で動いてるか (kanbario 開発時の干渉チェック)
if [[ -n "${CMUX_SURFACE_ID:-}" ]]; then
    warn "現在 cmux の中で動作中。kanbario の動作確認時は cmux 外で実行してください"
    echo "   理由: claude の PATH が cmux の shim を指す"
fi

echo ""
echo "kanbario 開発パス"
echo "================="
echo "  repo: $(cd "$(dirname "$0")/.." && pwd)"
echo "  data: $HOME/Library/Application Support/kanbario/"
