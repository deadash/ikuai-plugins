#!/bin/bash
#
# 构建 Rust 示例插件并打成插件包(可直接在"系统设置 -> 插件管理 -> ikguard -> 上传并安装"里上传)
#
#   bash examples/rust-plugin/build.sh
#   -> examples/rust-plugin/dist/rustdemo.zip
#
# 目标平台: 设备是 uClibc/musl 环境, 必须静态链接:
#   rustup target add x86_64-unknown-linux-musl
#   cargo build --release --target x86_64-unknown-linux-musl
set -e

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="x86_64-unknown-linux-musl"
PKG="$SELF_DIR/pkg"
OUT="$SELF_DIR/dist"
BIN="$SELF_DIR/target/$TARGET/release/rustdemo"

cd "$SELF_DIR"

echo "==> 准备目标 $TARGET"
rustup target add "$TARGET" >/dev/null 2>&1 || true

echo "==> 编译(静态 musl)"
cargo build --release --target "$TARGET"

echo "==> 组装插件包"
mkdir -p "$PKG/bin" "$OUT"
cp -f "$BIN" "$PKG/bin/rustdemo"
chmod +x "$PKG/bin/rustdemo" "$PKG"/*.sh "$PKG/function/rustdemo" 2>/dev/null
find "$PKG/www" -type f -exec chmod 644 {} \; 2>/dev/null

echo "==> 打包"
rm -f "$OUT/rustdemo.zip"
( cd "$PKG" && zip -qr "$OUT/rustdemo.zip" . )
ls -la "$OUT/rustdemo.zip"
unzip -l "$OUT/rustdemo.zip"

echo
echo "插件包: $OUT/rustdemo.zip"
echo "安装方式: 网页 系统设置 -> 插件管理 -> ikguard -> 插件管理 -> 选择 zip -> 上传并安装"
echo "         或命令行: ikplugin install $OUT/rustdemo.zip"
