#!/bin/bash
#
# bnfix 每次开机执行(优先级高于 install.sh)
#
# 为什么必须有这一步: 设备根分区(/dev/root)每次重启都从固件镜像还原,
# 我们对 /usr/lib/libcrypto.so.1.0.0 打的定点补丁也会随之消失, 所以必须在
# 每次开机重新打一遍。这也正是"卸载后重启即失效"的原因 —— 插件被卸载后
# 没有任何东西会再来打这个补丁, 根分区一还原就回到原始库。
#
# 另外: 若补丁打好时某个服务(nginx/ikdnsd)已经在跑, 它仍然持有旧库,
# 这里会检测并重启它们。

ROOT="${PLUGIN_DIR:-/etc/mnt/plugins/bnfix}"
BNFIX="$ROOT/bin/bnfix"
LOG=/etc/log/ikguard/bnfix.log
mkdir -p "$ROOT/data" "$(dirname "$LOG")" 2>/dev/null

echo "$(date '+%F %T') [boot] bnfix 开机处理开始" >> "$LOG"

[ -x "$BNFIX" ] || { echo "$(date '+%F %T') [boot] 缺少 $BNFIX, 跳过" >> "$LOG"; exit 0; }

enabled="$(sed -n 's/^enabled=//p' "$ROOT/data/state" 2>/dev/null | head -n1)"
if [ "${enabled:-0}" != "1" ]; then
    echo "$(date '+%F %T') [boot] 插件状态为关闭(enabled=$enabled), 不施加修复" >> "$LOG"
    exit 0
fi

# 记录打完补丁那一刻的 uptime: 之后只要某个服务的启动时刻晚于它,
# 就说明该服务是在补丁生效之后 exec 的, 用的是已修复的库。
"$BNFIX" apply >> "$LOG" 2>&1
echo "$(date '+%F %T') [boot] 补丁时刻 uptime=$(cut -d' ' -f1 /proc/uptime)" >> "$LOG"
"$BNFIX" restart >> "$LOG" 2>&1
echo "$(date '+%F %T') [boot] 状态: $("$BNFIX" status 2>/dev/null)" >> "$LOG"
exit 0
