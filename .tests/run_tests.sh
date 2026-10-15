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
# 说明: 老写法是 (pattern, 忽略, desc) 三个参数, 于是两参数调用时描述会打印成空 —— 现在兼容两种
assert_shim()      { local d="${3:-$2}"; grep -qF -- "$1" "$SHIM_LOG" 2>/dev/null && ok "$d" || bad "$d"; }
assert_not_shim()  { local d="${3:-$2}"; grep -qF -- "$1" "$SHIM_LOG" 2>/dev/null && bad "$d" || ok "$d"; }

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

section "4c. 被改写的固件脚本必须仍然语法正确"
# 真机踩过: 把 if 块里**唯一**的命令注释掉 -> bash/dash 判"then 子句为空", 整份脚本语法错误,
# monitor_process.sh 曾因此完全没跑起来(官方进程守护失效)。所以注释时一律留一条 no-op:
# `: # [ikblock] 原命令`, 而不是光加 `#`。这里对所有会被改写的固件脚本做语法检查。
for f in "$MOCK/usr/ikuai/script/rc" \
         "$MOCK/usr/ikuai/script/upgrade.sh" \
         "$MOCK/usr/ikuai/script/dingtalk.sh" \
         "$MOCK/usr/ikuai/script/catcherd.sh" \
         "$MOCK/usr/ikuai/script/ikaudit_update.sh" \
         "$MOCK/usr/ikuai/script/utils/monitor_process.sh" \
         "$MOCK/usr/ikuai/script/utils/collection.sh" \
         "$MOCK/usr/ikuai/script/utils/update_hosts.sh" \
         "$MOCK/usr/DTalkInside/monidtalk.sh"; do
    [ -f "$f" ] || continue
    if bash -n "$f" 2>/dev/null; then
        ok "$(basename "$f"): 改写后语法正确"
    else
        bad "$(basename "$f"): 改写后语法错误(往 if 里塞注释却没留 no-op?)"
    fi
done

# 后门进程被永久禁掉之后, 官方守护里紧随其后的"重启成功"日志行也必须一起禁:
# monitor_process.sh 是 30 秒一轮的守护, 那两条 Syslog 每轮都会打 —— 真机表现就是
# 日志中心→系统日志 每分钟多出 "进程监听: remote / route_collect 云平台远控服务重新启动"
MP="$MOCK/usr/ikuai/script/utils/monitor_process.sh"
assert_grep     "$MP" ": # \[ikblock\] Syslog \$(Iecho i18n_sys_event_ik_remote_ikuai)"  "monitor: remote 重启日志行已禁(不再每 30 秒刷屏)"
assert_grep     "$MP" ": # \[ikblock\] Syslog \$(Iecho i18n_sys_event_ik_route_collect)" "monitor: route_collect 重启日志行已禁"
assert_not_grep "$MP" "^[[:space:]]*Syslog \$(Iecho i18n_sys_event_ik_"                    "monitor: 没有残留的未禁用后门日志行"
# 官方*自身*组件的守护日志一行都不许动(它们是正常功能)
assert_not_grep "$MP" "ikblock\] Syslog \$(Iecho i18n_sys_event_ik_dhcp"                  "monitor: 官方组件(如 dhcp)的守护日志未被误改"

section "5. 域名封锁(/etc/hosts, 不碰防火墙)"
assert_not_shim "ipset"                                      "不碰 ipset(旧版网络层已删)"
assert_not_shim "iptables"                                   "不碰 iptables(旧版网络层已删)"
# 不再做域名解析: 旧版每 10 分钟对 24 个云端域名各起一次 nslookup(单轮 60~120s, 长于
# 60s 的 cron 周期, 叠加节流竞态 -> 2~6 个守卫并发), 是 30%~65% CPU 尖峰的根因
assert_not_shim "nslookup"                                   "引导期间不做域名解析(不做 nslookup)"
assert_grep     "$MOCK/etc/hosts" "0.0.0.0 302.ikuai8.com"   "hosts 屏蔽云端域名"
assert_grep     "$MOCK/etc/hosts" "0.0.0.0 update.ikuai8.com" "hosts 含 ctrlclient 的 update.ikuai8.com(真机核实补入)"
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
# rc-pid 快通道: bd_apply 补丁时记下"本次开机 rc 的 pid"; 真机上 rc 这个进程常常在本脚本
# 读到它之前就已退出回收, 只靠 cmdline/祖先链判不出来 —— 对上 pid 就直接当开机竞态放行
: > "$STUBLOG"
mkdir -p "$MOCK/tmp"
printf '%s\n' "$$" > "$MOCK/tmp/.ikblock.rc.pid"
"$MOCK/usr/sbin/pmd" >/dev/null 2>&1
assert_not_grep "$STUBLOG" "pmd 被启动(已拦截) ppid=$$"       "拉起者 pid == 记录的 rc pid -> 判为开机竞态(不记录)"
rm -f "$MOCK/tmp/.ikblock.rc.pid"

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

