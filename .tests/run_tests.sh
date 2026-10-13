#!/bin/bash
#
# 离线测试: 在模拟系统根目录上运行框架，验证
#   1) 后门/更新通道被正确阻断(进程/文件/网络三层)
#   2) 插件系统可用(zip 安装 / 签名校验 / 开机重铺)
#
# 全程不接触真实设备; 在 Linux 或 Git-Bash 下执行: bash .tests/run_tests.sh

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
MOCK="$TESTS_DIR/.mock"
BUILD="$TESTS_DIR/.build"
export SHIM_LOG="$TESTS_DIR/.shim.log"
export PATH="$TESTS_DIR/shims:$PATH"

chmod +x "$TESTS_DIR"/shims/* 2>/dev/null
: > "$SHIM_LOG"

PASS=0
FAIL=0
section() { echo; echo "== $* =="; }
ok()  { PASS=$((PASS + 1)); echo "  [PASS] $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $*"; }

assert_grep()      { grep -q -- "$2" "$1" 2>/dev/null && ok "$3" || bad "$3"; }
assert_not_grep()  { grep -q -- "$2" "$1" 2>/dev/null && bad "$3" || ok "$3"; }
assert_exists()    { [ -e "$1" ] && ok "$2" || bad "$2"; }
assert_noexist()   { [ -e "$1" ] && bad "$2" || ok "$2"; }
assert_notlink()   { [ -L "$1" ] && bad "$2" || ok "$2"; }
assert_shim()      { grep -qF -- "$2" "$SHIM_LOG" 2>/dev/null && ok "$3" || bad "$3"; }

run_boot() {
    IK_SYSROOT="$MOCK" bash "$MOCK/etc/mnt/.boot/install.sh" >/dev/null 2>&1
}

# ------------------------------------------------------------------ 准备
section "0. 生成模拟根目录并部署框架"
bash "$TESTS_DIR/mock_root.sh" "$MOCK" >/dev/null || { echo "生成失败"; exit 1; }
( cd "$REPO_DIR" && IK_SYSROOT="$MOCK" bash install.sh >/dev/null ) || { echo "部署失败"; exit 1; }
assert_exists "$MOCK/etc/mnt/.boot/install.sh" "boot.sh 已部署为 .boot/install.sh"
assert_exists "$MOCK/etc/mnt/boot_args" "boot_args 已初始化"
assert_grep "$MOCK/etc/mnt/boot_args" "^backdoor=1" "backdoor 开关默认开启"
assert_grep "$MOCK/etc/mnt/boot_args" "^backdoor_hosts=0" "hosts 屏蔽默认关闭"

section "1. 执行开机引导(模拟官方 plugins.sh 调用)"
# 打开 hosts 屏蔽以便覆盖该分支(真机默认关闭)
sed -i 's/^backdoor_hosts=.*/backdoor_hosts=1/' "$MOCK/etc/mnt/boot_args"
run_boot
assert_exists "$MOCK/var/log/ikuai-boot.log" "产生启动日志"

# ------------------------------------------------------------------ 后门
RC="$MOCK/usr/ikuai/script/rc"
MP="$MOCK/usr/ikuai/script/utils/monitor_process.sh"
COL="$MOCK/usr/ikuai/script/utils/collection.sh"

section "2. 文件层: rc 启动项改写"
assert_grep     "$RC" "# \[ikblock\] ik_rc_client"        "rc: 注释 ik_rc_client"
assert_grep     "$RC" "# \[ikblock\] pmd"                 "rc: 注释 pmd"
assert_grep     "$RC" "# \[ikblock\] cre_client start"    "rc: 注释 cre_client start"
assert_grep     "$RC" "# \[ikblock\] cre"                 "rc: 注释 cre(采集上报)"
assert_grep     "$RC" "# \[ikblock\] utils/submit.lua"    "rc: 不启动 submit.lua(云端指令通道)"
assert_grep     "$RC" "# \[ikblock\] utils/update_hosts"  "rc: 不启动 update_hosts.sh(云端取址)"
assert_grep     "$RC" "boot_load_sync   plugins.sh"       "rc: 保留 plugins.sh 钩子(框架入口)"
assert_not_grep "$RC" "^[[:space:]]*ik_rc_client[[:space:]]*$" "rc: 无残留 ik_rc_client 启动行"

