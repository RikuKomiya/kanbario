#!/usr/bin/env bash
# Ensure the zig toolchain version that ghostty requires is available in a
# cache-local directory, downloaded straight from ziglang.org. Lifted from
# cmux's CI workflow (.github/workflows/build-ghosttykit.yml) so the local
# build path matches the CI path exactly.
#
# Echoes the directory that contains the `zig` binary on stdout. Callers are
# expected to prepend that to PATH.
set -euo pipefail

ZIG_VERSION="${KANBARIO_ZIG_VERSION:-0.15.2}"
CACHE_ROOT="${KANBARIO_ZIG_CACHE_DIR:-$HOME/.cache/kanbario/zig}"
INSTALL_DIR="$CACHE_ROOT/$ZIG_VERSION"

case "$(uname -m)" in
  arm64) ZIG_ARCH="aarch64" ;;
  x86_64) ZIG_ARCH="x86_64" ;;
  *) echo "error: unsupported macOS architecture: $(uname -m)" >&2; exit 1 ;;
esac

ARCHIVE_STEM="zig-${ZIG_ARCH}-macos-${ZIG_VERSION}"
ARCHIVE_NAME="${ARCHIVE_STEM}.tar.xz"
DOWNLOAD_URL="https://ziglang.org/download/${ZIG_VERSION}/${ARCHIVE_NAME}"
ZIG_BIN="$INSTALL_DIR/zig"

if [[ -x "$ZIG_BIN" ]]; then
  INSTALLED_VERSION="$("$ZIG_BIN" version 2>/dev/null || true)"
  if [[ "$INSTALLED_VERSION" == "$ZIG_VERSION" ]]; then
    printf '%s\n' "$INSTALL_DIR"
    exit 0
  fi
fi

echo "==> Installing zig ${ZIG_VERSION} for ${ZIG_ARCH} into ${INSTALL_DIR}" >&2

mkdir -p "$CACHE_ROOT"
TMP_DIR="$(mktemp -d "$CACHE_ROOT/.zig-install.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE_PATH="$TMP_DIR/$ARCHIVE_NAME"
curl --fail --show-error --location \
  --retry 5 \
  --retry-delay 5 \
  --retry-all-errors \
  -o "$ARCHIVE_PATH" \
  "$DOWNLOAD_URL"

tar -xJf "$ARCHIVE_PATH" -C "$TMP_DIR"
rm -rf "$INSTALL_DIR"
mkdir -p "$CACHE_ROOT"
mv "$TMP_DIR/$ARCHIVE_STEM" "$INSTALL_DIR"

if ! "$ZIG_BIN" version >/dev/null 2>&1; then
  echo "error: installed zig ${ZIG_VERSION} but it failed to execute" >&2
  exit 1
fi

printf '%s\n' "$INSTALL_DIR"
