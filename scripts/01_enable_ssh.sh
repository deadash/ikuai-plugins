#!/bin/bash

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SELF_DIR/../lib/common.sh"

# 检查功能是否开启
is_enabled "sshd" || exit 0

# 开启sshd(把控制台登录shell换成bash)
#
# 设备上 sshd 账号的 shell 默认是 /etc/setup/rc —— 那是**控制台菜单程序**,
# 所以不改的话: SSH 能认证成功, 但每条命令只是在跑控制台菜单(表现就是"卡住不返回")。
#
# 这里做两件事, 保证换 shell 这件事稳:
#   1) 不依赖具体路径: 直接把 sshd 账号的 shell 字段整段替换成 /bin/bash
#   2) 兜底: 老固件里的字面路径替换写法(万一格式不同)
sed -i 's|^\(sshd:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\).*|\1/bin/bash|' "$(P /etc/passwd)"
sed -i 's|/etc/setup/rc|/bin/bash|' "$(P /etc/passwd)"

if grep -q '^sshd:.*:/bin/bash$' "$(P /etc/passwd)"; then
    log "[ssh] sshd 账号 shell 已换成 /bin/bash"
else
    log "[ssh] !! 未找到 sshd 账号(或 shell 替换失败): $(grep -c '^sshd:' "$(P /etc/passwd)")"
fi
