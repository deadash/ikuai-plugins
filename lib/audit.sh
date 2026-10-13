#!/bin/bash
#
# 审计/取证库: 记录"进程启动 / DNS 请求 / 网络连接 / 封锁命中", 用于确认没有
# 后门进程被拉起、没有与爱快云端建立连接。
#
# 日志全部写在持久分区 /etc/log (sda5, 容量大, 重启不丢):
#   /etc/log/ikguard/boot.log           框架开机日志
#   /etc/log/ikguard/audit-YYYYMMDD.log 审计事件(结构化)
#   /etc/log/ikguard/proc-YYYYMMDD.log  进程快照与新增进程
#   /etc/log/ikguard/conn-YYYYMMDD.log  出向连接快照与新增连接
#   /etc/log/ikguard/dns-YYYYMMDD.log   DNS 查询原始记录(tcpdump)
#   /etc/log/ikguard/report.txt         最近一次体检报告
#
# 依赖: common.sh 的 P()/log()，backdoor.sh 的 BD_PROCS/BD_NETS/BD_PORTS/BD_DOMAINS
#       (可选: 未加载 backdoor.sh 时使用本文件内置兜底名单)

AU_DIR="${AU_DIR:-/etc/log/ikguard}"
AU_KEEP_DAYS="${AU_KEEP_DAYS:-3}"
AU_STATE="/tmp/.ikaudit"
AU_REPORT="report.txt"

# 兜底名单(backdoor.sh 未加载时使用)
: "${BD_PROCS:=ik_rc_client cre cre_client pmd dtalkd dtalkc catcherd}"
: "${BD_PORTS:=1853 2016 2221 2502 6000 9443 15602 1863 32015 32017 8086 6444 21422}"
: "${BD_NETS:=59.110.6.0/24 59.110.171.0/24 47.94.237.123/32}"

# 额外可疑关键字(进程/命令行)
AU_PAT="${AU_PAT:-ikuai8.com cre_client dtalk catcherd monidtalk submit.lua update_hosts.sh}"

au_log() { log "[audit] $*"; }

# ---------------------------------------------------------------- 基础

au_dir() { printf '%s' "$(P "$AU_DIR")"; }

au_stamp() { date '+%Y-%m-%d %H:%M:%S'; }

# au_file <kind> -> 当天日志路径
au_file() {
    printf '%s/%s-%s.log' "$(au_dir)" "$1" "$(date +%Y%m%d)"
}

au_init() {
    mkdir -p "$(au_dir)" "$(P "$AU_STATE")" 2>/dev/null
    return 0
}

# au_emit <kind> <level> <event> <detail...>
au_emit() {
    local kind="$1" level="$2" event="$3"
    shift 3
    au_init
    printf '%s %-5s %-18s %s\n' "$(au_stamp)" "$level" "$event" "$*" >> "$(au_file "$kind")" 2>/dev/null
}

# 审计事件(写 audit 日志 + 框架日志)
au_event() {
    local level="$1" event="$2"
    shift 2
    au_emit audit "$level" "$event" "$*"
    log "[audit][$level] $event $*"
}

# 进程列表: "pid cmdline"
au_ps_list() {
    local p pid cmd
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        pid="${p#/proc/}"
        cmd="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)"
        cmd="${cmd% }"
        [ -n "$cmd" ] && printf '%s %s\n' "$pid" "$cmd"
    done
    return 0
}

# 判断某行是否命中可疑关键字
au_suspect() {
    local line="$1" k
    for k in $BD_PROCS $AU_PAT; do
        case "$line" in *"$k"*) printf '%s' "$k"; return 0 ;; esac
    done
    return 1
}

# IP 是否属于内网
au_is_private() {
    case "$1" in
        10.*|127.*|169.254.*|192.168.*|0.0.0.0) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
        224.*|239.*|255.*) return 0 ;;
    esac
    return 1
}

# IP 是否落在云端网段名单(BD_NETS)里
au_ip_in_nets() {
    local ip="$1" n
    for n in $BD_NETS; do
        case "$n" in
            *"/32") [ "$ip" = "${n%/32}" ] && return 0 ;;
            *"/24") [ "${ip%.*}" = "${n%.*}" ] && return 0 ;;
            *)      [ "$ip" = "$n" ] && return 0 ;;
        esac
    done
    return 1
}