section "3. 文件层: 进程守护与服务脚本"
assert_grep     "$MP" "# \[ikblock\] cgroup_exec pmd"          "monitor: 不再拉起 pmd"
assert_grep     "$MP" "# \[ikblock\] cgroup_exec ik_rc_client" "monitor: 不再拉起 ik_rc_client"
assert_grep     "$MP" "# \[ikblock\] cgroup_exec cre"          "monitor: 不再拉起 cre"
assert_grep     "$MP" "# \[ikblock\] cgroup_exec cre_client"   "monitor: 不再拉起 cre_client"
assert_grep     "$MP" "openresty"                              "monitor: 保留 openresty 守护(不影响功能)"
assert_grep     "$COL" "# \[ikblock\]"                         "collection: 注入跳过标记"
assert_grep     "$COL" "netstat -atnp"                         "collection: 原判断行仍在(仅提前return)"
assert_grep     "$MOCK/usr/ikuai/script/dingtalk.sh" "# \[ikblock\] monidtalk" "dingtalk: 不启动 monidtalk"
assert_grep     "$MOCK/usr/DTalkInside/monidtalk.sh" "exit 0"  "monidtalk: 已停用(dtalkd不再被守护)"
assert_grep     "$MOCK/usr/ikuai/script/catcherd.sh" "exit 0"  "catcherd: 已停用(抓包上报)"
assert_grep     "$MOCK/usr/ikuai/script/utils/update_hosts.sh" "exit 0" "update_hosts: 已停用"
assert_grep     "$MOCK/usr/ikuai/script/utils/submit.lua" "-- \[ikblock\]" "submit.lua: 已禁用云端指令(Lua 注释)"
assert_grep     "$MOCK/usr/ikuai/script/utils/submit.lua" "do return M end"     "submit.lua: boot 立即返回(Lua 合法语句)"
assert_not_grep "$MOCK/usr/ikuai/script/utils/submit.lua" "^\s*#"              "submit.lua: 未写入 shell 注释"
assert_grep     "$MOCK/usr/ikuai/script/upgrade.sh" "update_auto_disabled"      "upgrade.sh: 云端自动升级动作已改名禁用"
assert_grep     "$MOCK/usr/ikuai/script/upgrade.sh" "# \[ikblock\]"            "upgrade.sh: 已标记"

section "4. 进程层: 空壳替换与软链接清理"
assert_grep     "$MOCK/usr/sbin/ik_rc_client" "ikblock"      "ik_rc_client 已换成空壳"
assert_not_grep "$MOCK/usr/sbin/ik_rc_client" "real ik_rc_client" "ik_rc_client 原程序已移除"
assert_grep     "$MOCK/usr/sbin/cre" "ikblock"               "cre 已换成空壳"
assert_notlink  "$MOCK/usr/sbin/cre"                          "cre 软链接已断开"
assert_grep     "$MOCK/usr/sbin/pmd" "ikblock"               "pmd 已换成空壳"
assert_grep     "$MOCK/tmp/ikpkg/cre/cre" "ikblock"          "运行时包 cre 也被中和"
assert_noexist  "$MOCK/etc/cre.d/cre_host"                   "云端地址表 cre_host 已删除"
assert_noexist  "$MOCK/etc/pmd.d/pmd_host"                   "云端地址表 pmd_host 已删除"
assert_shim     "killall" "ik_rc_client"                     "尝试杀灭 ik_rc_client"

section "5. 网络层: 出口封锁"
assert_shim     "ipset create ikuai_blk" "ipset"             "创建封锁集合 ikuai_blk"
assert_shim     "iptables -I OUTPUT 1 -m set" "iptables"     "OUTPUT 按集合 DROP"
assert_shim     "iptables -I FORWARD 1 -m set" "iptables"    "FORWARD 按集合 DROP"
assert_shim     "multiport --dports" "iptables"              "云端专用端口 DROP"
assert_shim     "59.110.6.135/32" "ipset"                    "已加入已知云端 IP"
assert_shim     "203.0.113.10" "ipset"                       "域名解析结果已加入集合"
assert_grep     "$MOCK/etc/hosts" "0.0.0.0 302.ikuai8.com"   "hosts 屏蔽云端域名"