# 另一半: rc 的 `boot_load_async X &` 会先 fork 一个后台子 shell 再 exec, 中间子 shell 常常
# 在本脚本起来前/后就退出(cmdline 读不出来) —— 真机上靠"起床时先用内建 read 抓住的父进程
# stat"顺着祖先链找到 rc 来判定(见 README); 若父进程已被彻底回收($PPID 已经是 1), 归属不了,
# 就必须在日志第二行说明, 而不是伪造一个拉起者
: > "$STUBLOG"
printf 'if [ "$1" = boot2 ]; then ( "%s/usr/sbin/pmd" >/dev/null 2>&1 & exit 0 ); sleep 2; fi\n' "$MOCK" >> "$RC"
bash "$RC" boot2 >/dev/null 2>&1
assert_grep "$STUBLOG" "(拉起者已退出"                       "归属不了时写明"无法归属", 不伪造拉起者"

section "5c. SSH 加固(封禁公网访问 / 一键封禁来源 IP / 官方日志)"
SGBIN="$MOCK/etc/mnt/.boot/bin/sshguard"
SG_LIST="$MOCK/etc/mnt/ikguard/ssh-ban.list"
assert_exists   "$SGBIN"                                     "bin/sshguard 已部署"
assert_grep     "$MOCK/etc/mnt/boot_args" "^sshguard=0"      "sshguard 默认关闭(开了会把 WAN 侧管理通道一起挡掉)"

# ① 一切取官方值: SSH 端口读官方 remote_control.sshd_port(故意设成 2222),
#    公网网卡读官方 /usr/ikuai/include/iptables.sh 的 IPT_WAN_NO_VPN_IFACE_IN
sg_out="$(IK_SYSROOT="$MOCK" bash "$SGBIN" status 2>/dev/null)"
case "$sg_out" in
    *"端口=2222"*)        ok "SSH 端口取官方 sshd_port(2222), 没写死 22" ;;
    *)                    bad "SSH 端口取官方 sshd_port(2222), 没写死 22" ;;
esac
case "$sg_out" in
    *'wan*,vwan*,adsl*'*) ok "公网网卡取官方定义(-m ifaces --ifaces wan*,vwan*,adsl* --dir in)" ;;
    *)                    bad "公网网卡取官方定义(-m ifaces --ifaces wan*,vwan*,adsl* --dir in)" ;;
esac

# ② 默认(开关关 + 无名单): 一个防火墙调用都不发 —— 保持"不开就不花代价"
: > "$SHIM_LOG"; : > "$SHIM_LOG.iptables"; : > "$SHIM_LOG.ip6tables"
run_boot
assert_not_shim "IKG_SSH_WAN"                                "默认关闭时不下发公网封禁规则"
assert_not_shim "IKG_SRC_BAN"                                "没有封禁名单时不建来源封禁链"

# ③ 开启公网封禁: 官方网卡定义 + 官方端口 + 只拦新连接(iKuai 的 INPUT 是默认 ACCEPT,
#    不限 NEW 会把正在操作的管理会话一起打断)
IK_SYSROOT="$MOCK" bash "$SGBIN" on >/dev/null 2>&1
assert_grep "$MOCK/etc/mnt/boot_args" "^sshguard=1"          "开关置 1 并写入 boot_args"
assert_shim "iptables -w -A IKG_SSH_WAN -p tcp -m ifaces --ifaces wan*,vwan*,adsl* --dir in -m conntrack --ctstate NEW --dport 2222 -j DROP" \
                                                             "公网封禁规则(官方网卡 + 官方端口 + 仅新连接)"
assert_shim "iptables -w -I INPUT 1 -j IKG_SSH_WAN"          "封禁链挂到 INPUT 最前"

# ④ 幂等 + 并发: 重复点(以及两个进程同时点)之后, 规则表里 INPUT 只能有一条跳转。
#    实现是"先删净再插一条"+flock 串行化, 所以这里断言**最终状态**, 而不是调用了几次。
n_jump() { grep -c '^R|INPUT|-j IKG_SSH_WAN$' "$SHIM_LOG.iptables" 2>/dev/null; }
IK_SYSROOT="$MOCK" bash "$SGBIN" on >/dev/null 2>&1
case "$(n_jump)" in
    1) ok "重复应用后 INPUT 跳转仍只有一条(幂等)" ;;
    *) bad "重复应用后 INPUT 跳转仍只有一条(幂等)" ;;
