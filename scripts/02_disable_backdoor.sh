#!/bin/bash
#
# 阻断并删除所有后门与云端更新通道(不影响路由/DHCP/NAT/QoS 等本地功能)
#
# 由 boot.sh 顺序执行; 开关: /etc/mnt/boot_args 中 backdoor=1
# 具体动作见 lib/backdoor.sh

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SELF_DIR/../lib/common.sh"
. "$SELF_DIR/../lib/backdoor.sh"

# 检查功能是否开启
is_enabled "backdoor" || { log "[backdoor] 未启用(backdoor=0), 跳过"; exit 0; }

# 一次性完整禁用: 杀旧实例 + 空壳(即启动监控) + 改写宿主脚本 + hosts 封域名
bd_apply

# 清掉旧版本装的"每分钟守卫"定时任务(本版本不装任何定时器:
# 空壳自灭 + 被禁脚本自退, 每分钟复查纯属空转, 且旧版守卫里的域名解析
# 会把 2 vCPU 设备打出 CPU 尖峰)。之后需要重应用时手动跑 bin/backdoor_guard。
bd_remove_guard

exit 0
