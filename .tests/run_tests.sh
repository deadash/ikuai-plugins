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
assert_shim()      { grep -qF -- "$1" "$SHIM_LOG" 2>/dev/null && ok "$3" || bad "$3"; }
assert_not_shim()  { grep -qF -- "$1" "$SHIM_LOG" 2>/dev/null && bad "$2" || ok "$2"; }

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
assert_not_grep "$MOCK/etc/mnt/boot_args" "backdoor_hosts" "域名封锁已并入 backdoor(无独立开关)"

section "1. 执行开机引导(模拟官方 plugins.sh 调用)"
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

section "4. 进程层: 空壳替换(空壳=启动监控)"
assert_grep     "$MOCK/usr/sbin/ik_rc_client" "ikblock"      "ik_rc_client 已换成空壳"
assert_not_grep "$MOCK/usr/sbin/ik_rc_client" "real ik_rc_client" "ik_rc_client 原程序已移除"
assert_grep     "$MOCK/usr/sbin/cre" "ikblock"               "cre 已换成空壳"
assert_grep     "$MOCK/usr/sbin/pmd" "ikblock"               "pmd 已换成空壳"
assert_grep     "$MOCK/usr/sbin/dtalkd" "ikblock"            "dtalkd 已换成空壳"
assert_grep     "$MOCK/usr/sbin/dtalkc" "ikblock"            "dtalkc 已换成空壳"
assert_grep     "$MOCK/usr/sbin/cre" "stub.log"              "空壳带启动监控(记录到 stub.log)"
assert_grep     "$MOCK/usr/DTalkInside/monidtalk.sh" "stub.log" "被禁脚本同样记录启动尝试"
assert_shim     "killall" "ik_rc_client"                     "尝试杀灭 ik_rc_client"

section "4b. 云端审计组件下载器(ikaudit_update.sh)"
assert_grep     "$MOCK/usr/ikuai/script/ikaudit_update.sh" "exit 0" "ikaudit_update.sh 已禁用(启动即退)"
assert_grep     "$MOCK/usr/ikuai/script/utils/monitor_process.sh" "# \[ikblock\] start-stop-daemon ikaudit_update.sh" "monitor: 不再拉起 ikaudit_update.sh"

section "5. 域名封锁(/etc/hosts, 不碰防火墙)"
assert_not_shim "ipset"                                      "不碰 ipset(旧版网络层已删)"
assert_not_shim "iptables"                                   "不碰 iptables(旧版网络层已删)"
# 不再做域名解析: 旧版每 10 分钟对 24 个云端域名各起一次 nslookup(单轮 60~120s, 长于
# 60s 的 cron 周期, 叠加节流竞态 -> 2~6 个守卫并发), 是 30%~65% CPU 尖峰的根因
assert_not_shim "nslookup"                                   "引导期间不做域名解析(不做 nslookup)"
assert_grep     "$MOCK/etc/hosts" "0.0.0.0 302.ikuai8.com"   "hosts 屏蔽云端域名"
assert_exists   "$MOCK/etc/hosts.d/ikblock"                  "封锁写成 /etc/hosts.d 片段(与固件同源)"
assert_grep     "$MOCK/etc/hosts.d/ikblock" "\[ikblock\]"    "片段带标记(可追溯来源)"
# 真机 basic.sh:__set_hostname()(开机必经)/ function basic(网页改主机名)/ pppoe_server.sh
# 都会 `cat /etc/hosts.d/* > /etc/hosts` —— 直接追加会被冲掉, 片段必须活下来
cat "$MOCK/etc/hosts.d"/* > "$MOCK/etc/hosts"
assert_grep     "$MOCK/etc/hosts" "0.0.0.0 302.ikuai8.com"   "hosts 被重建后封锁仍在"

section "5b. 启动尝试监控(空壳 / 被禁脚本)"
STUBLOG="$MOCK/etc/log/ikguard/stub.log"
# 生成进空壳/被禁脚本里的记录代码必须是语法正确的:
# 真机首测就是 awk -v 转义把 printf 格式串里的 \n 变成真换行 -> 整脚本解析失败 -> 连启动尝试都记不下来
for f in "$MOCK/usr/sbin/ik_rc_client" "$MOCK/usr/ikuai/script/utils/update_hosts.sh" \
         "$MOCK/usr/ikuai/script/ikaudit_update.sh" "$MOCK/usr/DTalkInside/monidtalk.sh"; do
    if bash -n "$f" 2>/dev/null; then
        ok "$(basename "$f"): 拦截脚本语法正确"
    else
        bad "$(basename "$f"): 拦截脚本语法错误"
    fi
done

# 未知拉起者: 必须记一笔(否则"空壳即监控"形同虚设)
: > "$STUBLOG"
"$MOCK/usr/sbin/pmd" >/dev/null 2>&1
assert_grep "$STUBLOG" "pmd 被启动(已拦截)"                  "未知拉起者启动空壳 -> 记录启动尝试"
assert_grep "$STUBLOG" "run_tests.sh"                        "记录里带上拉起者 cmdline"
# 被禁脚本: 真机上由 /etc/ikcommon `source` 起来(顶层代码先跑), 这里等价地用 bash 起一次
bash "$MOCK/usr/ikuai/script/utils/update_hosts.sh" >/dev/null 2>&1
assert_grep "$STUBLOG" "update_hosts.sh 被启动(已禁用拦截)"  "被禁脚本被启动 -> 记录启动尝试"
# 被禁脚本必须真的不干活: 原脚本体内的断言行不能被执行到
assert_grep "$MOCK/usr/ikuai/script/utils/update_hosts.sh" "get_hosts" "被禁脚本原文保留(便于比对)"
# 开机竞态: rc 的函数体在补丁前已被 bash 解析进内存, 每次开机 rc 还会按旧内容拉起一遍
# (磁盘上的 rc 已带补丁) —— 这是预期内的, 不该污染"启动尝试"日志
: > "$STUBLOG"
printf 'if [ "$1" = boot ]; then "%s/usr/sbin/pmd"; exit 0; fi\n' "$MOCK" >> "$RC"
bash "$RC" boot >/dev/null 2>&1
assert_not_grep "$STUBLOG" "被启动"                          "rc 内存旧副本的启动不记为异常(判据: 磁盘 rc 已带补丁)"

section "6. 定时任务: 不装守卫, 且清掉旧版遗留"
assert_noexist  "$MOCK/etc/crontabs/cron.d/ikblock_guard"    "未安装每分钟守卫 cron"
assert_not_grep "$MOCK/etc/crontabs/root" "backdoor_guard"   "旧版守卫行已从 crontab 清除"
assert_not_grep "$MOCK/etc/crontabs/root" "ikaudit probe"    "旧版自检 cron 行已清除"
assert_grep     "$MOCK/etc/crontabs/root" "iktimer"          "iKuai 自带的 cron 行未被误删"

# 边界: crontab 里只剩守卫一行时也要清干净(不能"怕清空"而留下)
printf '* * * * * /etc/mnt/.boot/bin/backdoor_guard\n' > "$MOCK/etc/crontabs/root"
run_boot
assert_not_grep "$MOCK/etc/crontabs/root" "backdoor_guard"   "只剩守卫行时也能清掉(边界)"

section "7. 手动重应用入口(backdoor_guard -> bd_apply)"
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
