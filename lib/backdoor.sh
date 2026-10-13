#!/bin/bash
#
# 后门 & 云端更新通道 禁用库
#
# 设计原则:
#   1) 只针对"与爱快云端通信"的进程/通道，不动路由、DHCP、NAT、QoS 等本地功能
#   2) 三重保险: 进程层(不启动+杀灭) + 文件层(改写宿主脚本) + 网络层(出口封锁)
#   3) 幂等: 可重复执行。开机由 plugins 钩子执行一次，另由 cron 每分钟复查
#
# 依赖: 由 common.sh 提供 P()/log()/is_enabled()，调用前需先 source

BD_MARK="ikblock"

# 需要杀灭/禁止的进程名(精确匹配)
BD_PROCS="ik_rc_client cre cre_client pmd dtalkd dtalkc catcherd"

# 需要按命令行关键字杀灭的进程(仅限已被"文件层"改写的云端通道脚本,
# 因为改写只影响新启动的实例, 正在运行的旧实例需要显式杀掉)
BD_KILL_PATTERNS="utils/update_hosts.sh utils/submit.lua \
DTalkInside/monidtalk.sh script/dingtalk.sh script/catcherd.sh"

# 需要被替换成空壳的程序(官方后门/上报客户端)
BD_STUBS="/usr/sbin/ik_rc_client /usr/sbin/cre /usr/sbin/pmd /usr/sbin/dtalkd \
/usr/sbin/dtalkc /usr/bin/cre_client /tmp/ikpkg/cre/cre /tmp/ikpkg/pmd/pmd"

# 需要删除的软链接(云端地址表/运行时包)
BD_LINKS="/etc/cre.d/cre_host /etc/pmd.d/pmd_host /usr/bin/cre_client"

# 需要封锁的云端域名
BD_DOMAINS="302.ikuai8.com download.ikuai8.com pkgmanager.ikuai8.com dpi.ikuai8.com \
audit.ikuai8.com routers.ikuai8.com coll.ikuai8.com dis.ikuai8.com datacollect.ikuai8.com \
ctrl1.ikuai8.com ctrl2.ikuai8.com as1.ikuai8.com as2.ikuai8.com youyu.api.ikuai8.com \
genuine.ikuai8.com iapi.ikuai8.com yun.ikuai8.com portal.ikuai8.com local.ikuai8.com \
2021.ikuai8.com bm.ikuai8.com report.ikuai8.com www.ikuai8.com ikuai8.com"

# 已知云端 IP / 网段(动态解析失败时的兜底)
BD_NETS="59.110.6.135/32 59.110.171.18/32 47.94.237.123/32 123.57.179.21/32 \
123.57.14.224/32 120.55.220.4/32 120.55.220.55/32 121.43.10.93/32 47.114.236.50/32 \
47.98.0.183/32 47.96.32.142/32 59.82.122.79/32 121.199.107.25/32 47.114.208.4/32 \
59.110.6.0/24 59.110.171.0/24"

# 云端专用端口
BD_PORTS="1853 2016 2221 2502 6000 9443 15602 1863 32015 32017 8086 6444 21422"

IPSET_NAME="ikuai_blk"

# 用户扩展文件(可选, 一行一条)
BD_EXT_DOMAINS="/etc/mnt/ikblock.domains"
BD_EXT_NETS="/etc/mnt/ikblock.nets"

BD_RESOLVE_STAMP="/tmp/.ikblock_resolve"

bd_log() { log "[backdoor] $*"; }

# ---------------------------------------------------------------- 进程层

# 按命令行关键字杀灭进程(避开自身/SSH 会话/交互式 shell)
bd_kill_pattern() {
    local pat dir pid cmd
    for pat in $BD_KILL_PATTERNS; do
        for dir in /proc/[0-9]*; do
            pid="${dir#/proc/}"
            case "$pid" in "$$"|"$PPID") continue ;; esac
            cmd="$( { tr '\0' ' ' < "$dir/cmdline"; } 2>/dev/null )"
            [ -n "$cmd" ] || continue
            case "$cmd" in *"$pat"*) ;; *) continue ;; esac
            # 排除 ssh 会话与 shell -c 形式(避免误杀维护命令自身)
            case "$cmd" in *sshd*|*dropbear*) continue ;; esac
            case "$cmd" in *" -c "*) continue ;; esac
            bd_log "kill($pat) pid=$pid cmd=$cmd"
            kill -9 "$pid" 2>/dev/null
        done
    done
    return 0
}

