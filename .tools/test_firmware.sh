#!/bin/bash

# 测试函数
test_firmware() {
    local srcfile="$1"
    
    # 检查文件是否存在
    if [ ! -f "$srcfile" ]; then
        echo "错误：文件不存在"
        return 1
    fi
    
    # 创建临时目录
    local temp_dir="/tmp/test_firmware"
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"
    
    # 读取头部长度（4字节）
    local headlen=$(printf "%u" 0x$(hexdump -v -n 4 "$srcfile" -e '4/1 "%02x"'))
    echo "头部长度: $headlen 字节"
    
    # 检查头部长度是否合理
    if [ "$headlen" -ge 1048576 ]; then
        echo "错误：头部长度过大"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # 提取并解压头部信息
    echo "正在提取头部信息..."
    printf "\x1f\x8b\x08\x00\x6f\x9b\x4b\x59\x02\x03" > "$temp_dir/header.bin"
    dd if="$srcfile" bs=1 skip=4 count="$headlen" >> "$temp_dir/header.bin" 2>/dev/null
    
    if ! gunzip < "$temp_dir/header.bin" > "$temp_dir/header_info.json" 2>/dev/null; then
        echo "错误：头部解压失败"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # 显示头部 JSON 内容
    echo "头部 JSON 内容："
    cat "$temp_dir/header_info.json"
    
    # 提取固件部分
    echo "正在提取固件部分..."
    dd if="$srcfile" bs=$((headlen+4)) skip=1 of="$temp_dir/firmware.bin" 2>/dev/null
    
    # 计算固件信息
    local length=$(wc -c < "$temp_dir/firmware.bin")
    local md5sum=$(md5sum "$temp_dir/firmware.bin" | cut -d' ' -f1)
    local sha256sum=$(sha256sum "$temp_dir/firmware.bin" | cut -d' ' -f1)
    
    echo "固件信息："
    echo "大小: $length 字节"
    echo "MD5: $md5sum"
    echo "SHA256: $sha256sum"
    
    # 清理临时文件
    rm -rf "$temp_dir"
    
    return 0
}

# 使用方法
if [ $# -ne 1 ]; then
    echo "用法: $0 custom.bin"
    exit 1
fi

# 执行测试
test_firmware "$1"