section "6. 持久化守卫(cron 每分钟复查)"
assert_exists  "$MOCK/etc/crontabs/cron.d/ikblock_guard"     "守卫 cron 已安装"
assert_grep    "$MOCK/etc/crontabs/cron.d/ikblock_guard" "backdoor_guard" "守卫指向 backdoor_guard"

section "7. 复查动作(guard)可用"
IK_SYSROOT="$MOCK" bash "$MOCK/etc/mnt/.boot/bin/backdoor_guard" >/dev/null 2>&1
ok "backdoor_guard 执行成功(退出码 0)"

# ------------------------------------------------------------------ 插件
section "8. 插件系统: 打包/签名/校验"
rm -rf "$BUILD"
mkdir -p "$BUILD/hello/bin"
printf 'plugin=hello\nversion=1.0\n'  > "$BUILD/hello/Release"
printf '#!/bin/bash\necho x >> "$IK_SYSROOT/etc/mnt/hello.installed"\n' > "$BUILD/hello/install.sh"
printf '#!/bin/sh\necho hello\n'      > "$BUILD/hello/bin/hello.sh"
chmod +x "$BUILD/hello/install.sh" "$BUILD/hello/bin/hello.sh"

IK_SYSROOT="$MOCK" bash "$MOCK/etc/mnt/.boot/bin/ikplugin" keygen >/dev/null 2>&1
assert_exists "$MOCK/etc/mnt/plugins/plugin.key" "生成签名私钥"
assert_exists "$MOCK/etc/mnt/plugins/plugin.pub" "生成校验公钥"
cp -f "$MOCK/etc/mnt/plugins/plugin.pub" "$MOCK/etc/mnt/.boot/plugin.pub"

IK_SYSROOT="$MOCK" bash "$MOCK/etc/mnt/.boot/bin/ikplugin" pack "$BUILD/hello" "$BUILD/hello.zip" >/dev/null 2>&1
assert_exists "$BUILD/hello/MANIFEST.MF" "生成 MANIFEST.MF"
assert_exists "$BUILD/hello/SIGNATURE.RSA" "生成 SIGNATURE.RSA"
assert_exists "$BUILD/hello.zip" "生成插件 zip 包"

if IK_SYSROOT="$MOCK" bash "$MOCK/etc/mnt/.boot/bin/ikplugin" verify "$BUILD/hello" >/dev/null 2>&1; then
    ok "签名包校验通过"
else
    bad "签名包校验通过"
fi

section "9. 插件系统: zip 安装 -> 开机重铺"
mkdir -p "$MOCK/etc/mnt/plugins"
cp -f "$BUILD/hello.zip" "$MOCK/etc/mnt/plugins/"
IK_SYSROOT="$MOCK" bash "$MOCK/etc/mnt/.boot/bin/ikplugin" scan >/dev/null 2>&1
assert_exists "$MOCK/etc/mnt/plugins/hello/Release"        "插件已解压安装"
assert_exists "$MOCK/etc/mnt/hello.installed"              "插件 install.sh 已执行"
assert_exists "$MOCK/usr/sbin/hello"                       "插件 bin 已链接到 /usr/sbin"
assert_exists "$MOCK/etc/mnt/plugins/.installed/hello.zip" "安装后 zip 已归档"

run_boot
n=$(wc -l < "$MOCK/etc/mnt/hello.installed" 2>/dev/null || echo 0)
if [ "${n:-0}" -ge 2 ]; then
    ok "重启(再次引导)后插件被重新铺开"
else
    bad "重启(再次引导)后插件被重新铺开 (执行次数=$n)"
fi

section "10. 插件系统: 篡改检测"
rm -rf "$BUILD/tampered"
cp -r "$BUILD/hello" "$BUILD/tampered"
echo "tampered" >> "$BUILD/tampered/install.sh"
if IK_SYSROOT="$MOCK" bash "$MOCK/etc/mnt/.boot/bin/ikplugin" verify "$BUILD/tampered" >/dev/null 2>&1; then
    bad "篡改后应校验失败"
else
    ok "篡改后校验失败(摘要不匹配)"
fi

# ------------------------------------------------------------------ 汇总
echo
echo "=================================================="
echo " 通过: $PASS   失败: $FAIL"
echo "=================================================="
[ "$FAIL" -eq 0 ] || exit 1
