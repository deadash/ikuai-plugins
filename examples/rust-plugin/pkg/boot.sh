#!/bin/bash
#
# rustdemo 每次开机执行(优先于 install.sh):
# 根分区每次重启还原, 但插件本体在持久盘 /etc/mnt/plugins/rustdemo,
# 所以这里只需要把采集守护进程重新拉起来(数据库文件本身一直存在)。

ROOT="${PLUGIN_DIR:-/etc/mnt/plugins/rustdemo}"
BIN="$ROOT/bin/rustdemo"
DB="$ROOT/data/rustdemo.redb"
LOG_DIR=/etc/log/ikguard
LOG="$LOG_DIR/rustdemo.log"
PID="$ROOT/data/daemon.pid"

mkdir -p "$ROOT/data" "$LOG_DIR" 2>/dev/null
echo "$(date '+%F %T') [boot] 拉起 rustdemo 守护" >> "$LOG"

[ -x "$BIN" ] || { echo "$(date '+%F %T') [boot] 缺少 $BIN" >> "$LOG"; exit 0; }

# 清掉上次的残留实例(重启后 pid 文件可能指向别的进程)
if [ -f "$PID" ]; then
    kill "$(cat "$PID" 2>/dev/null)" 2>/dev/null
    rm -f "$PID"
fi
pkill -f "rustdemo .*daemon" 2>/dev/null
sleep 1

"$BIN" --db "$DB" init >> "$LOG" 2>&1
( trap '' HUP; exec "$BIN" --db "$DB" daemon >> "$LOG" 2>&1 ) &
sleep 1

if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
    echo "$(date '+%F %T') [boot] 守护进程已启动 pid=$(cat "$PID")" >> "$LOG"
else
    echo "$(date '+%F %T') [boot] 警告: 守护进程未启动" >> "$LOG"
fi
exit 0
