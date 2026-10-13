#!/bin/bash
#
# 审计/取证: 进程启动、DNS 请求、网络连接、封锁命中 -> /etc/log/ikguard
#
# 开关: /etc/mnt/boot_args 中 audit=1
# 说明: 日志写在持久分区 /etc/log (sda5, 15.5G), 重启不丢;
#       根分区只有 ~800K 可用, 因此 /var/log/ikuai-boot.log 只做软链接。

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SELF_DIR/../lib/common.sh"
. "$SELF_DIR/../lib/backdoor.sh"
. "$SELF_DIR/../lib/audit.sh"

is_enabled "audit" || { log "[audit] 未启用(audit=0), 跳过"; exit 0; }

IKAUDIT="$(P /etc/mnt/.boot/bin/ikaudit)"

au_init
mkdir -p "$(au_dir)" 2>/dev/null

# 便捷软链: 保持旧路径 /var/log/ikuai-boot.log 可用
test -d "$(P /var/log)" && ln -sf "$(P "$IK_LOG")" "$(P /var/log/ikuai-boot.log)" 2>/dev/null

# 启动标记(每次开机在审计日志里留痕)
au_event INFO "boot.audit" "开机审计启动, 框架版本=$(sed -n 's/^version=//p' "$(P /etc/mnt/.boot/Release)" 2>/dev/null)"

# 首次快照
"$IKAUDIT" init >/dev/null 2>&1
"$IKAUDIT" proc >/dev/null 2>&1
"$IKAUDIT" conn >/dev/null 2>&1

# DNS 记录(tcpdump); report 需要 ipset/iptables 已就绪, 放在最后
"$IKAUDIT" dns-start >/dev/null 2>&1
"$IKAUDIT" report

# 安装 cron(每分钟采集 + 每 10 分钟体检)
au_install_cron

exit 0
