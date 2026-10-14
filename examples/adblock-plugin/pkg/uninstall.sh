#!/bin/bash
#
# ikadblock 卸载脚本
#
# 做三件事:
#   1) 撤掉 DNS 劫持规则、停 sinkhole 实例与守护进程(立刻恢复原样, 不用重启);
#   2) 摘掉定时守卫, 并让 iKuai 重新汇总 crontab(否则 /etc/crontabs/root 里还留着
#      指向已删除插件的行);
#   3) 清掉框架之外可能残留的软链(插件目录由框架删除)。

ROOT="${PLUGIN_DIR:-/etc/mnt/plugins/ikadblock}"
B="$ROOT/bin/ikadblock"
LOG=/etc/log/ikadblock/ikadblock.log
mkdir -p "$(dirname "$LOG")" 2>/dev/null

echo "$(date '+%F %T') [uninstall] 开始清理" >> "$LOG"

[ -x "$B" ] && "$B" revert >> "$LOG" 2>&1

rm -f /etc/mnt/cron.d/ikadblock /etc/crontabs/cron.d/ikadblock 2>/dev/null
rm -f /usr/sbin/ikadblock /usr/ikuai/function/ikadblock 2>/dev/null
rm -f /usr/ikuai/www/plugins/app/ikadblock.html /usr/ikuai/www/plugins/app/ikadblock.png 2>/dev/null
rmdir /usr/ikuai/www/plugins/ikadblock 2>/dev/null
if [ -f /usr/ikuai/include/crond.sh ]; then
    ( . /usr/ikuai/include/crond.sh; crond_commit ) >/dev/null 2>&1
fi

echo "$(date '+%F %T') [uninstall] 完成: 劫持规则/实例/守护均已清除" >> "$LOG"
exit 0
