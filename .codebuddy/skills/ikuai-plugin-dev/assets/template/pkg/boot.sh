#!/bin/bash
#
# boot.sh —— 每次开机执行(存在时优先于 install.sh)。
#
# 为什么必须有: 设备根分区(/)每次重启都从固件镜像还原 —— /usr/sbin 软链、Web 页面
# 软链都会消失(框架会重新铺), 而"常驻进程"更是重启就没了。插件本体在持久盘
# /etc/mnt/plugins/<name>, 不会丢, 所以开机只要把进程重新拉起来即可。
#
# 重要: 超时/卡死会拖慢开机, 所以这里的动作要"快且可失败" —— 单步失败打印日志后继续。

set -u
ROOT="${PLUGIN_DIR:-/etc/mnt/plugins/plugdemo}"
BIN="$ROOT/bin/plugdemo"
LOG=/etc/log/ikguard/plugdemo.log

mkdir -p "$ROOT/data" "$(dirname "$LOG")" 2>/dev/null
echo "$(date '+%F %T') [boot] 开机处理开始 (uptime=$(cut -d' ' -f1 /proc/uptime))" >> "$LOG"

[ -x "$BIN" ] || { echo "$(date '+%F %T') [boot] 缺少 $BIN, 跳过" >> "$LOG"; exit 0; }

"$BIN" init         >> "$LOG" 2>&1
"$BIN" daemon-start >> "$LOG" 2>&1
echo "$(date '+%F %T') [boot] 状态: $("$BIN" status 2>/dev/null)" >> "$LOG"
exit 0