esac
# 两个进程同时应用(测试替身自己没锁, 所以并发后可能留下重复 —— 再应用一次必须收敛)
( IK_SYSROOT="$MOCK" bash "$SGBIN" on >/dev/null 2>&1 &
  IK_SYSROOT="$MOCK" bash "$SGBIN" on >/dev/null 2>&1 &
  wait ) 2>/dev/null
IK_SYSROOT="$MOCK" bash "$SGBIN" on >/dev/null 2>&1
case "$(n_jump)" in
    1) ok "并发应用后再次应用能收敛成一条(幂等设计兜住并发)" ;;
    *) bad "并发应用后再次应用能收敛成一条(幂等设计兜住并发)" ;;
esac

# ⑤ 关闭: 撤销干净, 自检同步显示
IK_SYSROOT="$MOCK" bash "$SGBIN" off >/dev/null 2>&1
assert_grep "$MOCK/etc/mnt/boot_args" "^sshguard=0"          "开关置 0"
assert_shim "iptables -w -D INPUT -j IKG_SSH_WAN"             "关闭时摘掉 INPUT 跳转"
assert_shim "iptables -w -X IKG_SSH_WAN"                      "关闭时删掉自建链"
case "$(IK_SYSROOT="$MOCK" bash "$SGBIN" status 2>/dev/null)" in
    *"未封禁"*) ok "自检显示公网未封禁(与规则同步)" ;;
    *)          bad "自检显示公网未封禁(与规则同步)" ;;
esac

# ⑥ 一键封禁来源 IP: 只挡该 IP 访问 SSH 端口(Web 不受影响, 手滑也能从网页解封)
IK_SYSROOT="$MOCK" bash "$SGBIN" ban 203.0.113.9 "SSH 爆破" >/dev/null 2>&1
assert_shim "iptables -w -I IKG_SRC_BAN 1 -s 203.0.113.9 -p tcp --dport 2222 -j DROP" \
                                                             "封禁只挡该 IP 的 SSH 端口"
assert_grep "$SG_LIST" '^203.0.113.9|'                        "封禁名单落到持久盘"
# 同一 IP 再封一次: 名单与规则都不许长出第二份
IK_SYSROOT="$MOCK" bash "$SGBIN" ban 203.0.113.9 "再封一次" >/dev/null 2>&1
case "$(grep -c '^203.0.113.9|' "$SG_LIST")" in
    1) ok "同一 IP 重复封禁不写重复名单行" ;;
    *) bad "同一 IP 重复封禁不写重复名单行" ;;
esac
case "$(grep -c '^R|IKG_SRC_BAN|-s 203.0.113.9 ' "$SHIM_LOG.iptables")" in
    1) ok "同一 IP 重复封禁只有一条 DROP 规则" ;;
    *) bad "同一 IP 重复封禁只有一条 DROP 规则" ;;
esac

# ⑦ 重启后名单要重放(用户点了封禁就该一直有效), 而开关关着时公网封禁不会自己回来
: > "$SHIM_LOG"; : > "$SHIM_LOG.iptables"; : > "$SHIM_LOG.ip6tables"
run_boot
assert_shim "iptables -w -I IKG_SRC_BAN 1 -s 203.0.113.9"    "重启后自动重放封禁名单"
assert_not_shim "IKG_SSH_WAN"                                "开关关着时公网封禁不会自己回来"

# ⑦b 真机抓到的场景: 曾经开过 sshguard(有 on 标记)但一个 IP 都没封 —— 开机重放不许留下空链
: > "$MOCK/etc/mnt/ikguard/sshguard.on"
IK_SYSROOT="$MOCK" bash "$SGBIN" on >/dev/null 2>&1
rm -f "$SG_LIST"
: > "$SHIM_LOG"; rm -f "$SHIM_LOG.iptables"     # 只看"接着 07 会不会自己建链"
IK_SYSROOT="$MOCK" bash "$MOCK/etc/mnt/.boot/scripts/07_enable_sshguard.sh" >/dev/null 2>&1
assert_not_shim "IKG_SRC_BAN"                                "名单为空时开机重放不建空链(真机踩过)"
# 给 ⑧ 备好现场: 重新封一个 IP(链 + 跳转 + 规则 + 名单), 然后关掉公网封禁
IK_SYSROOT="$MOCK" bash "$SGBIN" ban 203.0.113.9 调试 >/dev/null 2>&1
IK_SYSROOT="$MOCK" bash "$SGBIN" off >/dev/null 2>&1

