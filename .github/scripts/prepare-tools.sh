#!/usr/bin/env bash
set -euo pipefail

: "${TOOLS_DIR:?Set TOOLS_DIR}"
mkdir -p "$TOOLS_DIR"
TOOLS_DIR=$(cd "$TOOLS_DIR" && pwd)
if [[ -x "$TOOLS_DIR/apk" ]]; then exit 0; fi

# Pinned apk-tools revision for reproducible APK v3 packaging.
APK_REV=b5a31c0d865342ad80be10d68f1bb3d3ad9b0866
WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/sing-box-tools.XXXXXX")
mkdir "$WORK/apk"
curl -fsSL --retry 3 "https://codeload.github.com/alpinelinux/apk-tools/tar.gz/$APK_REV" |
  tar -xz -C "$WORK/apk" --strip-components=1
VERSION=3.0.5 meson setup "$WORK/apk/build" "$WORK/apk" \
  --buildtype=release -Ddefault_library=static \
  -Ddocs=disabled -Dhelp=disabled -Dlua=disabled -Dpython=disabled \
  -Dtests=disabled -Dzstd=disabled -Durl_backend=wget
meson compile -C "$WORK/apk/build" -j "$(nproc)"
install -m 0755 "$WORK/apk/build/src/apk" "$TOOLS_DIR/apk"
