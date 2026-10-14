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
#   /etc/log/ikguard/dns-YYYYMMDD.log   DNS 查询原始记录(tcpdump, 默认关闭, 仅用户手动启停)
#   /etc/log/ikguard/report.txt         最近一次体检报告
#
# 日志规模控制(大小 + 时间双限):
#   AU_KEEP_DAYS 时间周期, AU_MAX_TOTAL 目录总量, AU_MAX_FILE 单文件, AU_DNS_MAX DNS 抓包日志;
#   由 au_rotate()/au_cap_file()/au_dns_cap() 执行(随每分钟的 au_watch 一起跑)。
#
# 依赖: common.sh 的 P()/log()，backdoor.sh 的 BD_PROCS/BD_NETS/BD_PORTS/BD_DOMAINS
#       (可选: 未加载 backdoor.sh 时使用本文件内置兜底名单)

AU_DIR="${AU_DIR:-/etc/log/ikguard}"
AU_KEEP_DAYS="${AU_KEEP_DAYS:-3}"           # 时间周期: 日志保留天数
AU_MAX_TOTAL="${AU_MAX_TOTAL:-314572800}"   # 大小限制: 日志目录总量(默认 300MB), 超出按时间删最老
AU_MAX_FILE="${AU_MAX_FILE:-10485760}"      # 大小限制: 单个日志文件(默认 10MB), 超出滚动为 .1
AU_DNS_MAX="${AU_DNS_MAX:-52428800}"        # 大小限制: DNS 抓包日志(默认 50MB), 超出滚动并按原状态恢复抓包
AU_STATE="/tmp/.ikaudit"
AU_REPORT="report.txt"
AU_DNS_PIDFILE="$AU_STATE/dns.pids"         # DNS 抓包 pid 文件: 启动写入, 停止读取后删除

# 兜底名单(backdoor.sh 未加载时使用)
: "${BD_PROCS:=ik_rc_client cre cre_client pmd dtalkd dtalkc catcherd}"
: "${BD_PORTS:=1853 2016 2221 2502 6000 9443 15602 1863 32015 32017 8086 6444 21422}"
: "${BD_NETS:=59.110.6.0/24 59.110.171.0/24 47.94.237.123/32}"

# 额外可疑关键字(进程/命令行)
AU_PAT="${AU_PAT:-ikuai8.com cre_client dtalk catcherd monidtalk submit.lua update_hosts.sh}"

# 审计忽略: 框架"自己的动作"不算可疑(否则它自己的 DNS 解析探测会被当成后门进程而误报)
AU_IGNORE="${AU_IGNORE:-/etc/mnt/.boot/bin/(ikaudit|backdoor_guard)|nslookup .*(114\.114\.114\.114|223\.5\.5\.5)}"