# ⑧ 解封: 名单空了就要把链也拆掉(不留挂着的空链)
IK_SYSROOT="$MOCK" bash "$SGBIN" unban 203.0.113.9 >/dev/null 2>&1
assert_shim "iptables -w -D IKG_SRC_BAN -s 203.0.113.9"      "解封时删掉规则"
assert_not_grep "$SG_LIST" '^203.0.113.9|'                    "解封后名单里不留"
assert_shim "iptables -w -D INPUT -j IKG_SRC_BAN"             "名单空了就摘掉 INPUT 跳转(不留空链)"
assert_shim "iptables -w -X IKG_SRC_BAN"                      "名单空了就删掉链"

# ⑧b 清空名单同理
IK_SYSROOT="$MOCK" bash "$SGBIN" ban 198.51.100.7 >/dev/null 2>&1
: > "$SHIM_LOG"
IK_SYSROOT="$MOCK" bash "$SGBIN" clear >/dev/null 2>&1
assert_shim "iptables -w -X IKG_SRC_BAN"                      "清空名单后不留空链"
assert_not_grep "$SG_LIST" '198.51.100.7'                     "清空后名单为空"

# ⑨ 参数只收 IP 字面量(防把 shell 元字符带进 iptables 命令行)
if IK_SYSROOT="$MOCK" bash "$SGBIN" ban '1.2.3.4;reboot' >/dev/null 2>&1; then
    bad "非法 IP 被拒绝(防注入)"
else
    ok  "非法 IP 被拒绝(防注入)"
fi

# ⑩ SSH 登录日志: 直接读官方 syslog.db 的 messages 表(dropbear), 成功/失败/注销都要有
IK_SYSROOT="$MOCK" bash "$SGBIN" log 20 > "$MOCK/tmp/.sshlog" 2>/dev/null
assert_grep     "$MOCK/tmp/.sshlog" "登录成功(密码)"          "SSH 日志: 登录成功"
assert_grep     "$MOCK/tmp/.sshlog" "登录失败(口令错误)"      "SSH 日志: 失败尝试(dropbear 的 Bad password attempt)"
assert_grep     "$MOCK/tmp/.sshlog" "注销断开"                "SSH 日志: 注销"
assert_grep     "$MOCK/tmp/.sshlog" "203.0.113.9"             "SSH 日志: 解析出来源 IP(去掉端口)"
assert_not_grep "$MOCK/tmp/.sshlog" "与 SSH 无关"             "SSH 日志: 不掺入非 dropbear 的系统日志"

# 取值函数只能吐一个值: grep -c 无匹配时自己已经打印 0(退出码 1), 再 `|| printf 0` 就是 "0\n0"
v="$(IK_SYSROOT="$MOCK" bash -c '. "'"$MOCK"'/etc/mnt/.boot/lib/common.sh"; . "'"$MOCK"'/etc/mnt/.boot/lib/audit.sh"; au_count /nonexistent-file ""' 2>/dev/null)"
case "$v" in
    0) ok "au_count 无匹配时只输出一个 0(不是 \"0\n0\")" ;;
    *) bad "au_count 无匹配时只输出一个 0(实际: $(printf '%s' "$v" | tr '\n' '/'))" ;;
esac

# 启动尝试要按"本次开机增量"判定: stub.log 在持久盘上带历史记录, 不该让自检永远报红
printf '[2026-01-01 00:00:00] [ikblock] pmd 被启动(已拦截) ppid=1\n(历史记录)\n' >> "$STUBLOG"
run_boot                                  # 开机时记下基线(=1 条历史)
v="$(IK_SYSROOT="$MOCK" bash -c '. "'"$MOCK"'/etc/mnt/.boot/lib/common.sh"; . "'"$MOCK"'/etc/mnt/.boot/lib/backdoor.sh"; bd_stub_new' 2>/dev/null)"
case "$v" in
    0) ok "历史记录不算本次开机(增量 0)" ;;
    *) bad "历史记录不算本次开机(实际增量: $v)" ;;
esac
printf '[2026-01-01 00:01:00] [ikblock] cre 被启动(已拦截) ppid=1\n(本次新增)\n' >> "$STUBLOG"
v="$(IK_SYSROOT="$MOCK" bash -c '. "'"$MOCK"'/etc/mnt/.boot/lib/common.sh"; . "'"$MOCK"'/etc/mnt/.boot/lib/backdoor.sh"; bd_stub_new' 2>/dev/null)"
case "$v" in
    1) ok "本次开机新增能被数出来(增量 1)" ;;
    *) bad "本次开机新增能被数出来(实际: $v)" ;;
esac

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
