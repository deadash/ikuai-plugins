#!/bin/bash
# 把 ikui 统一 UI 套件装进一个插件包。
#
# **一般不需要**：套件由基础包提供（/plugins/app/ikui.js / ikui.css，开机软链），
# 插件页直接 ./ikui.css + ./ikui.js 就能引到。而且这里装进去的副本还会被基础包那份
# 覆盖（plugin_web_ui_link 在 plugin_boot 之后跑）。
# 只有"想让插件在没升级基础包的旧设备上也能跑"时才用它自己带一份。
#
#   bash add-ui.sh <插件的 pkg 目录> [插件名]
#   bash add-ui.sh ~/work/mytool/pkg mytool
#
# 只做一件事：把 ikui.js / ikui.css 放进 <pkg>/www/plugins/app/。
#
# 为什么放 app/ 而不是 <pkg>/www/plugins/<名>/ui/：
#   **根分区空间极紧**，框架发布插件 Web 资源时要在 /usr/ikuai/www/plugins/ 下
#   逐个建软链/建目录；实测那里**已经建不出新目录了**（No space left on device），
#   但在已存在的 app/ 里建文件软链是可以的。
#   所以资源平铺在 app/、跟页面同目录，顺带接入也只有两行。
set -e

PKG="${1:-}"
NAME="${2:-plugin}"

if [ -z "$PKG" ]; then
    echo "用法: bash add-ui.sh <插件的 pkg 目录> [插件名]" >&2
    echo "例  : bash add-ui.sh ~/work/mytool/pkg mytool" >&2
    exit 1
fi
[ -d "$PKG" ] || { echo "!! 目录不存在: $PKG" >&2; exit 1; }

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$SKILL_DIR/assets/ui"
[ -f "$SRC/ikui.js" ] || { echo "!! 找不到 UI 套件: $SRC/ikui.js" >&2; exit 1; }

DST="$PKG/www/plugins/app"
mkdir -p "$DST"
cp -f "$SRC/ikui.js"  "$DST/ikui.js"
cp -f "$SRC/ikui.css" "$DST/ikui.css"

echo "已装入: $DST"
ls -la "$DST/ikui.js" "$DST/ikui.css" | awk '{printf "  %8.0f KB  %s\n", $5/1024, $9}'
echo
echo "页面（www/plugins/app/$NAME.html）里加这两行就行："
echo
echo '  <link rel="stylesheet" href="./ikui.css">'
echo '  <script src="./ikui.js"></script>'
echo
echo "用法、内置组件、x-template 那个坑，见:"
echo "  $SKILL_DIR/assets/ui/README.md"
