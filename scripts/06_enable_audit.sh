#!/bin/bash
#
# 审计/取证: **被动采集**(conntrack 连接事件) -> /etc/log/ikguard
#
# 开关: /etc/mnt/boot_args 中 audit=1 才运行采集器(默认 0)
#   * 采集器是常驻进程, **不占 cron**; audit=0 时停掉它, 并清理旧版本遗留的定时任务
#   * 持久化: 重启后按 boot_args 里的 audit 值决定是否重新拉起
#
# 说明: DNS 只是连接事件里 dport=53 的子集(不抓包); 也不做"程序启动"判断,
#       本内核没有 exec/fork 事件源(CONFIG_CONNECTOR/AUDIT/KPROBES/FTRACE 均未编译)。
#       被禁组件的启动尝试监控由空壳自己完成 -> /etc/log/ikguard/stub.log(零代价)。
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
    log "[audit] 未启用(audit=0): 停止采集并清理旧版定时任务"
    "$IKAUDIT" collect-stop >/dev/null 2>&1
fi

# 采集报告(事件计数)
"$IKAUDIT" report >/dev/null 2>&1

# 清掉旧版本写入的 ikaudit 定时任务(本框架不写任何 cron)
au_remove_cron

exit 0
