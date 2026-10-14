#!/bin/bash
#
# new-plugin.sh —— 从 assets/template/ 脚手架出一个新插件目录。
#
# 用法:
#   bash scripts/new-plugin.sh <插件名> [输出目录]
#
# 例:
#   bash .codebuddy/skills/ikuai-plugin-dev/scripts/new-plugin.sh mytool ~/work/mytool
#
# 做的事: 复制模板 -> 把文件名/内容里的 plugdemo 全部替换成 <插件名> -> 设置执行位。
# 输出目录默认为 ./<插件名>。生成后:
#   bash <输出目录>/build.sh        # 打成 dist/<插件名>.zip
#   bash scripts/deploy-plugin.sh <输出目录>/dist/<插件名>.zip
#
set -euo pipefail

NAME="${1:-}"
OUT="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TPL="$HERE/../assets/template"

[ -n "$NAME" ] || { echo "用法: $0 <插件名> [输出目录]" >&2; exit 1; }
case "$NAME" in
    [a-z0-9]*) ;;
    *) echo "插件名建议小写字母/数字/下划线开头(会成为目录名与卡片名): $NAME" >&2; exit 1 ;;
esac
[ -d "$TPL" ] || { echo "找不到模板: $TPL" >&2; exit 1; }
[ -n "$OUT" ] || OUT="$PWD/$NAME"
[ -e "$OUT" ] && { echo "输出目录已存在: $OUT" >&2; exit 1; }

OLD="plugdemo"

# 1) 复制(排除构建产物)
mkdir -p "$(dirname "$OUT")"
cp -r "$TPL" "$OUT"
rm -rf "$OUT/dist" 2>/dev/null || true

# 2) 重命名文件
[ -f "$OUT/pkg/bin/$OLD" ] && mv "$OUT/pkg/bin/$OLD" "$OUT/pkg/bin/$NAME"
[ -f "$OUT/pkg/function/$OLD" ] && mv "$OUT/pkg/function/$OLD" "$OUT/pkg/function/$NAME"
if [ -d "$OUT/pkg/www/plugins/$OLD" ]; then
    mv "$OUT/pkg/www/plugins/$OLD" "$OUT/pkg/www/plugins/$NAME"
    [ -f "$OUT/pkg/www/plugins/$NAME/$OLD.json" ] && mv "$OUT/pkg/www/plugins/$NAME/$OLD.json" "$OUT/pkg/www/plugins/$NAME/$NAME.json"
fi
[ -f "$OUT/pkg/www/plugins/app/$OLD.html" ] && mv "$OUT/pkg/www/plugins/app/$OLD.html" "$OUT/pkg/www/plugins/app/$NAME.html"
[ -f "$OUT/pkg/www/plugins/app/$OLD.png" ]  && mv "$OUT/pkg/www/plugins/app/$OLD.png"  "$OUT/pkg/www/plugins/app/$NAME.png"

# 3) 替换内容(只处理文本文件)
find "$OUT" -type f ! -name '*.png' | while read -r f; do
    sed -i "s/${OLD}/${NAME}/g" "$f"
done

# 4) 执行位(设备端框架会 test -x install.sh)
chmod +x "$OUT/build.sh" "$OUT/pkg/install.sh" "$OUT/pkg/boot.sh" "$OUT/pkg/uninstall.sh" 2>/dev/null || true
chmod +x "$OUT/pkg/bin/$NAME" "$OUT/pkg/function/$NAME" 2>/dev/null || true

cat <<EOF
已生成插件脚手架: $OUT

下一步:
  1) 改业务逻辑:
       $OUT/pkg/bin/$NAME           # 命令行/守护进程
       $OUT/pkg/function/$NAME      # Web 后端接口(action)
       $OUT/pkg/www/plugins/app/$NAME.html   # 页面
       $OUT/pkg/Release             # plugin=$NAME / version / comment
  2) 打包:   bash $OUT/build.sh
  3) 部署:   bash $HERE/deploy-plugin.sh $OUT/dist/$NAME.zip --install --reboot
  4) 观测:   bash $HERE/deploy-plugin.sh --status
EOF
