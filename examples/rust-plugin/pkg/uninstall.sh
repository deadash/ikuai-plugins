#!/bin/bash
#
# rustdemo 卸载脚本: 停掉守护进程并清理运行痕迹
# (插件目录 /etc/mnt/plugins/rustdemo 由框架删除, 数据库文件随之消失)

ROOT="${PLUGIN_DIR:-/etc/mnt/plugins/rustdemo}"
BIN="$ROOT/bin/rustdemo"
PID="$ROOT/data/daemon.pid"
LOG=/etc/log/ikguard/rustdemo.log

mkdir -p "$(dirname "$LOG")" 2>/dev/null
echo "$(date '+%F %T') [uninstall] 停止 rustdemo 守护" >> "$LOG"

if [ -f "$PID" ]; then
    kill "$(cat "$PID" 2>/dev/null)" 2>/dev/null
    rm -f "$PID"
fi
pkill -f "rustdemo .*daemon" 2>/dev/null
[ -x "$BIN" ] && "$BIN" --db "$ROOT/data/rustdemo.redb" drop >> "$LOG" 2>&1

rm -f /usr/sbin/rustdemo /usr/ikuai/function/rustdemo 2>/dev/null
rm -rf /usr/ikuai/www/plugins/app/rustdemo.html /usr/ikuai/www/plugins/app/rustdemo.png 2>/dev/null
rmdir /usr/ikuai/www/plugins/rustdemo 2>/dev/null

echo "$(date '+%F %T') [uninstall] 完成" >> "$LOG"
exit 0