# ---------------------------------------------------------------- 进程审计

# 快照对比: 记录新出现的进程, 命中可疑名单则告警
au_proc_scan() {
    local snap="$AU_STATE/ps.snap" cur new suspect n=0
    au_init
    cur="$(au_ps_list | sed 's/^ *//' | sort -k1,1n)"
    printf '%s\n' "$cur" > "$snap.new"

    if [ -f "$snap" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            grep -qxF -- "$line" "$snap" 2>/dev/null && continue
            n=$((n + 1))
            au_emit proc INFO "proc.start" "${line%% *} ${line#* }"
            if suspect="$(au_suspect "$line")"; then
                au_event WARN "backdoor.proc" "命中可疑进程关键字=$suspect pid=${line%% *} cmd=${line#* }"
            fi
        done < "$snap.new"
    else
        au_emit proc INFO "proc.snapshot" "首次快照, 共 $(printf '%s\n' "$cur" | grep -c . ) 个进程"
    fi

    # 当前仍存活的名单进程
    local p
    for p in $BD_PROCS; do
        if pidof "$p" >/dev/null 2>&1; then
            au_event WARN "backdoor.alive" "进程仍在运行: $p pid=$(pidof "$p" 2>/dev/null | tr ' ' ',')"
        fi
    done

    mv -f "$snap.new" "$snap" 2>/dev/null
    printf '%s' "$n"
    return 0
}

# ---------------------------------------------------------------- 连接审计

# 从 conntrack 提取出向连接 "dport proto dst src"
au_conn_list() {
    local line dst dport proto
    [ -r /proc/net/nf_conntrack ] || return 0
    while IFS= read -r line; do
        proto="$(printf '%s' "$line" | awk '{print $3}')"
        case "$proto" in tcp|udp) ;; *) continue ;; esac
        # 只取正向第一组 src/dst
        dst="$(printf '%s' "$line" | sed -n 's/.*dst=\([0-9a-fA-F:.]*\).*/\1/p' | head -n1)"
        dport="$(printf '%s' "$line" | sed -n 's/.*dport=\([0-9]*\).*/\1/p' | head -n1)"
        [ -n "$dst" ] || continue
        au_is_private "$dst" && continue
        printf '%s %s %s\n' "${dport:--}" "$proto" "$dst"
    done < /proc/net/nf_conntrack | sort -u
    return 0
}

au_conn_scan() {
    local snap="$AU_STATE/conn.snap" cur n=0 dport proto dst hit
    au_init
    cur="$(au_conn_list)"
    printf '%s\n' "$cur" > "$snap.new"

    if [ -f "$snap" ]; then
        while IFS=' ' read -r dport proto dst; do
            [ -n "$dst" ] || continue
            grep -qxF -- "$dport $proto $dst" "$snap" 2>/dev/null && continue
            n=$((n + 1))
            au_emit conn INFO "conn.out" "$proto dst=$dst dport=$dport"
            for hit in $BD_PORTS; do
                [ "$dport" = "$hit" ] && au_event WARN "cloud.port" "出向连接到云端专用端口 dst=$dst dport=$dport proto=$proto"
            done
            au_ip_in_nets "$dst" && \
                au_event WARN "cloud.ip" "出向连接到云端网段 dst=$dst dport=$dport"
        done < "$snap.new"
    else
        au_emit conn INFO "conn.snapshot" "首次快照, 当前出向连接 $(printf '%s\n' "$cur" | grep -c . ) 条"
    fi

    mv -f "$snap.new" "$snap" 2>/dev/null
    printf '%s' "$n"
    return 0
}

# ---------------------------------------------------------------- 封锁命中