# 进程快照忽略: 框架目录本身 + 它每轮调起的短命工具(否则 proc 日志全是自身噪声)
AU_PS_IGNORE="${AU_PS_IGNORE:-/etc/mnt/.boot/|^[0-9]+ (/bin/|/usr/bin/)?(busybox +)?(sed|sort|awk|tr|wc|grep|egrep|head|tail|cut|du|find|date|sleep|nslookup) }"

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
# 先排掉"框架自己"的行: 否则 ikaudit/backdoor_guard 及其 DNS 探测(nslookup 公共DNS)
# 会因为命令行里带 ikuai8.com 而被自己的关键字名单命中, 产生自噪声告警。
au_suspect() {
    local line="$1" k
    printf '%s' "$line" | grep -qE "$AU_IGNORE" && return 1
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
    # 过滤框架自身与其短命子进程, 否则 proc 日志每轮都被自身噪声刷屏
    cur="$(au_ps_list | grep -vE "$AU_PS_IGNORE" | sed 's/^ *//' | sort -k1,1n)"
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

# DNS 抓包的生命周期: 只认 pid 文件。
#   启动 -> 记录 pid; 停止 -> 按 pid 关闭并删除 pid 文件。
#   不参与 cron, 也不在开机脚本里自动启动 —— 默认关闭, 只有用户点了"启动"才抓。
au_dns_pids() {
    test -f "$AU_DNS_PIDFILE" || return 0
    awk '{print $1}' "$AU_DNS_PIDFILE" 2>/dev/null
    return 0
}

au_dns_running() {
    local pid
    for pid in $(au_dns_pids); do
        kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}

# 启动 DNS 抓包(仅由用户点击触发): 每张网卡一个 tcpdump, pid 写入 pid 文件
au_dns_start() {
    local i pid n=0
    au_init
    command -v tcpdump >/dev/null 2>&1 || { au_event WARN "dns.nodump" "tcpdump 不可用, 无法记录 DNS 查询"; return 1; }

    au_dns_stop quiet            # 幂等: 重复点击先停掉上一轮, 避免同一网卡重复抓包

    : > "$AU_DNS_PIDFILE"
    for i in $(au_ifaces); do
        # 忽略 SIGHUP, 避免父进程(SSH/脚本)退出时抓包跟着退出; 设备无 nohup/setsid
        ( trap '' HUP; exec tcpdump -i "$i" -nn -l -s 400 -tttt "udp port 53" ) \
            >> "$(au_file dns)" 2>/dev/null &
        pid=$!
        [ -n "$pid" ] && printf '%s %s\n' "$pid" "$i" >> "$AU_DNS_PIDFILE"
        n=$((n + 1))
    done
    if [ "$n" = 0 ]; then
        au_event WARN "dns.start" "没有可用网卡, DNS 记录未启动"
        return 1
    fi
    au_event INFO "dns.start" "已启动 DNS 记录($n 张网卡: $(au_ifaces | tr '\n' ' '))"
    return 0
}

# 停止 DNS 抓包: 按 pid 文件逐个关闭, 然后删除 pid 文件
au_dns_stop() {
    local quiet="${1:-}" pid n=0
    if [ ! -f "$AU_DNS_PIDFILE" ]; then
        [ "$quiet" = "quiet" ] || au_event INFO "dns.stop" "DNS 记录未在运行"
        return 0
    fi
    while read -r pid _; do
        [ -n "$pid" ] || continue
        n=$((n + 1))
        kill "$pid" 2>/dev/null
    done < "$AU_DNS_PIDFILE"
    sleep 1
    while read -r pid _; do          # 仍未退出的补 SIGKILL
        [ -n "$pid" ] || continue
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    done < "$AU_DNS_PIDFILE"
    rm -f "$AU_DNS_PIDFILE"
    [ "$quiet" = "quiet" ] || au_event INFO "dns.stop" "已停止 DNS 记录($n 个抓包进程)"
    return 0
}

# DNS 日志体积封顶: tcpdump 持有文件句柄, 直接 mv 会让它继续写旧文件(变成 .1),
# 因此必须先停抓包 -> 滚动 -> 按原状态恢复(没在抓就保持关闭)。
au_dns_cap() {
    local f max sz running=0
    f="$(au_file dns)"
    test -f "$f" || return 0
    max="$AU_DNS_MAX"
    sz="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
    case "$sz" in ''|*[!0-9]*) return 0 ;; esac
    [ "$sz" -lt "$max" ] && return 0

    au_dns_running && running=1
    au_dns_stop quiet
    rm -f "$f.1" 2>/dev/null
    mv -f "$f" "$f.1" 2>/dev/null
    rm -f "$AU_STATE"/dns.scan.* 2>/dev/null     # 新文件需从头扫描
    [ "$running" = 1 ] && au_dns_start >/dev/null 2>&1
    au_event INFO "dns.rotate" \
        "DNS 日志超过 $max 字节, 已滚动, 抓包$( [ "$running" = 1 ] && echo '继续' || echo '保持停止')"
    return 0
}

# 检查 DNS 日志里是否出现云端域名
# 增量扫描: 用偏移量记录已扫描位置, 只扫新增内容 —— 否则 cron 每分钟重扫整天的日志,
# 会把同一个域名的 dns.cloud 事件重复写进审计日志(体检报告里的计数也就失真了)。
au_dns_check() {
    local f hit n=0 off_file off size chunk
    f="$(au_file dns)"
    [ -f "$f" ] || { printf '0'; return 0; }

    off_file="$AU_STATE/dns.scan.$(date +%Y%m%d)"
    off=0
    test -f "$off_file" && off="$(cat "$off_file" 2>/dev/null)"
    case "$off" in ''|*[!0-9]*) off=0 ;; esac
    size="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    [ "$size" -lt "$off" ] && off=0          # 日志被轮转/清空则从头扫
    [ "$size" -eq "$off" ] && { printf '0'; return 0; }

    # 跳过"框架自己"发往公共 DNS 的解析探测(backdoor_guard 补封锁 IP 用的),
    # 只保留客户端真实 DNS 查询, 否则 dns.cloud 全是自噪声。
    chunk="$(tail -c "+$((off + 1))" "$f" 2>/dev/null | grep -vE '(114\.114\.114\.114|223\.5\.5\.5)\.53')"
    for hit in $BD_DOMAINS; do
        if printf '%s\n' "$chunk" | grep -qiF -- "$hit" 2>/dev/null; then
            n=$((n + 1))
            au_event INFO "dns.cloud" "解析查询命中云端域名: $hit"
        fi
    done
    printf '%s' "$size" > "$off_file" 2>/dev/null
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

