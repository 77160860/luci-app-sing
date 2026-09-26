#!/usr/bin/env bash
set -euo pipefail

# 1. 解析与格式化版本号（去掉严格的 vMAJOR.MINOR.PATCH 限制）
TAG="${RELEASE_TAG:-}"
if [ -z "$TAG" ]; then
  TAG="1.0.0-$(date +'%Y%m%d')"
else
  TAG="${TAG#[vV]}"
fi
TAG=$(echo "$TAG" | tr '_' '-') # 替换不支持的字符

: "${TOOLS_DIR:?Set TOOLS_DIR to the directory containing apk}"

SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TOOLS_DIR=$(cd "$TOOLS_DIR" && pwd)
DIST="$SOURCE_DIR/dist"
mkdir -p "$DIST"

# 2. 从 Makefile 动态提取元数据
command -v tar >/dev/null 2>&1 || { echo "缺少 tar，无法生成 IPK" >&2; exit 1; }

RELEASE=$(sed -n 's/^PKG_RELEASE:=//p' "$SOURCE_DIR/Makefile" | tr -d ' \t\r\n' || true)
[ -z "$RELEASE" ] && RELEASE="1"

PKG_NAME=$(sed -n 's/^PKG_NAME:=//p' "$SOURCE_DIR/Makefile" | tr -d ' \t\r\n' || true)
[ -z "$PKG_NAME" ] && PKG_NAME="luci-app-sing"

TITLE=$(sed -n 's/^LUCI_TITLE:=//p' "$SOURCE_DIR/Makefile" | tr -d '\r\n' || true)
[ -z "$TITLE" ] && TITLE="Sing 配置与服务管理面板"

# OpenWrt 依赖声明转换
DEPENDS_RAW=$(sed -n 's/^LUCI_DEPENDS:=//p' "$SOURCE_DIR/Makefile" | tr -d '+' | tr -d '\r\n' || true)
[ -z "$DEPENDS_RAW" ] && DEPENDS_RAW="luci-base sing-box rpcd jshn jsonfilter"

# 构造 apk 依赖 (空格分隔) 与 opkg 依赖 (逗号分隔)
APK_DEPENDS="$DEPENDS_RAW"
IPK_DEPENDS=$(echo "$DEPENDS_RAW" | tr ' ' ', ')

LICENSE=$(sed -n 's/^PKG_LICENSE:=//p' "$SOURCE_DIR/Makefile" | tr -d ' \t\r\n' || true)
[ -z "$LICENSE" ] && LICENSE="MIT"

APK_VERSION="${TAG}-r${RELEASE}"
IPK_VERSION="${TAG}-${RELEASE}"

# 3. 组织构建产物目录
WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/sing-package.XXXXXX")
MAIN="$WORK/main"
mkdir -p "$MAIN/www"

[ -d "$SOURCE_DIR/root" ] && cp -R "$SOURCE_DIR/root/." "$MAIN/"
[ -d "$SOURCE_DIR/htdocs" ] && cp -R "$SOURCE_DIR/htdocs/." "$MAIN/www/"

# 规范基础文件权限
find "$MAIN" -type d -exec chmod 0755 {} +
find "$MAIN" -type f -exec chmod 0644 {} +
[ -f "$MAIN/usr/libexec/rpcd/luci.sing-box" ] && chmod 0755 "$MAIN/usr/libexec/rpcd/luci.sing-box"
[ -f "$MAIN/usr/libexec/sing-box-panel-worker" ] && chmod 0755 "$MAIN/usr/libexec/sing-box-panel-worker"