# 读取 ikblock 相关 DROP 规则计数器, 记录增量(有增量=确有出向被封)
au_blocked_scan() {
    local cur="$AU_STATE/fw.count" now n=0 l
    au_init
    iptables -nvx -L OUTPUT 2>/dev/null | grep -E "ikuai_blk|multiport" > "$cur.new"
    iptables -nvx -L FORWARD 2>/dev/null | grep -E "ikuai_blk" >> "$cur.new"

    if [ -f "$cur" ] && [ -s "$cur" ]; then
        while read -r pkts bytes rest; do
            case "$pkts" in ''|*[!0-9]*) continue ;; esac
            l="$(grep -F -- "$rest" "$cur" 2>/dev/null | head -n1)"
            case "$l" in
                "") continue ;;
                *) old="${l%% *}"; [ "$pkts" -gt "$old" ] 2>/dev/null && {
                        n=$((n + 1))
                        au_event INFO "block.hit" "封锁规则命中 +$((pkts - old)) 包: $rest"
                   } ;;
            esac
        done < "$cur.new"
    fi
    mv -f "$cur.new" "$cur" 2>/dev/null
    printf '%s' "$n"
    return 0
}

# ---------------------------------------------------------------- DNS 审计

# 设备上的数据网卡(排除 lo/imq/tunl/gre/隧道 等虚拟口与 sysfs 伪节点)
au_ifaces() {
    local i
    for i in $(ls /sys/class/net 2>/dev/null); do
        case "$i" in
            lo|imq*|tunl*|gre*|gretap*|erspan*|ifb*|sit*|ip6*|ip_vti*|ip6_vti*|bonding_masters|docker*|veth*)
                continue ;;
        esac
        # 桥/绑定成员不单独抓: 否则同一报文会在 br(lan1/wan1) 和物理口(eth0/eth1) 里各记一次
        [ -e "/sys/class/net/$i/master" ] && continue
        printf '%s\n' "$i"
    done
    return 0
}

# 找出所有"本框架启动的"DNS 抓包进程(按命令行匹配, 不依赖 pid 文件)
au_dns_pids() {
    local dir pid cmd
    for dir in /proc/[0-9]*; do
        pid="${dir#/proc/}"
        cmd="$( { tr '\0' ' ' < "$dir/cmdline"; } 2>/dev/null )"
        case "$cmd" in *tcpdump*"port 53"*) printf '%s\n' "$pid" ;; esac
    done
    return 0
}

au_dns_running() {
    [ -n "$(au_dns_pids)" ] && return 0
    return 1
}

# 启动 DNS 抓包(每张网卡一个 tcpdump, 追加到当天 dns 日志)
# 说明: 重复点击要幂等 —— 先杀掉旧的再按当前网卡列表重建, 否则会出现同一网卡
#       多个 tcpdump 且 pid 文件被覆盖, 导致"停止"停不干净(旧 bug)。
au_dns_start() {
    local i pid n=0
    au_init
    command -v tcpdump >/dev/null 2>&1 || { au_event WARN "dns.nodump" "tcpdump 不可用, 无法记录 DNS 查询"; return 1; }

    # 先清理旧实例(含开机时启动的), 避免重复抓同一张网卡
    au_dns_stop quiet

    : > "$AU_STATE/dns.pids"
    for i in $(au_ifaces); do
        # 忽略 SIGHUP, 避免父进程(SSH/脚本)退出时抓包跟着退出; 设备无 nohup/setsid
        ( trap '' HUP; exec tcpdump -i "$i" -nn -l -s 400 -tttt "udp port 53 or tcp port 53" ) \
            >> "$(au_file dns)" 2>/dev/null &
        pid=$!
        printf '%s %s\n' "$pid" "$i" >> "$AU_STATE/dns.pids"
        n=$((n + 1))
    done
    if [ "$n" = 0 ]; then
        au_event WARN "dns.start" "没有可用网卡, DNS 记录未启动"
        return 1
    fi
    au_event INFO "dns.start" "已启动 DNS 记录($n 张网卡: $(au_ifaces | tr '\n' ' '))"
    return 0
}