# 杀灭后门进程
bd_kill() {
    local p
    for p in $BD_PROCS; do
        if pidof "$p" >/dev/null 2>&1; then
            bd_log "kill 进程: $p"
            killall -q "$p" 2>/dev/null
            pkill -9 -x "$p" 2>/dev/null
        fi
    done
    bd_kill_pattern
}

# 用空壳替换程序(使其启动后立即退出)
bd_stub() {
    local f path
    for f in $BD_STUBS; do
        path="$(P "$f")"
        test -e "$path" || continue
        # 已是空壳则跳过
        grep -q "\[$BD_MARK\]" "$path" 2>/dev/null && continue
        rm -f "$path"
        {
            printf '#!/bin/sh\n'
            printf '# [%s] disabled\n' "$BD_MARK"
            printf 'sleep 1\n'
            printf 'exit 0\n'
        } > "$path"
        chmod +x "$path"
        bd_log "空壳替换: $f"
    done
}

# 删除云端地址表软链接
bd_unlink() {
    local f path
    for f in $BD_LINKS; do
        path="$(P "$f")"
        { test -e "$path" || test -L "$path"; } && { rm -f "$path"; bd_log "删除链接: $f"; }
    done
}

# ---------------------------------------------------------------- 文件层

# 带变更统计的 sed
bd_sed() {
    local file="$1" expr="$2" before after
    before=$(grep -c "\[$BD_MARK\]" "$file" 2>/dev/null)
    sed -i "$expr" "$file"
    after=$(grep -c "\[$BD_MARK\]" "$file" 2>/dev/null)
    if [ "$before" = "$after" ]; then
        bd_log "  未命中: $expr"
    else
        bd_log "  已改写(+$((after - before))): $(basename "$file")"
    fi
}

# 让整个脚本在 shebang 之后立即退出
bd_neuter_script() {
    local f="$1" p
    f="$1"; p="$(P "$f")"
    test -f "$p" || return 0
    grep -q "\[$BD_MARK\]" "$p" 2>/dev/null && return 0
    awk -v mark="$BD_MARK" 'NR==1{print; print "# ["mark"] 已禁用"; print "exit 0"; next}{print}' \
        "$p" > "$p.tmp" && mv "$p.tmp" "$p"
    chmod +x "$p"
    bd_log "已禁用脚本: $f"
}

# 在某行之后插入语句(常用于让函数提前返回)
# 用法: bd_insert_after <文件> <行正则> <说明> [语句] [注释前缀]
#   注意: 脚本类型不同注释前缀也不同(shell 用 #, lua 用 --),
#         否则会写出语法错误的文件(如 submit.lua 是 Lua 脚本!)
bd_insert_after() {
    local f="$1" pat="$2" note="$3" stmt="${4:-return}" cpre="${5:-\#}" p mode
    p="$(P "$f")"
    test -f "$p" || return 0
    grep -q "\[$BD_MARK\]" "$p" 2>/dev/null && return 0
    # 保留原权限(upgrade.sh/collection.sh 被 func_api/rc 直接调用, 必须可执行)
    mode="$(ls -l "$p" 2>/dev/null | cut -c2-10)"
    awk -v pat="$pat" -v mark="$BD_MARK" -v note="$note" -v stmt="$stmt" -v cpre="$cpre" '
        { print }
        $0 ~ pat && !done { print "\t" cpre " [" mark "] " note; print "\t" stmt; done=1 }
    ' "$p" > "$p.tmp" && mv "$p.tmp" "$p"
    case "$mode" in *x*) chmod +x "$p" ;; esac
    bd_log "已插入[$stmt]: $f"
}

# rc: 启动项与远程/上报服务
bd_patch_rc() {
    local f="/usr/ikuai/script/rc" p
    p="$(P "$f")"
    test -f "$p" || { bd_log "跳过(不存在): $f"; return 0; }
    grep -q "\[$BD_MARK\]" "$p" && return 0

    # 不再启动: 云端指令通道(submit3) / 云端取址(update_hosts)
    bd_sed "$p" "s|^\([[:space:]]*\)boot_load_async[[:space:]][[:space:]]*utils/submit.lua|\1# [$BD_MARK] utils/submit.lua|"
    bd_sed "$p" "s|^\([[:space:]]*\)boot_load_async[[:space:]][[:space:]]*utils/update_hosts.sh|\1# [$BD_MARK] utils/update_hosts.sh|"

    # start_remote_services(): 远程控制/包管理器/OME 客户端
    bd_sed "$p" "s|^\([[:space:]]*\)ik_rc_client[[:space:]]*\$|\1# [$BD_MARK] ik_rc_client|"
    bd_sed "$p" "s|^\([[:space:]]*\)pmd[[:space:]]*\$|\1# [$BD_MARK] pmd|"
    bd_sed "$p" "s|^\([[:space:]]*\)cre_client[[:space:]][[:space:]]*start|\1# [$BD_MARK] cre_client start|"

    # start_ikuai_services(): 采集上报引擎
    bd_sed "$p" "s|^\([[:space:]]*\)cre[[:space:]]*>/dev/null[[:space:]]*2>&1|\1# [$BD_MARK] cre|"
}

