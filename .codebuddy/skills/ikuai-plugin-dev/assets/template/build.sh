#!/bin/bash
#
# 组装 pkg/ 并打成 dist/<name>.zip —— 纯 shell 插件, 不需要编译。
#
# 关键点: zip 会保存 unix 权限位, 设备端解压后框架会 `test -x install.sh`,
#         所以打 zip 之前必须保证 pkg/ 下的脚本是可执行的(chmod +x)。
#
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

NAME="$(sed -n 's/^plugin=//p' pkg/Release | head -n1)"
: "${NAME:?pkg/Release 里缺少 plugin=}"

# 统一换行 + 执行位(仓库里 core.filemode=false, 光靠文件系统位不够, 见 SKILL.md)
find pkg -type f \( -name '*.sh' -o -path 'pkg/bin/*' -o -path 'pkg/function/*' \) | while read -r f; do
    sed -i 's/\r$//' "$f"
    chmod +x "$f"
done

mkdir -p dist
rm -f "dist/$NAME.zip"
( cd pkg && zip -qr "../dist/$NAME.zip" . )

echo "已生成: $DIR/dist/$NAME.zip"
unzip -l "dist/$NAME.zip"
