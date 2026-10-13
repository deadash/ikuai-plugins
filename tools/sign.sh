#!/bin/bash
#
# 为插件包(.boot 目录)生成 MANIFEST.MF / SIGNATURE.RSA
# 兼容官方 /usr/ikuai/script/plugins.sh 的校验方式(openssl dgst -sha256 -verify)
#
# 用法:
#   tools/sign.sh <目录> [私钥]
#
# 注意: 修改 .boot 内任何一个被清单列出的文件后，都必须重新签名，
#       否则开机时 plugins.sh 校验失败，整个框架不会运行。

DIR="$1"
KEY="$2"

test -d "$DIR" || { echo "用法: $0 <目录> [私钥]"; exit 1; }
rm -f "$DIR/MANIFEST.MF" "$DIR/SIGNATURE.RSA"

{
    echo "Manifest-Version: 1.0"
    echo "Created-By: SignTool 1.0"
    echo
    ( cd "$DIR" && find . -type f ! -name MANIFEST.MF ! -name SIGNATURE.RSA -print0 | \
      sort -z | while IFS= read -r -d '' f; do
          rel="${f#./}"
          echo "Name: $rel"
          echo "SHA-256-Digest: $(sha256sum "$rel" | cut -d' ' -f1)"
          echo
      done )
} > "$DIR/MANIFEST.MF"

echo "已生成: $DIR/MANIFEST.MF"

if test -n "$KEY" && test -f "$KEY"; then
    openssl dgst -sha256 -sign "$KEY" -out "$DIR/SIGNATURE.RSA" "$DIR/MANIFEST.MF" && \
        echo "已签名: $DIR/SIGNATURE.RSA"
else
    echo "未提供私钥, 仅生成清单(官方 plugins.sh 将校验失败, 请用你的私钥签名)"
fi
