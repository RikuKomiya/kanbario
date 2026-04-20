#!/usr/bin/env bash
# Build (or reuse cached) GhosttyKit.xcframework from the pinned ghostty
# submodule and expose it at repo root via a symlink. Lifted almost verbatim
# from cmux (manaflow-ai/cmux) with CMUX_ → KANBARIO_ renames.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

hash_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

hash_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    sha256sum "$path" | awk '{print $1}'
  fi
}

validate_bridge_header() {
  local path="$1"
  python3 - "$path" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
required = '#include "ghostty/include/ghostty.h"'
if required not in text:
    raise SystemExit(1)
PY
}

if [[ ! -d "$PROJECT_DIR/ghostty" ]]; then
  echo "error: ghostty submodule is missing. Run 'git submodule update --init --recursive' first." >&2
  exit 1
fi

# Use the pinned zig version that ghostty requires (matches cmux CI behavior).
# ensure-zig.sh downloads zig straight from ziglang.org into a per-user cache
# and echoes the install dir on stdout, so we can prepend it to PATH without
# contaminating a globally installed zig (e.g. brew's 0.16.x).
ZIG_INSTALL_DIR="$("$SCRIPT_DIR/ensure-zig.sh")"
export PATH="$ZIG_INSTALL_DIR:$PATH"

if ! command -v zig >/dev/null 2>&1; then
  echo "Error: zig is not installed." >&2
  echo "ensure-zig.sh should have installed it; check the cache at $ZIG_INSTALL_DIR." >&2
  exit 1
fi

if [[ ! -f "$PROJECT_DIR/ghostty/include/ghostty.h" ]]; then
  echo "error: ghostty/include/ghostty.h is missing. Ensure the submodule is fully checked out." >&2
  exit 1
fi

BRIDGE_HEADER="$PROJECT_DIR/Kanbario/ghostty.h"
if [[ ! -f "$BRIDGE_HEADER" ]]; then
  echo "error: Kanbario/ghostty.h bridge header is missing." >&2
  exit 1
fi
if ! validate_bridge_header "$BRIDGE_HEADER"; then
  echo "error: Kanbario/ghostty.h no longer points at ghostty/include/ghostty.h." >&2
  echo "Restore the bridge header so Xcode uses Ghostty's canonical C API." >&2
  exit 1
fi

GHOSTTY_SHA="$(git -C ghostty rev-parse HEAD)"
GHOSTTY_KEY="$GHOSTTY_SHA"
UNTRACKED_FILES="$(git -C ghostty ls-files --others --exclude-standard)"
if ! git -C ghostty diff --quiet --ignore-submodules=all HEAD -- || [[ -n "$UNTRACKED_FILES" ]]; then
  DIRTY_HASH="$(
    {
      printf 'head=%s\n' "$GHOSTTY_SHA"
      git -C ghostty diff --binary HEAD -- .
      if [[ -n "$UNTRACKED_FILES" ]]; then
        printf '\n--untracked--\n'
        while IFS= read -r path; do
          [[ -n "$path" ]] || continue
          printf 'path=%s\n' "$path"
          hash_file "$PROJECT_DIR/ghostty/$path"
        done <<< "$UNTRACKED_FILES"
      fi
    } | hash_stdin
  )"
  GHOSTTY_KEY="${GHOSTTY_SHA}-dirty-${DIRTY_HASH}"
fi

CACHE_ROOT="${KANBARIO_GHOSTTYKIT_CACHE_DIR:-$HOME/.cache/kanbario/ghosttykit}"
CACHE_DIR="$CACHE_ROOT/$GHOSTTY_KEY"
CACHE_XCFRAMEWORK="$CACHE_DIR/GhosttyKit.xcframework"
LOCAL_XCFRAMEWORK="$PROJECT_DIR/ghostty/macos/GhosttyKit.xcframework"
LOCAL_KEY_STAMP="$LOCAL_XCFRAMEWORK/.ghostty_state_key"
LEGACY_LOCAL_SHA_STAMP="$LOCAL_XCFRAMEWORK/.ghostty_sha"
LOCK_DIR="$CACHE_ROOT/$GHOSTTY_KEY.lock"

mkdir -p "$CACHE_ROOT"

echo "==> Ghostty build key: $GHOSTTY_KEY"

LOCK_TIMEOUT=300
LOCK_START=$SECONDS
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  if (( SECONDS - LOCK_START > LOCK_TIMEOUT )); then
    echo "==> Lock stale (>${LOCK_TIMEOUT}s), removing and retrying..."
    rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
    continue
  fi
  echo "==> Waiting for GhosttyKit cache lock for $GHOSTTY_KEY..."
  sleep 1
done
trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

if [[ -d "$CACHE_XCFRAMEWORK" ]]; then
  echo "==> Reusing cached GhosttyKit.xcframework"
