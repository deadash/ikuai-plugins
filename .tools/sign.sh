#!/bin/bash

# 获取脚本所在目录的绝对路径（私钥所在目录）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 切换到上级目录（需要签名的文件目录）
cd "$SCRIPT_DIR/.." || exit 1

# 打包/签名共用的排除规则(见 package.exclude 里的说明):
#   清单里的文件必须与 build.sh 打进 tar 的文件**完全一致**, 否则设备端
#   plugins.sh 校验 sha256 失败会直接 return, 整包不挂载。
EXCLUDE_FILE="$SCRIPT_DIR/package.exclude"

is_excluded() {
    local p="$1" pat
    test -f "$EXCLUDE_FILE" || return 1
    while IFS= read -r pat; do
        test -z "$pat" && continue
        case "$pat" in \#*) continue ;; esac
        # 目录本身 + 目录下的任何文件(tar --exclude 是同一个语义)
        case "$p" in $pat|$pat/*) return 0 ;; esac
    done < "$EXCLUDE_FILE"
    return 1
}

# 创建签名文件
generate_signature() {
    echo "Manifest-Version: 1.0" > MANIFEST.MF
    echo "Created-By: SignTool 1.0" >> MANIFEST.MF
    echo "" >> MANIFEST.MF
    
    # 使用 -not -path "*/\.*" 排除所有.开头的文件和目录
    find . -type f \
        -not -path "*/\.*" \
        ! -path "./install.sh" \
        ! -name "MANIFEST.MF" \
        ! -name "SIGNATURE.RSA" \
        ! -path "./$(basename "$SCRIPT_DIR")/*" \
        -print0 | \
    while IFS= read -r -d '' file; do
        relative_path=${file#./}
        
        # 与 build.sh 保持一致的排除(构建产物不进包, 也就不进清单)
        is_excluded "$relative_path" && continue
        
        if [ "$relative_path" = "boot.sh" ]; then
            echo "Name: install.sh" >> MANIFEST.MF
        else
            echo "Name: $relative_path" >> MANIFEST.MF
        fi
        
        sha256=$(sha256sum "$file" | cut -d' ' -f1)
        echo "SHA-256-Digest: $sha256" >> MANIFEST.MF
        echo "" >> MANIFEST.MF
    done
    
    openssl dgst -sha256 -sign "$SCRIPT_DIR/private.pem" -out SIGNATURE.RSA MANIFEST.MF
}

# 清理旧的签名文件
rm -f MANIFEST.MF SIGNATURE.RSA

# 生成新的签名
generate_signature

echo "签名完成"