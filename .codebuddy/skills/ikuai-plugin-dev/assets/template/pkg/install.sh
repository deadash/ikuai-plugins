#!/bin/bash
#
# install.sh —— 框架在"安装"动作时执行, 必须幂等(重复安装不能报错/不能叠加)。
#
# 框架会传入环境变量:
#   PLUGIN_NAME PLUGIN_VERSION PLUGIN_DIR PLUGIN_ROOT PLUGIN_ACTION IK_SYSROOT
#
# 注意: "开机自启"不靠这里, 而靠同目录的 boot.sh; 本脚本只负责
#       "装完这一刻立刻能用"(初始化 + 拉起进程), 让用户不用重启就能看到效果。

set -u
ROOT="${PLUGIN_DIR:-/etc/mnt/plugins/plugdemo}"
BIN="$ROOT/bin/plugdemo"
LOG=/etc/log/ikguard/plugdemo.log          # 日志放持久分区 /etc/log, 不要写根分区

mkdir -p "$ROOT/data" "$(dirname "$LOG")" 2>/dev/null
echo "$(date '+%F %T') [install] action=${PLUGIN_ACTION:-?} version=${PLUGIN_VERSION:-?} root=$ROOT" >> "$LOG"

if [ ! -x "$BIN" ]; then
    echo "[plugdemo] 缺少可执行文件: $BIN" >&2
    exit 1
fi

"$BIN" init         >> "$LOG" 2>&1   # 建库建表(幂等)
"$BIN" daemon-start >> "$LOG" 2>&1   # 后台拉起采集进程
exit 0
