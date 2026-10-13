#!/bin/bash
#
# 插件系统入口(参考官方 firmwareid=90001 方案)
#
# 动作:
#   1) 安装 /etc/mnt/plugins/ 下新上传的 *.zip 插件包
#   2) 重新铺开所有已安装插件(根分区每次重启还原, 必须每开机重建)
#   3) 暴露命令行 /usr/sbin/ikplugin
#
# 开关: /etc/mnt/boot_args 中 plugins=1
# 使用条款: /etc/mnt/plugins/.eula 未同意时只铺"同意条款"占位卡片, 不显示真实插件

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SELF_DIR/../lib/common.sh"
. "$SELF_DIR/../lib/plugin.sh"

# 检查功能是否开启
is_enabled "plugins" || { log "[plugin] 未启用(plugins=0), 跳过"; exit 0; }

plugin_ensure_dirs

# 自动安装上传的 zip 包
plugin_scan_zips

# 重新铺开已安装插件
plugin_boot

# 同步 Web 插件资源与后端接口(根分区每次重启还原, 必须每开机重建)
#   -> /usr/ikuai/www/plugins/<name>/<name>.json
#   -> /usr/ikuai/www/plugins/docker/<name>.html|png
#   -> /usr/ikuai/function/<func_name>
plugin_web_sync
plugin_function_link

# 去掉「插件管理」页"需要绑定爱快云平台"的前端拦截(本框架插件不依赖云平台)
plugin_web_patch

# 暴露 ikplugin 命令
plugin_link_cli

exit 0
