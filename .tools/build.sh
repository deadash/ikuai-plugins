#!/bin/bash

# 获取脚本所在目录的绝对路径（私钥所在目录）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 切换到上级目录
cd "$SCRIPT_DIR/.." || exit 1

# 创建 .dist 目录
mkdir -p .dist

# sign
$SCRIPT_DIR/sign.sh

# 定义输出文件名
OUTPUT=".dist/firmware.bin"
JSON_FILE=".dist/firmware.json"
TEMP_GZ=".dist/temp.gz"
FINAL_OUTPUT=".dist/custom.bin"


find . -name "*.sh" -type f -exec chmod +x {} \;

# 压缩文件，忽略 . 开头的文件和目录
# 排除规则与 sign.sh 共用 .tools/package.exclude —— 清单与实际打包内容必须完全一致,
# 否则设备端 plugins.sh 校验摘要失败会直接 return, 整包不挂载(详见 package.exclude 注释)
tar --exclude='.*' --exclude-from="$SCRIPT_DIR/package.exclude" -czf "$OUTPUT" *

# 计算文件信息
MD5=$(md5sum "$OUTPUT" | cut -d' ' -f1)
SHA256=$(sha256sum "$OUTPUT" | cut -d' ' -f1 | cut -c1-32)
LENGTH=$(stat -c%s "$OUTPUT")
TIMESTAMP=$(date +%s)

# 读取 .release 文件并转换为 JSON 格式
RELEASE_JSON=""
while IFS='=' read -r key value; do
    # 跳过空行
    [[ -z "$key" ]] && continue
    # 去除首尾空格
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    # 添加到 JSON
    RELEASE_JSON+="\"$key\":\"$value\","
done < Release
RELEASE_JSON=${RELEASE_JSON%,}  # 移除最后一个逗号

# 创建压缩的 JSON 文件
if [ -n "$RELEASE_JSON" ]; then
    echo -n "{$RELEASE_JSON,\"md5\":\"$MD5\",\"sha256\":\"$SHA256\",\"length\":$LENGTH,\"timestamp\":$TIMESTAMP}" > "$JSON_FILE"
else
    echo -n "{\"md5\":\"$MD5\",\"sha256\":\"$SHA256\",\"length\":$LENGTH,\"timestamp\":$TIMESTAMP}" > "$JSON_FILE"
fi

# 压缩 JSON 并去除 gzip 头部
perl -e '
use IO::Compress::Gzip qw(gzip $GzipError);
my $gz = new IO::Compress::Gzip $ARGV[1],
    Level       => 9,
    Time        => 0x594b9b6f,
    OS_Code     => 3
    or die "gzip failed: $GzipError\n";
open(my $in, "<", $ARGV[0]) or die "Cannot open $ARGV[0]: $!";
while(<$in>) { print $gz $_; }
close $in;
close $gz;
' "$JSON_FILE" "$TEMP_GZ"
HEADER_LENGTH=$(( $(stat -c%s "$TEMP_GZ") - 10 ))

# 创建最终文件
# 写入长度（4字节，大端序）
perl -e "print pack('N', $HEADER_LENGTH)" > "$FINAL_OUTPUT"
# 写入压缩的 JSON（去除前10字节）
tail -c +11 "$TEMP_GZ" >> "$FINAL_OUTPUT"
# 写入固件内容
cat "$OUTPUT" >> "$FINAL_OUTPUT"

# 清理临时文件
rm -f "$TEMP_GZ" "$JSON_FILE" "$OUTPUT"

echo "构建完成！"
echo "最终文件: $FINAL_OUTPUT"