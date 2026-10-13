#!/bin/bash
#
# rustdemo 插件安装脚本(由插件框架执行, 需要幂等)
#   环境变量: PLUGIN_NAME PLUGIN_VERSION PLUGIN_DIR PLUGIN_ROOT PLUGIN_ACTION IK_SYSROOT
#
# 做三件事:
#   1) 准备持久化目录(数据库放这里, 重启不丢)
#   2) 初始化数据库与默认配置
#   3) 拉起采集守护进程

ROOT="${PLUGIN_DIR:-/etc/mnt/plugins/rustdemo}"
BIN="$ROOT/bin/rustdemo"
DB="$ROOT/data/rustdemo.redb"
LOG_DIR=/etc/log/ikguard
LOG="$LOG_DIR/rustdemo.log"
PID="$ROOT/data/daemon.pid"

mkdir -p "$ROOT/data" "$LOG_DIR" 2>/dev/null
echo "$(date '+%F %T') [install] action=$PLUGIN_ACTION version=$PLUGIN_VERSION root=$ROOT" >> "$LOG"

if [ ! -x "$BIN" ]; then
    echo "[rustdemo] 找不到可执行文件: $BIN" >&2
    exit 1
fi

# 1) 初始化数据库/默认配置(幂等)
"$BIN" --db "$DB" init >> "$LOG" 2>&1

# 2) 重启守护进程(避免重复实例)
[ -f "$PID" ] && kill "$(cat "$PID" 2>/dev/null)" 2>/dev/null
pkill -f "rustdemo .*daemon" 2>/dev/null
sleep 1
( trap '' HUP; exec "$BIN" --db "$DB" daemon >> "$LOG" 2>&1 ) &
sleep 1

if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
    echo "[rustdemo] 安装完成, 守护进程 pid=$(cat "$PID")" >> "$LOG"
else
    echo "[rustdemo] 警告: 守护进程可能未启动" >> "$LOG"
fi
exit 0
