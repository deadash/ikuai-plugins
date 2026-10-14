#!/bin/bash
#
# bnfix 安装脚本(由插件框架在 install 动作时执行, 必须幂等)
#   环境变量: PLUGIN_NAME PLUGIN_VERSION PLUGIN_DIR PLUGIN_ROOT PLUGIN_ACTION IK_SYSROOT
#
# 做的事: 把修复"打开"——默认给 /usr/lib/libcrypto.so.1.0.0 打 1 字节定点补丁,
#         并顺手尝试重启受影响的服务。根分区每次重启还原, 所以真正"开机即生效"
#         靠 boot.sh, 这里只是让"安装完立刻能自检"。

ROOT="${PLUGIN_DIR:-/etc/mnt/plugins/bnfix}"
BNFIX="$ROOT/bin/bnfix"
LOG=/etc/log/ikguard/bnfix.log
mkdir -p "$ROOT/data" "$(dirname "$LOG")" 2>/dev/null

echo "$(date '+%F %T') [install] action=${PLUGIN_ACTION:-?} version=${PLUGIN_VERSION:-?} root=$ROOT" >> "$LOG"

if [ ! -x "$BNFIX" ]; then
    echo "[bnfix] 缺少可执行文件: $BNFIX" >&2
    exit 1
fi

"$BNFIX" apply
rc=$?
"$BNFIX" restart
echo "$(date '+%F %T') [install] apply rc=$rc, 状态: $("$BNFIX" status)" >> "$LOG"
exit 0
