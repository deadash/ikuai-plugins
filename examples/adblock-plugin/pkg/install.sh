#!/bin/bash
#
# ikadblock 安装脚本(插件框架在 install 动作时执行, 必须幂等)
#   环境变量: PLUGIN_NAME PLUGIN_VERSION PLUGIN_DIR PLUGIN_ROOT PLUGIN_ACTION IK_SYSROOT
#
# 做的事:
#   * 建 data/ 与默认配置(首次安装默认"开启")
#   * 用内置种子表(share/seed.txt)重建域名表 —— 不联网也能立刻拦广告
#   * 起 sinkhole 实例 + 装 DNS 劫持规则 + 拉起守护
#   * 写 /etc/mnt/cron.d/ikadblock 定时守卫(框架开机软链进 /etc/crontabs/cron.d)

ROOT="${PLUGIN_DIR:-/etc/mnt/plugins/ikadblock}"
B="$ROOT/bin/ikadblock"
LOG=/etc/log/ikadblock/ikadblock.log
mkdir -p "$ROOT/data" "$(dirname "$LOG")" 2>/dev/null

echo "$(date '+%F %T') [install] action=${PLUGIN_ACTION:-?} version=${PLUGIN_VERSION:-?} root=$ROOT" >> "$LOG"

if [ ! -x "$B" ]; then
    echo "[ikadblock] 缺少可执行文件: $B" >&2
    exit 1
fi

# 首次安装的默认开关; 升级时保留用户已有配置(data/ 会被框架保留)
if [ ! -f "$ROOT/data/state" ]; then
    {
        echo "enabled=1"
        echo "auto_update=1"
        echo "block_ipv6=1"
        echo "last_update=0"
        echo "last_result=seed"
    } > "$ROOT/data/state"
fi
[ -f "$ROOT/data/sources.conf" ] || cp -f "$ROOT/share/sources.conf" "$ROOT/data/sources.conf" 2>/dev/null

# 定时守卫(兜住"守护进程被杀/规则被清"的情况; 失败不影响拦截本身)
# 框架开机会把 /etc/mnt/cron.d/* 软链进 /etc/crontabs/cron.d/, 这里先自己链一次,
# 让"装完不重启也能生效"(框架那步是幂等的)。
mkdir -p /etc/mnt/cron.d /etc/crontabs/cron.d 2>/dev/null
echo "* * * * * $B sync >/dev/null 2>&1" > /etc/mnt/cron.d/ikadblock 2>/dev/null
ln -sf /etc/mnt/cron.d/ikadblock /etc/crontabs/cron.d/ikadblock 2>/dev/null
if [ -f /usr/ikuai/include/crond.sh ]; then
    ( . /usr/ikuai/include/crond.sh; crond_commit ) >/dev/null 2>&1
fi

"$B" rebuild >> "$LOG" 2>&1

if [ "$(sed -n 's/^enabled=//p' "$ROOT/data/state" 2>/dev/null | head -n1)" = "1" ]; then
    "$B" apply >> "$LOG" 2>&1
    echo "$(date '+%F %T') [install] 状态: $("$B" status 2>/dev/null)" >> "$LOG"
else
    "$B" disable >> "$LOG" 2>&1
    echo "$(date '+%F %T') [install] 配置为关闭, 未启用拦截" >> "$LOG"
fi

exit 0
