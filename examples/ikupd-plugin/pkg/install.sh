#!/bin/bash
#
# ikupd 安装脚本(install 与每次开机都会执行, 必须幂等)
#
# 环境变量: PLUGIN_NAME PLUGIN_VERSION PLUGIN_DIR PLUGIN_ROOT PLUGIN_ACTION IK_SYSROOT
#
# 插件没有常驻进程/定时任务, 所以这里只需要把 data/ 目录和默认配置准备好:
#   data/repos.conf      仓库列表(一行一个 "<地址><TAB><说明>")
#   data/proxy.conf      代理开关 enabled / url / token
#   data/installed.conf  本插件装过的包哈希(升级判断用)
# 升级时框架会保留 data/, 因此所有 [ -f ] 判断都保证不覆盖用户设置。

ROOT="${PLUGIN_DIR:-/etc/mnt/plugins/ikupd}"
B="$ROOT/bin/ikupd"
DATA="$ROOT/data"
LOG=/etc/log/ikupd/ikupd.log

mkdir -p "$DATA/cache" "$DATA/dl" "$(dirname "$LOG")" 2>/dev/null
echo "$(date '+%F %T') [install] action=${PLUGIN_ACTION:-?} version=${PLUGIN_VERSION:-?} root=$ROOT" >> "$LOG"

if [ ! -x "$B" ]; then
    echo "[ikupd] 缺少可执行文件: $B" >&2
    exit 1
fi

[ -f "$DATA/proxy.conf" ]     || printf 'enabled=0\nurl=\ntoken=\n' > "$DATA/proxy.conf"
[ -f "$DATA/repos.conf" ]     || : > "$DATA/repos.conf"
[ -f "$DATA/installed.conf" ] || : > "$DATA/installed.conf"

chmod +x "$B" 2>/dev/null
echo "$(date '+%F %T') [install] 完成: $("$B" status 2>/dev/null)" >> "$LOG"
exit 0