# monitor_process.sh: 进程守护会重新拉起后门
bd_patch_monitor() {
    local f="/usr/ikuai/script/utils/monitor_process.sh" p
    p="$(P "$f")"
    test -f "$p" || { bd_log "跳过(不存在): $f"; return 0; }
    grep -q "\[$BD_MARK\]" "$p" && return 0

    bd_sed "$p" "s|^\([[:space:]]*\)cgroup_exec[[:space:]][[:space:]]*pmd[[:space:]]|\1# [$BD_MARK] cgroup_exec pmd |"
    bd_sed "$p" "s|^\([[:space:]]*\)cgroup_exec[[:space:]][[:space:]]*ik_rc_client[[:space:]]|\1# [$BD_MARK] cgroup_exec ik_rc_client |"
    bd_sed "$p" "s|^\([[:space:]]*\)cgroup_exec[[:space:]][[:space:]]*cre[[:space:]]|\1# [$BD_MARK] cgroup_exec cre |"
    bd_sed "$p" "s|^\([[:space:]]*\)cgroup_exec[[:space:]][[:space:]]*cre_client[[:space:]]|\1# [$BD_MARK] cgroup_exec cre_client |"
}

# collection.sh: 远控连通性判断会误关多线IPv6，必须跳过(否则影响功能)
bd_patch_collection() {
    bd_insert_after "/usr/ikuai/script/utils/collection.sh" \
        "netstat -atnp" "跳过远控连通性判断(否则24h后自关多线IPv6)" "return"
}

# 钉钉/企业微信云管通道
bd_patch_dtalk() {
    local f="/usr/ikuai/script/dingtalk.sh" p
    p="$(P "$f")"
    if test -f "$p" && ! grep -q "\[$BD_MARK\]" "$p"; then
        bd_sed "$p" "s|^\([[:space:]]*\)/usr/DTalkInside/monidtalk.sh[[:space:]][[:space:]]*start|\1# [$BD_MARK] monidtalk|"
    fi
    bd_neuter_script "/usr/DTalkInside/monidtalk.sh"
}

# 抓包上报
bd_patch_catcherd() {
    bd_neuter_script "/usr/ikuai/script/catcherd.sh"
}

# 禁用某个公开动作(func_api 通过函数名分发, 改名即可让云端/外部调用失效,
# 同时保持文件语法完整 —— 不要用"插入 return"的方式, 因为模式可能匹配到函数定义行)
bd_disable_action() {
    local f="$1" name="$2" p
    p="$(P "$f")"
    test -f "$p" || return 0
    grep -q "\[$BD_MARK\]" "$p" 2>/dev/null && return 0
    bd_sed "$p" "s|^${name}()|${name}_disabled() # [$BD_MARK] 已禁用|"
}

# 更新通道: 取址脚本 / submit3 指令通道 / 云端自动升级
bd_patch_updates() {
    bd_neuter_script "/usr/ikuai/script/utils/update_hosts.sh"
    # submit.lua 是 Lua 脚本: 注释用 -- , 语句用合法的 do return M end
    bd_insert_after "/usr/ikuai/script/utils/submit.lua" \
        "^function M:boot" "禁用云端指令通道(submit3)" "do return M end" "--"
    # 切断"云端下发自动升级"(本地手动上传固件/插件仍然可用)
    bd_disable_action "/usr/ikuai/script/upgrade.sh" "update_auto"
}

bd_patch_system() {
    bd_patch_rc
    bd_patch_monitor
    bd_patch_collection
    bd_patch_dtalk
    bd_patch_catcherd
    bd_patch_updates
}

# ---------------------------------------------------------------- 网络层

