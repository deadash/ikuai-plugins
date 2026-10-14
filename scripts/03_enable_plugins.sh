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

# 同步框架自带的 Web 插件资源(清空并重铺 /usr/ikuai/www/plugins,
# 未同意《使用条款》时只铺"同意入口"占位卡片) —— 必须在 plugin_boot 之前,
# 因为 plugin_boot 会给插件建卡片/页面软链。
plugin_web_sync

# 重新铺开已安装插件(会链接 bin/、www/、function/; 未同意条款时跳过 Web 部分)
plugin_boot

plugin_function_link

# 去掉「插件管理」页"需要绑定爱快云平台"的前端拦截(本框架插件不依赖云平台)
plugin_web_patch

# 固件侧补丁: 磁盘分区页加第 6 种绑定业务(插件存储), 配套 disk_mgmt.sh 与 i18n
plugin_fw_patch

# 插件存储: 若用户把某块数据盘绑成了「插件存储」业务(6), 上面那次 init 已经把它挂到
# /etc/disk_sys/plugin, 这里再把 /etc/mnt/plugins 挂到那块盘上(见 lib/plugin.sh)
# —— 必须在 plugin_fw_patch 之后: 数据盘是那一步才挂起来的
plugin_store_setup

# 注册免重启回调: 之后在磁盘分区页把某块盘绑成「插件存储」时, disk_mgmt 会立刻
# 执行 /etc/disk_notify/plugin, 插件目录当场切换(不用重启)
plugin_store_notify_install

# 暴露 ikplugin 命令
plugin_link_cli

exit 0
