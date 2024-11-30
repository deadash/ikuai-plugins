#!/bin/bash

. /etc/mnt/.boot/lib/common.sh

# 检查功能是否开启
is_enabled "shell" || exit 0

# shell相关路径
SHELL_BIN="/etc/mnt/shells/bin"
SHELL_ETC="/etc/mnt/shells/etc"
TARGET_BIN="/usr/sbin"
TARGET_ETC="/usr/local/etc"

# 处理bin目录
test -d "$SHELL_BIN" && {
    # 确保目标目录存在
    test -d "$TARGET_BIN" || mkdir -p "$TARGET_BIN"
    
    # 处理可执行文件
    find "$SHELL_BIN" -type f -perm /111 -print0 | \
    while IFS= read -r -d '' file; do
        filename=$(basename "$file")
        # 如果是.sh结尾，去掉后缀
        if [[ "$filename" == *.sh ]]; then
            target="$TARGET_BIN/${filename%.sh}"
        else
            target="$TARGET_BIN/$filename"
        fi
        ln -sf "$(readlink -f "$file")" "$target"
    done
}

# 处理etc目录
test -d "$SHELL_ETC" && {
    # 确保目标目录存在
    test -d "$TARGET_ETC" || mkdir -p "$TARGET_ETC"
    
    # 处理文件和目录
    cd "$SHELL_ETC" || exit 1
    find . -mindepth 1 -print0 | \
    while IFS= read -r -d '' item; do
        # 去掉开头的./
        rel_path="${item#./}"
        target="$TARGET_ETC/$rel_path"
        
        # 创建目标目录
        test -d "$(dirname "$target")" || mkdir -p "$(dirname "$target")"
        
        # 创建链接（使用绝对路径）
        ln -sf "$(readlink -f "$SHELL_ETC/$rel_path")" "$target"
    done
}