# 解析域名并加入 ipset(带节流, 避免每分钟大量DNS查询)
# 注意: 只有在确实解析成功时才更新节流时间戳, 否则开机时 WAN 还没起来
#       (解析全失败)会导致之后 10 分钟内都不再重试, 域名封锁形同虚设。
bd_resolve_domains() {
    local now last=0 d ip extra="" n=0
    now=$(date +%s)
    test -f "$BD_RESOLVE_STAMP" && last=$(cat "$BD_RESOLVE_STAMP" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    test $((now - last)) -lt 600 && return 0

    test -f "$(P "$BD_EXT_DOMAINS")" && extra=$(cat "$(P "$BD_EXT_DOMAINS")" 2>/dev/null)

    for d in $BD_DOMAINS $extra; do
        ip="$(dns_lookup_ip "$d")" || continue
        case "$ip" in 127.*|0.0.0.0|"") continue ;; esac
        ipset add "$IPSET_NAME" "$ip" -exist 2>/dev/null && n=$((n + 1))
    done

    if [ "$n" -gt 0 ]; then
        echo "$now" > "$BD_RESOLVE_STAMP" 2>/dev/null
        bd_log "按域名解析补充封锁地址: $n 个"
    else
        bd_log "域名解析未成功(无外网/DNS不可用), 稍后重试"
    fi
}

# 出口封锁: 域名解析结果 + 已知网段 + 云端专用端口
bd_block_network() {
    local n ports extra=""
    ipset create "$IPSET_NAME" hash:net -exist 2>/dev/null || {
        bd_log "ipset 不可用，跳过网络层封锁"
        return 0
    }

    for n in $BD_NETS; do
        ipset add "$IPSET_NAME" "$n" -exist 2>/dev/null
    done
    test -f "$(P "$BD_EXT_NETS")" && extra=$(cat "$(P "$BD_EXT_NETS")" 2>/dev/null)
    for n in $extra; do
        ipset add "$IPSET_NAME" "$n" -exist 2>/dev/null
    done

    bd_resolve_domains

    # 目的地址在封锁集合内 -> DROP
    iptables -C OUTPUT -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null || \
        iptables -I OUTPUT 1 -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null
    iptables -C FORWARD -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null || \
        iptables -I FORWARD 1 -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null

    # 云端专用端口 -> DROP
    ports=$(echo "$BD_PORTS" | tr ' ' ',')
    iptables -C OUTPUT -p tcp -m multiport --dports "$ports" -j DROP 2>/dev/null || \
        iptables -I OUTPUT 2 -p tcp -m multiport --dports "$ports" -j DROP 2>/dev/null
}

# DNS 层兜底: 把云端域名指向 0.0.0.0
# 默认关闭(boot_args: backdoor_hosts=0)，因为写 hosts 可能影响本地门户页面等
# 本地功能；网络层已足够，这里作为可选加固。
bd_block_hosts() {
    local p d
    test "$(get_flag backdoor_hosts 0)" = "1" || return 0

    p="$(P "/etc/hosts")"
    test -f "$p" || return 0
    grep -q "\[$BD_MARK\]" "$p" 2>/dev/null && return 0
    {
        echo "# [$BD_MARK] begin 屏蔽爱快云端域名"
        for d in $BD_DOMAINS; do echo "0.0.0.0 $d"; done
        echo "# [$BD_MARK] end"
    } >> "$p"
    bd_log "已写入 hosts 屏蔽: $p"
}

# ---------------------------------------------------------------- 对外接口

# 完整应用一次(开机调用)
bd_apply() {
    bd_log "开始禁用后门/更新通道"
    bd_kill
    bd_stub
    bd_unlink
    bd_patch_system
    bd_block_network
    bd_block_hosts
    # 文件层改完后再次杀灭: 进程守护(monitor_process.sh)可能又拉起了旧实例
    bd_kill
    bd_log "完成"
}

# 轻量复查(cron 每分钟调用): 只处理会被系统重建的部分
bd_guard() {
    bd_kill
    bd_stub
    bd_block_network
}

# 安装每分钟守卫 cron(防止系统重建防火墙后失效)
bd_install_guard() {
    local cron_dir guard
    cron_dir="$(P "/etc/crontabs/cron.d")"
    guard="$(P "/etc/mnt/.boot/bin/backdoor_guard")"
    mkdir -p "$cron_dir" 2>/dev/null
    chmod +x "$guard" 2>/dev/null
    printf '* * * * * %s\n' "$guard" > "$cron_dir/ikblock_guard"
    bd_log "已安装守卫任务: $cron_dir/ikblock_guard"
    # 立即生效(iKuai 用 crond_commit 汇总 cron.d 到 /etc/crontabs/root)
    if [ -f "$(P /usr/ikuai/include/crond.sh)" ]; then
        ( . "$(P /usr/ikuai/include/crond.sh)"; crond_commit >/dev/null 2>&1 )
    fi
}
