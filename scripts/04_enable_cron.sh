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
    ln -sf "$file" "$CRON_TARGET/"
done

# 测试日志
is_enabled "cron_test" || exit 0

sed -i 's|crond -L /dev/null|crond -L /var/log/crond.log|' /usr/ikuai/script/utils/crond.sh