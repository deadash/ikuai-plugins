#!/bin/bash
#
# 构建 ikupd 插件包
#
#   bash examples/ikupd-plugin/build.sh
#
# 产物: dist/ikupd-v<版本>-plugin.zip
# 说明:
#   * 包里只有 shell + Web 资源, 约 12KB, 不带任何二进制
#     (全部用设备自带的 curl / jq / unzip / sha256sum / ikplugin)。
#   * zip 保存 unix 权限位, 打包前统一 chmod +x 并转成 LF 换行, 并校验
#     install.sh / function/* 在 zip 里确实带执行位(框架会 test -x)。

set -e

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG="$SELF_DIR/pkg"
OUT="$SELF_DIR/dist"
NAME=ikupd
VER="$(sed -n 's/^version=//p' "$PKG/Release" | head -n1)"
ZIP="$OUT/${NAME}-v${VER}-plugin.zip"

[ -n "$VER" ] || { echo "读不到 pkg/Release 里的 version" >&2; exit 1; }
mkdir -p "$OUT"

# ---------------------------------------------------------------- 规范化
find "$PKG" -type f \( -name '*.sh' -o -path "$PKG/bin/*" -o -path "$PKG/function/*" \) \
    -exec sed -i 's/\r$//' {} + 2>/dev/null || true
chmod +x "$PKG"/*.sh "$PKG"/bin/* "$PKG"/function/* 2>/dev/null || true
for f in "$PKG"/Release "$PKG"/www/plugins/*/*.json "$PKG"/www/plugins/app/*.html; do
    [ -f "$f" ] && sed -i 's/\r$//' "$f"
done

# ---------------------------------------------------------------- 打包
rm -f "$ZIP"
( cd "$PKG" && zip -qr "$ZIP" . )

# ---------------------------------------------------------------- 校验
python3 - "$ZIP" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
must = ("Release", "install.sh", "uninstall.sh",
        "bin/ikupd", "function/ikupd",
        "www/plugins/ikupd/ikupd.json",
        "www/plugins/app/ikupd.html",
        "www/plugins/app/ikupd.png")
bad = []
for n in must:
    try:
        i = z.getinfo(n)
    except KeyError:
        bad.append(n + ": 缺失")
        continue
    if n.endswith(".sh") or n.startswith(("bin/", "function/")):
        if not (i.external_attr >> 16) & 0o111:
            bad.append(n + ": zip 里没有执行位")
print("zip 清单校验:", "OK" if not bad else "FAIL")
if bad:
    print("\n".join(bad))
    sys.exit(1)
print("包内文件:")
for n in sorted(z.namelist()):
    print("   %-46s %6d B" % (n, z.getinfo(n).file_size))
PY

echo
ls -l "$ZIP"
echo "sha256: $(sha256sum "$ZIP" | cut -d' ' -f1)"
