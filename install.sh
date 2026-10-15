#!/bin/bash

# 部署脚本: 把本仓库铺到 /etc/mnt/.boot/，并初始化开关文件 /etc/mnt/boot_args
# 说明: boot.sh 会被改名为 .boot/install.sh，以便官方 plugins.sh 调用

IK_SYSROOT="${IK_SYSROOT:-}"
BOOT_PATH="${IK_SYSROOT}/etc/mnt/.boot"
BOOT_ARGS="${IK_SYSROOT}/etc/mnt/boot_args"

# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 清理并创建目标目录
rm -rf "$BOOT_PATH"
mkdir -p "$BOOT_PATH"

# 复制所有文件，排除自身和特定文件
cd "$SCRIPT_DIR" || exit 1
find . -mindepth 1 -maxdepth 1 \
    ! -name "$(basename "${BASH_SOURCE[0]}")" \
    ! -name ".*" \
    -print0 | while IFS= read -r -d '' file; do
    if [ "$(basename "$file")" = "boot.sh" ]; then
        # 特殊处理boot.sh
        cp -p "$file" "$BOOT_PATH/install.sh"
        chmod +x "$BOOT_PATH/install.sh"
    else
        # 复制其他文件和目录
        cp -r "$file" "$BOOT_PATH/"
    fi
done

# 补齐可执行位(Windows/zip 拷贝后容易丢失)
find "$BOOT_PATH/scripts" "$BOOT_PATH/bin" "$BOOT_PATH/usr/ikuai/function" -type f 2>/dev/null | \
while IFS= read -r f; do
    chmod +x "$f" 2>/dev/null
done
chmod +x "$BOOT_PATH/install.sh" 2>/dev/null

# Web 插件资源需要可读
find "$BOOT_PATH/www" -type f 2>/dev/null | while IFS= read -r f; do
    chmod 644 "$f" 2>/dev/null
done

# 初始化配置(已存在则只补齐缺失项)
test -f "$BOOT_ARGS" || {
    mkdir -p "$(dirname "$BOOT_ARGS")"
    : > "$BOOT_ARGS"
}

ensure_key() {
    grep -q "^$1=" "$BOOT_ARGS" || echo "$1=$2" >> "$BOOT_ARGS"
}

ensure_key sshd 1
ensure_key backdoor 1
ensure_key plugins 1
ensure_key cron 1
ensure_key shell 1
ensure_key audit 0    # 审计取证=被动采集器(默认关闭; 开启后运行常驻进程, 不占 cron)
ensure_key sshguard 0 # SSH 加固=封禁公网访问 SSH(默认关闭: 打开后从 WAN 侧的新 SSH 连接
                      # 一律被丢, 只剩 LAN 侧可用 —— 别把自己锁在门外, 需要时在 Web 上一键开)

# 清理已废弃开关:
#   remote         历史遗留的空开关(没有任何脚本读取; iKuai 云平台的"远程控制/远程维护"
#                  已由后门阻断层覆盖: ik_rc_client 空壳 + monitor_process 不再守护 + hosts 封域名)
#   plugins_verify 插件强校验(插件包不再要求签名)
#   backdoor_hosts 域名封锁已并入 backdoor(不再单独开关)
#   probe          云端连通性自检已移除(封锁不走 iptables, 旧的 DNS+TCP 探测已无意义)
sed -i '/^remote=/d;/^plugins_verify=/d;/^backdoor_hosts=/d;/^probe=/d' "$BOOT_ARGS" 2>/dev/null

echo "已部署到 $BOOT_PATH"
echo "开关文件: $BOOT_ARGS"
cat "$BOOT_ARGS"