# ==========================================
# 4. 构建 OpenWrt APK (v3)
# ==========================================
make_apk_hooks() {
  local dir="$WORK/apk-hooks"
  mkdir -p "$dir"
  {
    printf '#!/bin/sh\nexport pkgname="%s"\n' "$PKG_NAME"
    cat <<'EOF'
[ "${IPKG_NO_SCRIPT:-}" = 1 ] && exit 0
[ -s "${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0
. "${IPKG_INSTROOT}/lib/functions.sh"
export root="${IPKG_INSTROOT}"
default_postinst
[ -n "$IPKG_INSTROOT" ] || {
  [ -f /etc/uci-defaults/90-luci-app-sing ] && {
    ( . /etc/uci-defaults/90-luci-app-sing ) && rm -f /etc/uci-defaults/90-luci-app-sing
  }
  rm -f /tmp/luci-indexcache.*
  rm -rf /tmp/luci-modulecache/
  /etc/init.d/rpcd reload 2>/dev/null || true
}
exit 0
EOF
  } > "$dir/post-install"
  { printf '#!/bin/sh\nexport PKG_UPGRADE=1\n'; tail -n +2 "$dir/post-install"; } > "$dir/post-upgrade"
  {
    printf '#!/bin/sh\nexport pkgname="%s"\n' "$PKG_NAME"
    cat <<'EOF'
[ -s "${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0
. "${IPKG_INSTROOT}/lib/functions.sh"
export root="${IPKG_INSTROOT}"
default_prerm
EOF
  } > "$dir/pre-deinstall"
}

build_apk() {
  echo "==> [1/2] 正在打包 OpenWrt APK: $PKG_NAME-$APK_VERSION.apk"
  make_apk_hooks
  local hooks="$WORK/apk-hooks"

  mkdir -p "$MAIN/lib/apk/packages"
  (cd "$MAIN"; find . -type f -printf '/%P\n' | sort) > "$WORK/$PKG_NAME.list"
  cp "$WORK/$PKG_NAME.list" "$MAIN/lib/apk/packages/$PKG_NAME.list"

  fakeroot "$TOOLS_DIR/apk" mkpkg \
    --info "name:$PKG_NAME" \
    --info "version:$APK_VERSION" \
    --info "arch:noarch" \
    --info "license:$LICENSE" \
    --info "origin:$PKG_NAME" \
    --info "url:https://github.com/77160860/luci-app-sing" \
    --info "description:$TITLE" \
    --info "depends:$APK_DEPENDS" \
    --script "post-install:$hooks/post-install" \
    --script "post-upgrade:$hooks/post-upgrade" \
    --script "pre-deinstall:$hooks/pre-deinstall" \
    --files "$MAIN" \
    --output "$DIST/$PKG_NAME-$APK_VERSION.apk"
}

# ==========================================
# 5. 构建标准 OpenWrt IPK (tar.gz 容器)
# ==========================================
build_ipk() {
  echo "==> [2/2] 正在打包 OpenWrt IPK: ${PKG_NAME}_${IPK_VERSION}_all.ipk"
  local ipk_work="$WORK/ipk_build"
  local data_dir="$ipk_work/data"
  local ctrl_dir="$ipk_work/control"
  mkdir -p "$data_dir" "$ctrl_dir"

  # 准备数据目录（清理掉 apk 专用的 package 列表）
  cp -R "$MAIN/." "$data_dir/"
  rm -rf "$data_dir/lib/apk"

  # 生成符合 Debian/opkg 规范的 control 文件（确保末尾有且仅有空行）
  cat <<EOF > "$ctrl_dir/control"
Package: $PKG_NAME
Version: $IPK_VERSION
Depends: $IPK_DEPENDS
Section: luci
Architecture: all
Maintainer: OpenWrt
Description: $TITLE

EOF

  # 生成 postinst 脚本
  cat <<'EOF' > "$ctrl_dir/postinst"
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
    [ -f /etc/uci-defaults/90-luci-app-sing ] && {
        ( . /etc/uci-defaults/90-luci-app-sing ) && rm -f /etc/uci-defaults/90-luci-app-sing
    }
    rm -f /tmp/luci-indexcache.*
    rm -rf /tmp/luci-modulecache/
    /etc/init.d/rpcd reload 2>/dev/null || true
}
exit 0
EOF
  chmod 0755 "$ctrl_dir/postinst"

  # 生成 prerm 脚本
  cat <<'EOF' > "$ctrl_dir/prerm"
#!/bin/sh
exit 0
EOF
  chmod 0755 "$ctrl_dir/prerm"

  # 1. 规范打包 control.tar.gz 与 data.tar.gz（排除父级目录 '.'）
  echo "2.0" > "$ipk_work/debian-binary"
  (cd "$ctrl_dir" && tar --numeric-owner --group=0 --owner=0 -czf "$ipk_work/control.tar.gz" *)
  (cd "$data_dir" && tar --numeric-owner --group=0 --owner=0 -czf "$ipk_work/data.tar.gz" *)

  # 2. 关键：OpenWrt 的 IPK 是 tar.gz 容器，不是 ar 归档。
  #    opkg 的 libbb/unarchive.c:deb_extract() 直接把整个包当 tar 流遍历，
  #    逐个比对成员名 "control.tar.gz" / "data.tar.gz"；用 ar 封装会导致
  #    "pkg_init_from_file: Malformed package file"。此处改用 tar 封装。
  local ipk_file="$DIST/${PKG_NAME}_${IPK_VERSION}_all.ipk"
  rm -f "$ipk_file"
  (
    cd "$ipk_work"
    tar --numeric-owner --group=0 --owner=0 -czf "$ipk_file" \
        ./debian-binary ./control.tar.gz ./data.tar.gz
  ) || { echo "IPK 封装失败: $ipk_file" >&2; exit 1; }

  # 3. 自检：确认外层是 tar.gz 且包含 opkg 需要的两个成员
  if ! tar -tzf "$ipk_file" 2>/dev/null | grep -q '^\./control\.tar\.gz$'; then
    echo "IPK 自检失败：缺少 ./control.tar.gz 成员" >&2
    exit 1
  fi
  if ! tar -tzf "$ipk_file" 2>/dev/null | grep -q '^\./data\.tar\.gz$'; then
    echo "IPK 自检失败：缺少 ./data.tar.gz 成员" >&2
    exit 1
  fi

  echo "打包完成，标准 IPK 文件: $ipk_file"
}

# 执行打包
build_apk
build_ipk

echo "=========================================="
echo "🎉 打包完成，产物列表："
ls -lh "$DIST"
echo "=========================================="
