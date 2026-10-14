#!/bin/bash
#
# 审计/取证: **被动采集**(conntrack 事件 + 内核封锁日志) -> /etc/log/ikguard
#
# 开关: /etc/mnt/boot_args 中 audit=1 才运行采集器(默认 0)
#   * 采集器是常驻进程, **不占 cron**; audit=0 时停掉它并移除定时任务
#   * 持久化: 重启后按 boot_args 里的 audit 值决定是否重新拉起
#   * probe=1 时才写"定时自检"的 cron(默认 0)
#
# 说明: DNS 只是连接事件里 dport=53 的子集(不抓包); 也不做"程序启动"判断,
#       本内核没有 exec/fork 事件源(CONFIG_CONNECTOR/AUDIT/KPROBES/FTRACE 均未编译)。
#       日志写在持久分区 /etc/log (sda5, 15.5G), 重启不丢;
#       根分区只有 ~800K 可用, 因此 /var/log/ikuai-boot.log 只做软链接。

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SELF_DIR/../lib/common.sh"
. "$SELF_DIR/../lib/backdoor.sh"
. "$SELF_DIR/../lib/audit.sh"

IKAUDIT="$(P /etc/mnt/.boot/bin/ikaudit)"

au_init

# 便捷软链: 保持旧路径 /var/log/ikuai-boot.log 可用
test -d "$(P /var/log)" && ln -sf "$(P "$IK_LOG")" "$(P /var/log/ikuai-boot.log)" 2>/dev/null

if is_enabled "audit"; then
    au_event INFO "boot.audit" "开机审计启动, 框架版本=$(sed -n 's/^version=//p' "$(P /etc/mnt/.boot/Release)" 2>/dev/null)"
    "$IKAUDIT" collect-start >/dev/null 2>&1
else
    log "[audit] 未启用(audit=0): 停止采集并移除定时任务"
    "$IKAUDIT" collect-stop >/dev/null 2>&1
    au_remove_cron
fi

# 采集报告(ipset/规则/事件计数)
"$IKAUDIT" report >/dev/null 2>&1

# 定时任务: 采集不占 cron, 只有 probe=1(定时自检)才写一条
au_install_cron

exit 0
