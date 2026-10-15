#!/bin/bash

# 依次执行 scripts/NN_* (按文件名数字排序)
# 说明: 部署到设备后本文件会被改名为 .boot/install.sh, 由官方 plugins.sh 校验签名后调用
#
# 开机先把框架自己copy一份到内存(/tmp/.boot)再从那儿执行。原因:
#   1) 维护类脚本(如 09_expand_mnt.sh 扩容 /etc/mnt)需要改 /etc/mnt 所在的分区,
#      而 bash 是边读边执行脚本的 —— 自己一直占着那个分区, 既改不干净也读不下去;
#   2) 万一持久盘出问题, 已经起来的框架脚本不受影响。
BOOT_SELF="$(cd "$(dirname "$0")" && pwd)"
if [ "$BOOT_SELF" != "/tmp/.boot" ]; then
    rm -rf /tmp/.boot 2>/dev/null
    mkdir -p /tmp/.boot 2>/dev/null && \
    cp -a "$BOOT_SELF"/. /tmp/.boot/ 2>/dev/null && \
    [ -x /tmp/.boot/install.sh ] && exec /tmp/.boot/install.sh "$@"
fi

execute_scripts()
{
    local boot_path script
    boot_path="$(cd "$(dirname "$0")" && pwd)"

    test -d "$boot_path/scripts" || return 0

    # 用通配符按文件名排序(字典序 = 数字序): 不依赖 find -print0 / sort -z 这些 busybox 可能
    # 没编进去的选项, 顺序也是确定的(原来 sort -n 拿整条路径比较, 数值其实都相同, 只靠实现细节)
    for script in "$boot_path"/scripts/[0-9][0-9]*; do
        [ -f "$script" ] || continue
        # 兼容丢失可执行位的情况(Windows/zip 拷贝后常见)
        if [ -x "$script" ]; then
            "$script" || echo "[boot] 脚本执行失败: $(basename "$script")"
        else
            bash "$script" || echo "[boot] 脚本执行失败: $(basename "$script")"
        fi
    done
    return 0
}

execute_scripts
