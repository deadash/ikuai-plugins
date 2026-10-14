#!/bin/bash
#
# ikupd 卸载脚本
#
# 插件没有常驻进程/定时任务/数据面改动, 所以要做的只有:
#   1) 删掉暂存的下载包(别占持久盘 43MB)
#   2) 清掉框架之外可能残留的软链(插件目录随后由框架删除)

ROOT="${PLUGIN_DIR:-/etc/mnt/plugins/ikupd}"
LOG=/etc/log/ikupd/ikupd.log
mkdir -p "$(dirname "$LOG")" 2>/dev/null

echo "$(date '+%F %T') [uninstall] 开始清理" >> "$LOG"

rm -rf "$ROOT/data/dl" 2>/dev/null
rm -f /usr/sbin/ikupd /usr/ikuai/function/ikupd 2>/dev/null
rm -f /usr/ikuai/www/plugins/app/ikupd.html /usr/ikuai/www/plugins/app/ikupd.png 2>/dev/null
rmdir /usr/ikuai/www/plugins/ikupd 2>/dev/null

echo "$(date '+%F %T') [uninstall] 完成(暂存包已删除, 仓库列表随插件目录一起删除)" >> "$LOG"
exit 0
