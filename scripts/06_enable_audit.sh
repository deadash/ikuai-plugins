#!/bin/bash
#
# 审计/取证: 进程启动、网络连接、封锁命中 -> /etc/log/ikguard
#
# 开关: /etc/mnt/boot_args 中 audit=1
#   audit=0 -> 不采集, 并移除定时任务(au_remove_cron) + 停掉 DNS 抓包
#   probe=1 定时自检(默认 0): 持久化, 只有开启才写入定时任务, 关闭则移除
# DNS 抓包不持久化: 重启即失效, 不进定时任务, 也不由本脚本启动
# 说明: 日志写在持久分区 /etc/log (sda5, 15.5G), 重启不丢;
#       根分区只有 ~800K 可用, 因此 /var/log/ikuai-boot.log 只做软链接。

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SELF_DIR/../lib/common.sh"
. "$SELF_DIR/../lib/backdoor.sh"
. "$SELF_DIR/../lib/audit.sh"

# 审计关闭时: 不仅要"不启动", 还要把已写入的定时任务清掉、停掉 DNS 抓包 ——
# 否则关掉开关后采集仍会每分钟继续跑(与"没开的功能不进定时任务"相矛盾)。
if ! is_enabled "audit"; then
    log "[audit] 未启用(audit=0): 停止采集并移除定时任务"
    au_remove_cron
    au_dns_stop quiet
    exit 0
fi

IKAUDIT="$(P /etc/mnt/.boot/bin/ikaudit)"

au_init                     # 建日志目录(不再重复 mkdir)

# 便捷软链: 保持旧路径 /var/log/ikuai-boot.log 可用
test -d "$(P /var/log)" && ln -sf "$(P "$IK_LOG")" "$(P /var/log/ikuai-boot.log)" 2>/dev/null

# 启动标记(每次开机在审计日志里留痕)
au_event INFO "boot.audit" "开机审计启动, 框架版本=$(sed -n 's/^version=//p' "$(P /etc/mnt/.boot/Release)" 2>/dev/null)"

# 首次快照(进程/连接)
"$IKAUDIT" proc >/dev/null 2>&1
"$IKAUDIT" conn >/dev/null 2>&1

# DNS 抓包: 默认关闭且**不持久化** —— 重启即失效, 开机不启动、cron 也不启动,
# 只有用户当次点击"启动 DNS 记录"才抓(见 ikaudit dns-start)。

# 体检报告(report 需要 ipset/iptables 已就绪, 放在最后; 非"云端连通性自检")
"$IKAUDIT" report

# 安装 cron(每分钟采集 + 每 10 分钟体检; 定时自检只有 probe=1 才加入)
au_install_cron

exit 0
