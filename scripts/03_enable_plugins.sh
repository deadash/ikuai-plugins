#!/bin/bash

. /etc/mnt/.boot/lib/common.sh

# 检查功能是否开启
is_enabled "plugins" || exit 0

