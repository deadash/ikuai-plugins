#!/bin/bash

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SELF_DIR/../lib/common.sh"
. "$SELF_DIR/../lib/sshguard.sh"

# SSH 加固(开关 sshguard):
#   ① 公网访问 SSH 的封禁 —— 跟开关走: 开=落规则(只拦 wan/vwan/adsl 入向的新连接),
#      关=撤销规则(靠 /etc/mnt/ikguard/sshguard.on 标记判断"曾经生效过", 没开过就一个
#      iptables 调用都不发)
#   ② 来源 IP 一键封禁名单(/etc/mnt/ikguard/ssh-ban.list) —— 不看开关, 始终重放:
#      显式封禁是用户的决定, 必须跨重启保持
#
# 本脚本不常驻、不写 cron: 规则只在开机(这里)与 Web"重新应用/切开关"时落一次。
# 所以这里**不能**像别的脚本那样 is_enabled 早退 —— 关闭开关时也要跑一次把规则撤掉。
sg_apply
