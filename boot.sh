#!/bin/bash

# 依次执行 scripts/NN_* (按文件名数字排序)
# 说明: 部署到设备后本文件会被改名为 .boot/install.sh, 由官方 plugins.sh 校验签名后调用
execute_scripts()
{
    local boot_path script
    boot_path="$(cd "$(dirname "$0")" && pwd)"

    test -d "$boot_path/scripts" || return 0

    find "$boot_path/scripts" -maxdepth 1 -type f -name "[0-9][0-9]*" -print0 | \
    sort -z -n | \
    while IFS= read -r -d '' script; do
        # 兼容丢失可执行位的情况(Windows/zip 拷贝后常见)
        if test -x "$script"; then
            "$script"
        else
            bash "$script"
        fi
    done
    return 0
}

execute_scripts
