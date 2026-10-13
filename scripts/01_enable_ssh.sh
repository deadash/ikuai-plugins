#!/bin/bash

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SELF_DIR/../lib/common.sh"

# 检查功能是否开启
is_enabled "sshd" || exit 0

# 开启sshd(把控制台登录shell换成bash)
sed -i 's|/etc/setup/rc|/bin/bash|' "$(P /etc/passwd)"
log "[ssh] 已开启 sshd 登录"
