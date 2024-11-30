#!/bin/bash

# 日志相关配置
LOG_DIR="/var/log/test"
LOG_FILE="$LOG_DIR/test.log"

# 确保日志目录存在
test -d "$LOG_DIR" || mkdir -p "$LOG_DIR"

# 生成日志
log_test() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] Test running OK" >> "$LOG_FILE"
    
    # 保持日志文件不会太大
    test -f "$LOG_FILE" && {
        local size=$(stat -f %z "$LOG_FILE" 2>/dev/null || stat -c %s "$LOG_FILE")
        test "$size" -gt $((1024 * 1024)) && {  # 大于1MB时轮转
            mv "$LOG_FILE" "$LOG_FILE.old"
        }
    }
}

# 执行测试
log_test