# 停止 DNS 抓包: 既按 pid 文件, 也按命令行兜底(防止 pid 文件过期/丢失)
au_dns_stop() {
    local quiet="$1" pid n=0
    # 1) pid 文件
    if [ -f "$AU_STATE/dns.pids" ]; then
        while read -r pid _; do
            [ -n "$pid" ] || continue
            kill "$pid" 2>/dev/null && n=$((n + 1))
        done < "$AU_STATE/dns.pids"
        rm -f "$AU_STATE/dns.pids"
    fi
    # 2) 命令行兜底
    for pid in $(au_dns_pids); do
        kill "$pid" 2>/dev/null && n=$((n + 1))
    done
    sleep 1
    for pid in $(au_dns_pids); do
        kill -9 "$pid" 2>/dev/null
    done
    [ "$quiet" = "quiet" ] || au_event INFO "dns.stop" "已停止 DNS 记录($n 个抓包进程)"
    return 0
}

# 检查当天 DNS 日志里是否出现云端域名
au_dns_check() {
    local f hit n=0
    f="$(au_file dns)"
    [ -f "$f" ] || { printf '0'; return 0; }
    for hit in $BD_DOMAINS; do
        if grep -qiF -- "$hit" "$f" 2>/dev/null; then
            n=$((n + 1))
            au_event INFO "dns.cloud" "解析查询命中云端域名: $hit"
        fi
    done
    printf '%s' "$n"
    return 0
}

# ---------------------------------------------------------------- 主动探测

