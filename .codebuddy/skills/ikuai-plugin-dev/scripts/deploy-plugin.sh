#!/bin/bash
#
# deploy-plugin.sh —— 通过 SSH 在真机上安装/卸载/重启/观测插件(封装 ikctl.py)。
#
# 用法:
#   bash deploy-plugin.sh <zip>  --install [--reboot]   # 推送并 ikplugin install
#   bash deploy-plugin.sh <zip>  --scan    [--reboot]   # 推送并 ikplugin scan
#   bash deploy-plugin.sh --remove <名称>  [--reboot]   # ikplugin remove
#   bash deploy-plugin.sh --reboot                      # 重启并等 SSH 回来
#   bash deploy-plugin.sh --status                      # 一次性观测(插件/软链/页面/日志)
#   bash deploy-plugin.sh --sh '<命令>'                 # 设备上执行任意命令
#
# 环境变量(都有默认值, 按需覆盖):
#   IKCTL=/home/deadash/ikuai/ikctl.py
#   IK_PY=/home/deadash/ikuai/.venv/bin/python     # paramiko 所在的解释器
#   IK_PASS=<控制台密码>                            # 必需
#   IK_HOST=127.0.0.1 IK_PORT=10022                 # 由 ikctl.py 读取
#
set -euo pipefail

IKCTL="${IKCTL:-/home/deadash/ikuai/ikctl.py}"
IK_PY="${IK_PY:-/home/deadash/ikuai/.venv/bin/python}"
: "${IK_PASS:?请先导出设备密码, 例: export IK_PASS='Ikuai@2026'}"

ik() { "$IK_PY" "$IKCTL" "$@"; }

reboot=0
args=()
for a in "$@"; do
    case "$a" in
        --reboot) reboot=1 ;;
        *) args+=("$a") ;;
    esac
done
set -- "${args[@]:-}"

cmd="${1:-}"
case "$cmd" in
    --status)
        ik sh '
echo "== 已安装插件 =="; ikplugin list
echo "== 插件目录 =="; ls -l /etc/mnt/plugins/ 2>&1
echo "== 软链 =="; ls -l /usr/sbin/ /usr/ikuai/function/ 2>/dev/null | grep -E "^l" | tail -20
echo "== Web 卡片与页面 =="; ls -lR /usr/ikuai/www/plugins/ 2>&1 | head -30
echo "== boot_args =="; cat /etc/mnt/boot_args
echo "== plugins_ok =="; cat /etc/plugins_ok 2>&1
echo "== /etc/log/ikguard =="; ls -l /etc/log/ikguard/ 2>&1
'
        ;;
    --reboot)
        ik reboot --wait
        ;;
    --remove)
        name="${2:?用法: deploy-plugin.sh --remove <名称>}"
        ik sh "ikplugin remove $name; ikplugin list"
        [ "$reboot" = 1 ] && ik reboot --wait || true
        ;;
    --sh)
        ik sh "${2:?用法: deploy-plugin.sh --sh '<命令>'}"
        ;;
    ""|--help|-h)
        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        zip="$1"; action="${2:---install}"
        [ -f "$zip" ] || { echo "找不到插件包: $zip" >&2; exit 1; }
        remote="/root/$(basename "$zip")"
        echo ">> 推送 $zip -> $remote"
        ik push "$zip" "$remote"
        case "$action" in
            --install) echo ">> ikplugin install"; ik sh "ikplugin install $remote; ikplugin list" ;;
            --scan)    echo ">> ikplugin scan";    ik sh "cp -f $remote /etc/mnt/plugins/ && ikplugin scan; ikplugin list" ;;
            *) echo "未知动作: $action (用 --install / --scan)" >&2; exit 1 ;;
        esac
        [ "$reboot" = 1 ] && { echo ">> 重启并等待"; ik reboot --wait; }
        ;;
esac
