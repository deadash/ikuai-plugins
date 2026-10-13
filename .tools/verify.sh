#!/bin/bash

# 切换到上级目录(需要校验的目录), 公钥取脚本自身所在目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PUBKEY="$SCRIPT_DIR/public.pem"
cd "$SCRIPT_DIR/.." || exit 1

verify_files() {
    local current_file=""
    local expected_hash=""
    
    # 首先验证MANIFEST.MF的签名
    if ! openssl dgst -sha256 -verify "$PUBKEY" -signature SIGNATURE.RSA MANIFEST.MF; then
        echo "签名验证失败"
        exit 1
    fi
    
    # 验证每个文件
    while IFS= read -r line; do
        if [[ $line =~ ^Name:\ (.+)$ ]]; then
            current_file="${BASH_REMATCH[1]}"
            # 特殊处理install.sh
            if [ "$current_file" = "install.sh" ]; then
                current_file="boot.sh"
            fi
        elif [[ $line =~ ^SHA-256-Digest:\ (.+)$ ]]; then
            expected_hash="${BASH_REMATCH[1]}"
            
            if [ -f "$current_file" ]; then
                actual_hash=$(sha256sum "$current_file" | cut -d' ' -f1)
                if [ "$actual_hash" != "$expected_hash" ]; then
                    echo "文件 $current_file 校验失败"
                    exit 1
                fi
            else
                echo "文件 $current_file 不存在"
                exit 1
            fi
        fi
    done < MANIFEST.MF
    
    echo "验证成功"
}

# 检查必要文件是否存在
if [ ! -f MANIFEST.MF ] || [ ! -f SIGNATURE.RSA ]; then
    echo "清单文件或签名文件不存在"
    exit 1
fi

verify_files