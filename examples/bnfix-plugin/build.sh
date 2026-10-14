#!/bin/bash
#
# 构建 bnfix 插件包
#
#   bash examples/bnfix-plugin/build.sh
#   bash examples/bnfix-plugin/build.sh --base /path/to/libcrypto.so.1.0.0
#
# 说明:
#   * 默认只打包"补丁描述 + 脚本 + 前端", 约 20KB。
#     设备端走**就地 1 字节补丁**, 不需要搬运 1.9MB 的整库
#     (设备根分区 111MB 已 100% 占满, 也放不下)。
#   * 给了 --base 时, 会顺便在 pkg/lib/ 下生成一份打好补丁的整库
#     (就是设备的 /usr/lib/libcrypto.so.1.0.0 原件), 供 `bnfix submit`
#     用 bind-mount 覆盖 —— 那是一条可选路线, 默认用不到。
#
set -e

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG="$SELF_DIR/pkg"
OUT="$SELF_DIR/dist"
SOLIB="$PKG/lib/libcrypto.so.1.0.0"

BASE=""
[ "${1:-}" = "--base" ] && BASE="${2:-}"

mkdir -p "$OUT"

# ---------------------------------------------------------------- 可选: 整库
if [ -n "$BASE" ]; then
    test -r "$BASE" || { echo "读不到 --base $BASE" >&2; exit 1; }
    # shellcheck disable=SC1090
    . "$PKG/share/bnfix.conf"

    md5_now=$(md5sum "$BASE" | cut -d' ' -f1)
    echo "==> 生成打好补丁的整库 (源 md5=$md5_now)"
    if [ "$md5_now" != "$ORIG_MD5" ]; then
        echo "   !! 源文件 md5 与 bnfix.conf 里的 ORIG_MD5 不一致, 拒绝生成" >&2
        echo "      期望 $ORIG_MD5" >&2
        exit 1
    fi
    mkdir -p "$PKG/lib"
    cp -f "$BASE" "$SOLIB"
    oldifs="$IFS"; IFS=';'
    for item in $PATCHES; do
        IFS="$oldifs"
        # shellcheck disable=SC2086
        set -- $item
        off="${1:-}"; nb="${3:-}"
        IFS=';'
        [ -n "$off" ] && [ -n "$nb" ] || continue
        printf "\\$(printf '%03o' "$((16#$nb))")" | \
            dd of="$SOLIB" bs=1 seek="$((off))" count=1 conv=notrunc 2>/dev/null
        echo "   patch $off: $2 -> $nb"
    done
    IFS="$oldifs"
    md5_new=$(md5sum "$SOLIB" | cut -d' ' -f1)
    echo "   补丁后 md5=$md5_new"
    if [ "$md5_new" != "$PATCHED_MD5" ]; then
        echo "   !! 补丁后 md5 与 PATCHED_MD5($PATCHED_MD5) 不一致" >&2
        exit 1
    fi
    echo "   OK"
else
    rm -f "$SOLIB"
    rmdir "$PKG/lib" 2>/dev/null || true
fi

# ---------------------------------------------------------------- 打包
echo "==> 检查自检证书与补丁描述"
test -r "$PKG/share/selfcheck.der" || { echo "缺少 share/selfcheck.der" >&2; exit 1; }
test -r "$PKG/share/bnfix.conf"    || { echo "缺少 share/bnfix.conf" >&2; exit 1; }
# 自检证书必须仍是那份会触发死循环的样本, 否则 verify 会失去意义
if [ "$(md5sum "$PKG/share/selfcheck.der" | cut -d' ' -f1)" != "663868c457285f4a62b232a018af91d1" ]; then
    echo "   !! share/selfcheck.der 与预期不符, 拒绝打包" >&2
    exit 1
fi
echo "   OK"

echo "==> 组装插件包"
chmod +x "$PKG/install.sh" "$PKG/boot.sh" "$PKG/uninstall.sh" "$PKG/bin/bnfix" "$PKG/function/bnfix"
find "$PKG/www" -type f -exec chmod 644 {} \; 2>/dev/null || true

echo "==> 打包"
rm -f "$OUT/bnfix.zip"
( cd "$PKG" && zip -qr "$OUT/bnfix.zip" . )
ls -la "$OUT/bnfix.zip"
unzip -l "$OUT/bnfix.zip"

echo
echo "插件包: $OUT/bnfix.zip"
echo "安装: 系统设置 -> 插件管理 -> 选择 bnfix.zip -> 上传并安装"
echo "      或命令行: ikplugin install $OUT/bnfix.zip"
echo "安装后: bnfix status / bnfix verify --full"
