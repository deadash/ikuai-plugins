#!/bin/bash
#
# bnfix 卸载脚本
#
# 做两件事:
#   1) 立刻把库还原成原始字节(或卸载 bind mount), 让"不重启"也能恢复;
#   2) 交给框架删掉插件目录 —— 之后重启时根分区还原, 没有任何东西会再打补丁,
#      修复自然失效(这就是"卸载后重启失效")。

ROOT="${PLUGIN_DIR:-/etc/mnt/plugins/bnfix}"
BNFIX="$ROOT/bin/bnfix"
LOG=/etc/log/ikguard/bnfix.log
mkdir -p "$(dirname "$LOG")" 2>/dev/null

echo "$(date '+%F %T') [uninstall] 开始还原" >> "$LOG"

if [ -x "$BNFIX" ]; then
    "$BNFIX" revert >> "$LOG" 2>&1
    "$BNFIX" restart >> "$LOG" 2>&1
fi

# 清掉状态与残留(插件目录由框架删除)
rm -f "$ROOT/data/state" 2>/dev/null
rm -f /usr/sbin/bnfix /usr/ikuai/function/bnfix 2>/dev/null
rm -f /usr/ikuai/www/plugins/app/bnfix.html /usr/ikuai/www/plugins/app/bnfix.png 2>/dev/null
rmdir /usr/ikuai/www/plugins/bnfix 2>/dev/null

echo "$(date '+%F %T') [uninstall] 完成; 注意: 已在运行的进程仍持有旧库, 重启设备后彻底恢复" >> "$LOG"
exit 0