# au_probe: 解析云端域名 + 尝试建立 TCP 连接(区分"解析到但连不上"=封锁生效)
au_tcp_probe() {
    local ip="$1" port="$2" pid
    ( exec 3<>"/dev/tcp/$ip/$port" ) 2>/dev/null &
    pid=$!
    # 3 秒兜底(不主动杀兜底进程, 避免 shell 打印 "Killed" 噪音; 它自己会超时退出)
    ( sleep 3; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    if wait "$pid" 2>/dev/null; then
        return 0
    fi
    return 1
}

au_probe() {
    local d ip blocked=0 resolved=0 reachable=0
    au_init
    printf '=== 云端连通性自检 %s ===\n' "$(au_stamp)"
    printf '说明: 解析成功但 TCP 连接失败 = 封锁生效; 若能连通则说明封锁失效。\n\n'
    au_event INFO "probe.begin" "开始云端连通性自检"

    for d in 302.ikuai8.com pkgmanager.ikuai8.com download.ikuai8.com; do
        ip="$(dns_lookup_ip "$d")"
        if [ -z "$ip" ]; then
            printf '  %-24s 未解析到地址(设备无外网 / DNS 不可达)\n' "$d"
            au_event INFO "probe.dns" "域名=$d 未解析到地址(环境无外网/DNS 不可达)"
            continue
        fi
        resolved=$((resolved + 1))
        if au_tcp_probe "$ip" 443; then
            reachable=$((reachable + 1))
            printf '  %-24s -> %-16s TCP 443 可连通 [异常! 封锁可能失效]\n' "$d" "$ip"
            au_event WARN "probe.tcp" "!!! 可连通云端 $ip:443 (封锁可能失效)"
        else
            blocked=$((blocked + 1))
            printf '  %-24s -> %-16s TCP 443 连接失败 [正常, 已被阻断]\n' "$d" "$ip"
            au_event INFO "probe.tcp" "连接云端 $ip:443 失败(封锁生效/无外网)"
        fi
    done

    printf '\n汇总: 解析成功 %s 个, 连接被阻断 %s 个, 可连通 %s 个\n' "$resolved" "$blocked" "$reachable"
    if [ "$reachable" -gt 0 ]; then
        printf '结论: 异常, 存在可连通的云端地址, 请检查 ipset/iptables 封锁规则\n'
    elif [ "$resolved" -gt 0 ]; then
        printf '结论: 正常, 云端域名可解析但连接全部被阻断\n'
    else
        printf '结论: 无法判断(设备当前没有可用外网, 请先把 WAN 配置好)\n'
    fi
    printf 'resolved=%s blocked=%s reachable=%s\n' "$resolved" "$blocked" "$reachable"
    return 0
}

# ---------------------------------------------------------------- 报告/维护

# 封锁规则累计命中包数
au_blocked_hits() {
    { iptables -nvx -L OUTPUT 2>/dev/null; iptables -nvx -L FORWARD 2>/dev/null; } | \
        awk '/ikuai_blk|multiport/{s+=$1} END{print s+0}'
    return 0
}

au_rotate() {
    find "$(au_dir)" -type f -name '*.log' -mtime "+$AU_KEEP_DAYS" -delete 2>/dev/null
    return 0
}

# 生成体检报告, 返回 0=正常 1=发现异常
au_report() {
    local suspect=0 alive="" ncloud=0 dns_warn=0 out cloud_lines=""
    au_init

    local p
    for p in $BD_PROCS; do
        if pidof "$p" >/dev/null 2>&1; then
            suspect=1
            alive="$alive $p($(pidof "$p" 2>/dev/null | tr ' ' ','))"
        fi
    done

    # 当前出向连接里是否有云端地址/端口
    local dport proto dst
    while IFS=' ' read -r dport proto dst; do
        [ -n "$dst" ] || continue
        for hit in $BD_PORTS; do
            [ "$dport" = "$hit" ] && { suspect=1; cloud_lines="$cloud_lines
  - 云端端口连接 dst=$dst dport=$dport proto=$proto"; }
        done
        au_ip_in_nets "$dst" && {
            suspect=1; cloud_lines="$cloud_lines
  - 云端网段连接 dst=$dst dport=$dport proto=$proto"
        }
    done <<EOF
$(au_conn_list)
EOF

    ncloud=$(grep -c "cloud\." "$(au_file audit)" 2>/dev/null)
    case "$ncloud" in ''|*[!0-9]*) ncloud=0 ;; esac

    {
        echo "ikguard 安全体检报告 $(au_stamp)"
        echo "-----------------------------------------------"
        echo "进程:   后门进程存活  : ${alive:-无}"
        echo "网络:   云端连接/端口 : $(printf '%s' "$cloud_lines" | grep -c . ) 条"
        echo "DNS:    云端域名解析  : ${ncloud} 次(今日审计日志)"
        echo "封锁:   ipset ikuai_blk: $(ipset -L ikuai_blk 2>/dev/null | grep -c '^[0-9]') 条"
        echo "        封锁规则       : $(iptables -S 2>/dev/null | grep -c ikuai_blk) 条"
        echo "        阻断端口规则   : $(iptables -S 2>/dev/null | grep -c multiport) 条"
        echo "        命中包数       : $(au_blocked_hits) 包"
        echo "探针:   DNS 抓包进程  : $(au_dns_running && echo 运行中 || echo 未运行)"
        echo "-----------------------------------------------"
        if [ "$suspect" = 1 ]; then
            printf '结论: 异常(发现后门进程或云端连接)\n'
            printf "$cloud_lines\n"
        else
            printf '结论: 正常(无后门进程, 无云端连接)\n'
        fi
    } > "$(au_dir)/$AU_REPORT" 2>/dev/null
    cat "$(au_dir)/$AU_REPORT"

    [ "$suspect" = 1 ] && return 1
    return 0
}

# cron 入口: 每一轮采集
au_watch() {
    au_init
    au_rotate
    au_proc_scan >/dev/null
    au_conn_scan >/dev/null
    au_blocked_scan >/dev/null
    au_dns_check >/dev/null
    au_dns_running || au_dns_start >/dev/null 2>&1
    return 0
}

# 安装审计 cron(每分钟目录采集 + 每 10 分钟体检)
au_install_cron() {
    local cron_dir
    cron_dir="$(P /etc/crontabs/cron.d)"
    mkdir -p "$cron_dir" 2>/dev/null
    printf '* * * * * %s watch\n' "$(P /etc/mnt/.boot/bin/ikaudit)" > "$cron_dir/ikguard_audit"
    printf '*/10 * * * * %s report\n' "$(P /etc/mnt/.boot/bin/ikaudit)" > "$cron_dir/ikguard_report"
    au_event INFO "cron.install" "已安装审计任务: $cron_dir/ikguard_{audit,report}"
    # 立即生效(iKuai 用 crond_commit 汇总 cron.d 到 /etc/crontabs/root)
    if [ -f "$(P /usr/ikuai/include/crond.sh)" ]; then
        ( . "$(P /usr/ikuai/include/crond.sh)"; crond_commit >/dev/null 2>&1 )
    fi
    return 0
}
