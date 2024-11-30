#!/bin/bash

# 配置文件路径
BOOT_ARGS="/etc/mnt/boot_args"

# 检查功能是否启用
is_enabled() {
    local function_name="$1"
    test -f "$BOOT_ARGS" && \
    grep -q "^${function_name}=1$" "$BOOT_ARGS"
}

# 启用功能
enable() {
    local function_name="$1"
    test -f "$BOOT_ARGS" && \
    sed -i "s/^${function_name}=.*/${function_name}=1/" "$BOOT_ARGS"
}

# 禁用功能
disable() {
    local function_name="$1"
    test -f "$BOOT_ARGS" && \
    sed -i "s/^${function_name}=.*/${function_name}=0/" "$BOOT_ARGS"
}