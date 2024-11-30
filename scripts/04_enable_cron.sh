#!/bin/bash

. /etc/mnt/.boot/lib/common.sh

# 检查功能是否开启
is_enabled "cron" || exit 0

# cron相关路径
CRON_SOURCE="/etc/mnt/cron.d"
CRON_TARGET="/etc/crontabs/cron.d"

# 确保目标目录存在
test -d "$CRON_TARGET" || mkdir -p "$CRON_TARGET"

# 拷贝cron文件
test -d "$CRON_SOURCE" && \
find "$CRON_SOURCE" -type f -print0 | \
while IFS= read -r -d '' file; do
    cp -p "$file" "$CRON_TARGET/"
done