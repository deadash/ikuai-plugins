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

# 一次性完整禁用
bd_apply

# 安装每分钟守卫(系统重建 iptables 后自动补回封锁)
bd_install_guard

exit 0