else
  LOCAL_KEY=""
  if [[ -f "$LOCAL_KEY_STAMP" ]]; then
    LOCAL_KEY="$(cat "$LOCAL_KEY_STAMP")"
  elif [[ -f "$LEGACY_LOCAL_SHA_STAMP" ]]; then
    LOCAL_KEY="$(cat "$LEGACY_LOCAL_SHA_STAMP")"
  fi

  if [[ -d "$LOCAL_XCFRAMEWORK" && "$LOCAL_KEY" == "$GHOSTTY_KEY" ]]; then
    echo "==> Seeding cache from existing local GhosttyKit.xcframework (build key matches)"
  else
    echo "==> Building GhosttyKit.xcframework (this may take a few minutes)..."
    (
      cd ghostty
      zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
    )
    echo "$GHOSTTY_KEY" > "$LOCAL_KEY_STAMP"
    echo "$GHOSTTY_SHA" > "$LEGACY_LOCAL_SHA_STAMP"
  fi

  if [[ ! -d "$LOCAL_XCFRAMEWORK" ]]; then
    echo "Error: GhosttyKit.xcframework not found at $LOCAL_XCFRAMEWORK" >&2
    exit 1
  fi

  TMP_DIR="$(mktemp -d "$CACHE_ROOT/.ghosttykit-tmp.XXXXXX")"
  mkdir -p "$CACHE_DIR"
  cp -R "$LOCAL_XCFRAMEWORK" "$TMP_DIR/GhosttyKit.xcframework"
  rm -rf "$CACHE_XCFRAMEWORK"
  mv "$TMP_DIR/GhosttyKit.xcframework" "$CACHE_XCFRAMEWORK"
  rmdir "$TMP_DIR"
  echo "==> Cached GhosttyKit.xcframework at $CACHE_XCFRAMEWORK"
fi

MACOS_ARCHIVE="$CACHE_XCFRAMEWORK/macos-arm64_x86_64/libghostty.a"
if [[ -f "$MACOS_ARCHIVE" ]]; then
  # Xcode 26 can fail to resolve symbols from Ghostty's universal static archive
  # until its ranlib index is refreshed after reuse or copy.
  echo "==> Refreshing libghostty archive index..."
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "error: xcrun is required to refresh libghostty archive index." >&2
    exit 1
  fi
  if ! XCODE_RANLIB="$(xcrun --find ranlib 2>/dev/null)"; then
    echo "error: could not locate ranlib via xcrun." >&2
    exit 1
  fi
  "$XCODE_RANLIB" "$MACOS_ARCHIVE"
fi

echo "==> Creating symlink for GhosttyKit.xcframework..."
ln -sfn "$CACHE_XCFRAMEWORK" GhosttyKit.xcframework

# Terminfo: ghostty の build output が生成する terminfo ディレクトリを
# Resources/terminfo に symlink する。cmux と同じく xterm-ghostty terminfo
# を app bundle に同梱して、TERM=xterm-ghostty のまま lazygit / vi / tmux
# が動くようにするため (README 参照)。
#
# ghostty の `zig build` は ReleaseLocal (Ghostty.app) と ReleaseFast の両方を
# 残すので、存在するほうから拾う。見つからなくても build は続行 (Swift 側の
# GhosttyTerminfoInstaller が保険として ~/.terminfo へ copy する)。
GHOSTTY_TERMINFO_CANDIDATES=(
  "$PROJECT_DIR/ghostty/macos/build/ReleaseLocal/Ghostty.app/Contents/Resources/terminfo"
  "$PROJECT_DIR/ghostty/zig-out/share/terminfo"
)
GHOSTTY_TERMINFO_SRC=""
for candidate in "${GHOSTTY_TERMINFO_CANDIDATES[@]}"; do
  if [[ -d "$candidate" ]]; then
    GHOSTTY_TERMINFO_SRC="$candidate"
    break
  fi
done

if [[ -n "$GHOSTTY_TERMINFO_SRC" ]]; then
  # Xcode の Run Script sandbox は、symlink 先が project 外ディレクトリ
  # (e.g. ghostty/macos/build/...) だと cp -RL を permission エラーで弾く。
  # そのため symlink ではなく実ファイルを copy して Resources/terminfo を
  # 自己完結させる。source 側が更新された時は ensure-ghosttykit.sh 再実行で
  # 追従する (= ghostty rebuild したらこの script も走る運用)。
  echo "==> Copying terminfo: $GHOSTTY_TERMINFO_SRC → Resources/terminfo"
  rm -rf "$PROJECT_DIR/Resources/terminfo"
  mkdir -p "$PROJECT_DIR/Resources"
  cp -R "$GHOSTTY_TERMINFO_SRC" "$PROJECT_DIR/Resources/terminfo"
else
  echo "==> warn: ghostty terminfo source not found; Resources/terminfo not linked"
  echo "    candidates:"
  printf '      %s\n' "${GHOSTTY_TERMINFO_CANDIDATES[@]}"
fi
