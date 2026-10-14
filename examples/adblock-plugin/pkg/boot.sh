#!/bin/bash
#
# ikadblock 开机脚本(存在 boot.sh 时开机只跑它, 不再跑 install.sh)
#
# 为什么必须有: 根分区每次重启从固件镜像还原 —— iptables 劫持规则、sinkhole 进程
# 全部消失(域名表在持久盘 data/ 里不会丢), 所以每次开机都要重新:
#   1) 起 ikdnsx sinkhole 实例   2) 装 LAN DNS 劫持规则   3) 拉起守护进程
#
# 注意: 开机这一刻 LAN 接口可能还没建好, 那时 iptables 会加不上规则;
#       守护进程(每 20s 一次幂等校准)会在接口就绪后补上, 所以这里失败不影响开机。

ROOT="${PLUGIN_DIR:-/etc/mnt/plugins/ikadblock}"
B="$ROOT/bin/ikadblock"
LOG=/etc/log/ikadblock/ikadblock.log
mkdir -p "$ROOT/data" "$(dirname "$LOG")" 2>/dev/null

echo "$(date '+%F %T') [boot] 开机处理开始 uptime=$(cut -d' ' -f1 /proc/uptime)" >> "$LOG"

[ -x "$B" ] || { echo "$(date '+%F %T') [boot] 缺少 $B, 跳过" >> "$LOG"; exit 0; }

enabled="$(sed -n 's/^enabled=//p' "$ROOT/data/state" 2>/dev/null | head -n1)"
if [ "${enabled:-0}" != "1" ]; then
    echo "$(date '+%F %T') [boot] 配置为关闭, 不做任何事" >> "$LOG"
    exit 0
fi

"$B" apply >> "$LOG" 2>&1
if [ "$(iptables -t nat -S PREROUTING 2>/dev/null | grep -c -- '-j IKADB')" = "0" ]; then
    echo "$(date '+%F %T') [boot] LAN 接口尚未就绪, 劫持规则由守护进程(前 2 分钟每 5 秒)补齐" >> "$LOG"
fi
echo "$(date '+%F %T') [boot] 状态: $("$B" status 2>/dev/null)" >> "$LOG"
exit 0
