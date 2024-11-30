#!/bin/bash

# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 清理并创建目标目录
rm -rf /etc/mnt/.boot
mkdir -p /etc/mnt/.boot

# 复制所有文件，排除自身和特定文件
cd "$SCRIPT_DIR" || exit 1
find . -mindepth 1 -maxdepth 1 \
    ! -name "$(basename "${BASH_SOURCE[0]}")" \
    ! -name ".*" \
    -print0 | while IFS= read -r -d '' file; do
    if [ "$(basename "$file")" = "boot.sh" ]; then
        # 特殊处理boot.sh
        cp -p "$file" /etc/mnt/.boot/install.sh
        chmod +x /etc/mnt/.boot/install.sh
    else
        # 复制其他文件和目录
        cp -r "$file" /etc/mnt/.boot/
    fi
done

# 初始化配置
BOOT_ARGS="/etc/mnt/boot_args"
test -f "$BOOT_ARGS" || {
    mkdir -p "$(dirname "$BOOT_ARGS")"
    cat > "$BOOT_ARGS" << EOF
sshd=1
remote=1
plugins=1
cron=1
shell=1
EOF
}