# 通用单文件体积封顶: 超过上限则滚动为 <文件>.1(只保留一代)
au_cap_file() {
    local f="$1" max="$2" sz
    test -f "$f" || return 0
    sz="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
    case "$sz" in ''|*[!0-9]*) return 0 ;; esac
    [ "$sz" -lt "$max" ] && return 0
    rm -f "$f.1" 2>/dev/null
    mv -f "$f" "$f.1" 2>/dev/null
    return 0
}

# 日志维护(时间周期 + 目录总量): 每分钟随 au_watch 执行
au_rotate() {
    # 1) 时间周期: 超过保留天数直接删除(含滚动出的 .1)
    find "$(au_dir)" -type f \( -name '*.log' -o -name '*.log.[0-9]*' \) \
        -mtime "+$AU_KEEP_DAYS" -delete 2>/dev/null

    # 2) 目录总量上限: 超出则按修改时间删最老的, 保证不会无限增长
    local max used old
    max=$((AU_MAX_TOTAL / 1024))
    while :; do
        used="$(du -sk "$(au_dir)" 2>/dev/null | awk '{print $1}')"
        case "$used" in ''|*[!0-9]*) break ;; esac
        [ "$used" -le "$max" ] && break
        old="$(ls -1t "$(au_dir)"/*.log* 2>/dev/null | tail -n1)"
        [ -n "$old" ] || break
        rm -f "$old" 2>/dev/null
    done
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

    # 统计"云端相关"审计事件: dns.cloud / cloud.ip / cloud.port / probe.cloud
    # 注意: 事件名里 cloud 后面是空格(如 "dns.cloud          解析..."), 所以
    #       不能用 grep 'cloud\.' —— 那个点号在 cloud 前面, 永远匹配不到(报告恒为 0)。
    ncloud=$(grep -cE 'dns\.cloud|cloud\.(ip|port)|probe\.cloud' "$(au_file audit)" 2>/dev/null)
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
# 注意: 这里**不启停 DNS 抓包** —— 抓包默认关闭、只由用户在前端手动开关,
#       否则用户点了"停止", 下一分钟又被拉起来(与 cron 无关)。
#       这里只做: 采集 + 日志维护(时间/体积), 抓包超限时按原状态滚动。
au_watch() {
    au_init
    au_rotate
    au_proc_scan >/dev/null
    au_conn_scan >/dev/null
    au_blocked_scan >/dev/null
    au_dns_check >/dev/null
    au_dns_cap
    au_cap_file "$(au_dir)/boot.log" "$AU_MAX_FILE"
    au_cap_file "$(au_file audit)"   "$AU_MAX_FILE"
    au_cap_file "$(au_file proc)"    "$AU_MAX_FILE"
    au_cap_file "$(au_file conn)"    "$AU_MAX_FILE"
    return 0
}

# 安装审计 cron(每分钟目录采集 + 每 10 分钟体检)
au_install_cron() {
    local cron_dir root bin
    cron_dir="$(P /etc/crontabs/cron.d)"
    root="$(P /etc/crontabs/root)"
    bin="$(P /etc/mnt/.boot/bin/ikaudit)"
    mkdir -p "$cron_dir" 2>/dev/null
    # 保留 cron.d 文件(便于查看/别的脚本复用)
    printf '* * * * * %s watch\n' "$bin" > "$cron_dir/ikguard_audit"
    printf '*/10 * * * * %s report\n' "$bin" > "$cron_dir/ikguard_report"

    # 关键: iKuai 的 crond 只读 /etc/crontabs/root, cron.d 只是它自己的暂存目录,
    # 而且它的 crond_commit 会整体重写 root —— 所以必须把任务直接写进 root,
    # 否则"每分钟采集"根本不会执行(日志里只有开机那一次的数据)。
    # 先清掉本框架的旧任务行(旧版本可能残留 probe 等自动动作), 再写入当前应有的两条,
    # 保证 root 里只保留"该做的事"; 直接追加也能保证幂等(不会重复)。
    if [ -f "$root" ]; then
        grep -v "$bin" "$root" > "$root.ikguard.tmp" 2>/dev/null || :
        mv -f "$root.ikguard.tmp" "$root" 2>/dev/null
    else
        mkdir -p "$(dirname "$root")" 2>/dev/null
        : > "$root"
    fi
    printf '* * * * * %s watch\n'   "$bin" >> "$root"
    printf '*/10 * * * * %s report\n' "$bin" >> "$root"
    au_event INFO "cron.install" "已安装审计任务到 $root (每分钟 watch / 每10分钟 report)"

    # 兜底: 让 iKuai 自己再提交一次(iKuai 的 crond 每分钟会检查 crontab 变化)
    if [ -f "$(P /usr/ikuai/include/crond.sh)" ]; then
        ( . "$(P /usr/ikuai/include/crond.sh)"; crond_commit >/dev/null 2>&1 )
    fi
    return 0
}
