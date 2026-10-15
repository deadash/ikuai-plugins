#!/bin/bash

# 框架公共库：开关判断、路径前缀、日志
# 配置文件：/etc/mnt/boot_args，内容形如 "sshd=1"

BOOT_ARGS="/etc/mnt/boot_args"

# 系统根前缀：留空 = 真实系统(设备上运行)；
# 设置后所有系统路径都会自动加上该前缀，便于在本地/沙箱离线模拟测试。
IK_SYSROOT="${IK_SYSROOT:-}"

# 为系统绝对路径加上测试前缀
P() {
    printf '%s' "${IK_SYSROOT}$1"
}

# 统一日志：控制台 + 日志文件
# 说明: 根分区每次重启还原且只有 ~800K 可用, 因此日志统一写到持久盘 /etc/log
#       (/etc/log 是独立分区 sda5, 容量大且重启不丢)。
IK_LOG_DIR="${IK_LOG_DIR:-/etc/log/ikguard}"
IK_LOG="${IK_LOG:-$IK_LOG_DIR/boot.log}"
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$$] $*"
    echo "$msg"
    mkdir -p "$(dirname "$(P "$IK_LOG")")" 2>/dev/null
    echo "$msg" >> "$(P "$IK_LOG")" 2>/dev/null
    return 0
}

# 读取 boot_args 中的值(缺省返回 $2)
get_flag() {
    local key="$1" def="$2" v
    v=$(sed -n "s/^${key}=//p" "$(P "$BOOT_ARGS")" 2>/dev/null | head -n1)
    printf '%s' "${v:-$def}"
}

# 检查功能是否启用
is_enabled() {
    test "$(get_flag "$1" 0)" = "1"
}

# 启用功能
enable() {
    test -f "$(P "$BOOT_ARGS")" || return 0
    sed -i "s/^$1=.*/$1=1/" "$(P "$BOOT_ARGS")"
}

# 禁用功能
disable() {
    test -f "$(P "$BOOT_ARGS")" || return 0
    sed -i "s/^$1=.*/$1=0/" "$(P "$BOOT_ARGS")"
}
