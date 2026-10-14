#!/bin/bash
#
# 审计/取证库 —— **被动采集**(事件驱动, 不用 cron, 不做轮询)
#
# 设计要点:
#   1) 只有一个常驻采集器(bin/ikaudit collect), 由开关 audit 控制启停:
#        audit=1 开机自动拉起、=0 停止; 默认关闭(install.sh 写入 audit=0)
#   2) 事件全部来自内核推送, 没有任何定时轮询:
#        conntrack -E   连接事件([NEW]/[DESTROY]); dport=53 的另存为 DNS 事件
#        /dev/kmsg      封锁命中(命中 DROP 的包由 -j LOG 写进内核日志)
#   3) **不做"程序启动"判断** —— 本内核没有 exec/fork 事件源
#      (CONFIG_CONNECTOR / CONFIG_AUDIT / CONFIG_KPROBES / CONFIG_FTRACE 均未编译)
#   4) **不做 DNS 抓包** —— DNS 只是连接事件里 dport=53 的子集(conntrack 拿不到域名)
#
# 日志(持久分区 /etc/log, 重启不丢):
#   boot.log            框架日志
#   audit-YYYYMMDD.log  结构化事件
#   conn-YYYYMMDD.log   连接事件
#   dns-YYYYMMDD.log    DNS(dport=53)事件
#   block-YYYYMMDD.log  封锁命中(原始内核日志行)
#   report.txt          最近一次报告
#
# 依赖: common.sh 的 P()/log()/get_flag()，backdoor.sh 的 BD_PORTS/BD_NETS/IPSET_NAME

AU_DIR="${AU_DIR:-/etc/log/ikguard}"
AU_KEEP_DAYS="${AU_KEEP_DAYS:-3}"           # 时间周期: 日志保留天数
AU_MAX_TOTAL="${AU_MAX_TOTAL:-314572800}"   # 大小限制: 日志目录总量(默认 300MB)
AU_MAX_FILE="${AU_MAX_FILE:-10485760}"      # 大小限制: 单个日志文件(默认 10MB)
AU_STATE="/tmp/.ikaudit"
AU_REPORT="report.txt"
AU_COLLECT_PIDFILE="$AU_STATE/collect.pid"
AU_BLK_CHAIN="${AU_BLK_CHAIN:-${BD_BLK_CHAIN:-IKG_BLK}}"   # backdoor.sh 的封锁链: 命中日志挂这里
AU_LOG_TAG="${AU_LOG_TAG:-ikguard-blk}"         # 内核日志里的标记(匹配用)
AU_LOG_PREFIX="${AU_LOG_PREFIX:-$AU_LOG_TAG }"  # iptables -j LOG 的前缀
AU_PROBE_CRON="${AU_PROBE_CRON:-*/10}"      # 定时自检的 cron 周期

# 兜底名单(backdoor.sh 未加载时使用)
: "${BD_PORTS:=1853 2016 2221 2502 6000 9443 15602 1863 32015 32017 8086 6444 21422}"
: "${BD_NETS:=59.110.6.0/24 59.110.171.0/24 47.94.237.123/32}"
: "${IPSET_NAME:=ikuai_blk}"

au_log() { log "[audit] $*"; }

# ---------------------------------------------------------------- 基础

# 读取开关(boot_args); 缺省返回 $2(默认 0)
au_flag() {
    if command -v get_flag >/dev/null 2>&1; then
        get_flag "$1" "${2:-0}"
    else
        printf '%s' "${2:-0}"
    fi
}

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

# 统计某类事件条数(按事件名匹配 —— 避免把旧版本留下的其它格式内容也算进来)
au_count() {
    local f="$1" pat="$2"
    [ -f "$f" ] || { printf '0'; return 0; }
    if [ -n "$pat" ]; then
        grep -cE "$pat" "$f" 2>/dev/null || printf '0'
    else
        grep -c . "$f" 2>/dev/null || printf '0'
    fi
}

# IP 是否属于内网/组播(这些不出现在"对外连接"档案里)
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

# 端口是否属于云端专用端口
au_port_in_list() {
    local p="$1" x
    for x in $BD_PORTS; do
        [ "$p" = "$x" ] && return 0
    done
    return 1
}

# pid 是否真的在运行(排除僵尸)
au_pid_running() {
    local s
    [ -n "$1" ] && [ -d "/proc/$1" ] || return 1
    read -r s < "/proc/$1/stat" 2>/dev/null || return 1
    s="${s#*) }"; s="${s%% *}"
    case "$s" in Z|X) return 1 ;; esac
    return 0
}

# ---------------------------------------------------------------- 日志规模

# 通用单文件体积封顶: 超过上限则滚动为 <文件>.1(保留一代)
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

# 日志维护(时间周期 + 目录总量 + 单文件体积)
au_rotate() {
    local f
    find "$(au_dir)" -type f \( -name '*.log' -o -name '*.log.[0-9]*' \) \
        -mtime "+$AU_KEEP_DAYS" -delete 2>/dev/null

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

    for f in audit conn dns block; do
        au_cap_file "$(au_file "$f")" "$AU_MAX_FILE"
    done
    au_cap_file "$(au_dir)/boot.log" "$AU_MAX_FILE"
    return 0
}

# ---------------------------------------------------------------- 封锁命中日志

# iptables 是否支持 -j LOG(设备 3.7.16 实测自带该目标, 无需外部扩展)
# 若哪天固件砍掉了, 可用 .tools/build_xt_LOG.sh 编一个补到 /usr/lib/iptables/
au_xt_log_ok() {
    iptables -j LOG -h 2>&1 | grep -q 'log-prefix'
}

# 在封锁链首位插入 LOG(非终止: 记完继续 DROP) -> 命中即写内核日志
au_log_rule_on() {
    au_xt_log_ok || {
        au_event WARN "block.nolog" "iptables 不支持 -j LOG, 封锁命中无法事件化"
        return 1
    }
    iptables -N "$AU_BLK_CHAIN" 2>/dev/null
    iptables -C "$AU_BLK_CHAIN" -j LOG --log-prefix "$AU_LOG_PREFIX" 2>/dev/null && return 0
    iptables -I "$AU_BLK_CHAIN" 1 -j LOG --log-prefix "$AU_LOG_PREFIX" 2>/dev/null
    return 0
}

au_log_rule_off() {
    while iptables -C "$AU_BLK_CHAIN" -j LOG --log-prefix "$AU_LOG_PREFIX" 2>/dev/null; do
        iptables -D "$AU_BLK_CHAIN" -j LOG --log-prefix "$AU_LOG_PREFIX" 2>/dev/null || break
    done
    return 0
}

# ---------------------------------------------------------------- 事件处理

# conntrack 事件行, 例如:
#   [1791946078.802537]  [NEW] tcp 6 5 SYN_SENT src=10.0.2.15 dst=1.2.3.4 sport=1 dport=443 ...
# 只用 shell 内建解析(每个事件都 fork 一次 sed/awk 会拖垮设备)
au_ct_event() {
    local line="$1" ev proto src dst sport dport rest

    case "$line" in
        *'[NEW]'*)     ev=NEW ;;
        *'[DESTROY]'*) ev=DESTROY ;;
        *'[UPDATE]'*)  return 0 ;;            # UPDATE 太吵, 不记
        *)             return 0 ;;
    esac

    # 去掉"[时间戳]"与"[事件]"两个方括号, 剩下的第一个字段就是协议
    # (注意不能用 ${line#*[NEW] }: 这里的方括号在 pattern 里是字符类)
    rest="${line#*]}"; rest="${rest#*]}"
    set -- $rest                              # tcp 6 5 SYN_SENT src=... dst=...
    proto="${1:--}"
    case "$proto" in *[!a-zA-Z]*) proto="-" ;; esac

    src="${line#*src=}";   src="${src%% *}"
    dst="${line#*dst=}";   dst="${dst%% *}"
    sport="${line#*sport=}"; sport="${sport%% *}"
    dport="${line#*dport=}"; dport="${dport%% *}"
    case "$line" in *dport=*) ;; *) dport="-" ;; esac

    [ -n "$dst" ] || return 0
    au_is_private "$dst" && return 0

    au_emit conn INFO "conn.$ev" "$proto $src:$sport -> $dst:$dport"

    # DNS: dport=53 单独存档(域名在报文里, 这里只到"谁向谁查")
    if [ "$dport" = "53" ]; then
        au_emit dns INFO "dns.query" "$proto $src:$sport -> $dst:$dport"
    fi

    # 出现"云端网段/专用端口"的**已建立**连接 = 封锁可能失效(被拦的包根本进不了 conntrack)
    if [ "$ev" = NEW ]; then
        au_port_in_list "$dport" && \
            au_event WARN "cloud.leak" "出向连到云端专用端口且未被拦截: $proto $src:$sport -> $dst:$dport"
        au_ip_in_nets "$dst" && \
            au_event WARN "cloud.leak" "出向连到云端网段且未被拦截: $proto $src:$sport -> $dst:$dport"
    fi
    return 0
}

# 内核日志行: "6,618,49727577,-;ikguard-blk: IN= OUT=wan1 SRC=.. DST=.. PROTO=TCP DPT=443"
au_kmsg_event() {
    local line="$1" seq msg src dst proto dpt
    seq="${line#*,}"; seq="${seq%%,*}"
    case "$seq" in ''|*[!0-9]*) return 0 ;; esac
    [ "$seq" -le "${AU_KMSG_SEQ:-0}" ] && return 0     # 启动前的旧记录不重放

    msg="${line#*;}"
    # 内核不一定原样带上前缀后的空格, 用 tag 匹配更稳(如 "ikguard-blk: IN=..." )
    case "$msg" in *"$AU_LOG_TAG"*) ;; *) return 0 ;; esac

    src="${msg#*SRC=}";   src="${src%% *}"
    dst="${msg#*DST=}";   dst="${dst%% *}"
    proto="${msg#*PROTO=}"; proto="${proto%% *}"
    case "$msg" in *DPT=*) dpt="${msg#*DPT=}"; dpt="${dpt%% *}" ;; *) dpt="-" ;; esac
    [ -n "$src$dst" ] || { src="-"; dst="-"; }
    [ -n "$proto" ] || proto="-"

    au_emit block INFO "block.hit" "$proto $src -> $dst:$dpt"
    au_event WARN "block.hit" "封锁命中: $proto $src -> $dst:$dpt"
    return 0
}

# ---------------------------------------------------------------- 采集器

au_collect_running() {
    local pid=""
    test -f "$AU_COLLECT_PIDFILE" && read -r pid < "$AU_COLLECT_PIDFILE"
    au_pid_running "$pid"
}

au_ct_spawn() {
    ( trap '' HUP; exec conntrack -E -o timestamp ) > "$AU_FIFO" 2>/dev/null &
    AU_CT_PID=$!
}

au_km_spawn() {
    ( trap '' HUP; exec cat /dev/kmsg ) > "$AU_FIFO" 2>/dev/null &
    AU_KM_PID=$!
}

# 当前 /dev/kmsg 的最大 seq —— 避免重放"上一次采集"留下的旧命中。
# 注意: 不能用 `head -c N /dev/kmsg`, 环形缓冲不足 N 字节时它会永久阻塞(/dev/kmsg 不会 EOF)。
au_kmsg_seq_now() {
    local tmp="$AU_STATE/kmsg.probe" p n
    au_init
    : > "$tmp" 2>/dev/null
    cat /dev/kmsg > "$tmp" 2>/dev/null &
    p=$!
    sleep 2
    kill "$p" 2>/dev/null
    n="$(tail -n1 "$tmp" 2>/dev/null | cut -d, -f2)"
    rm -f "$tmp" 2>/dev/null
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s' "$n"
}

# 别的采集器实例(排除自身) —— 防止重复订阅。
# 必须用**严格前缀**匹配: 任何"命令行里提到过 ikaudit collect 的 shell"都可能被子串匹配骗到
# (曾经因此把真正的采集器判成重复, 直接退出)。
au_collect_others() {
    local bin p pid c me
    bin="$(P /etc/mnt/.boot/bin/ikaudit)"
    # 注意: 本函数常被 $(...) 调用, 那种子 shell 会**继承**采集器的 cmdline,
    # 而 $$ 在子 shell 里仍是父 pid —— 必须用 BASHPID 才排除得掉自己。
    me="${BASHPID:-$$}"
    for p in /proc/[0-9]*/cmdline; do
        [ -r "$p" ] || continue
        pid="${p#/proc/}"; pid="${pid%/cmdline}"
        [ "$pid" = "$me" ] && continue
        c="$(tr '\0' ' ' < "$p" 2>/dev/null)"
        case "$c" in
            "/bin/bash $bin collect "*|"$bin collect "*|"bash $bin collect "*|"sh $bin collect "*)
                printf '%s ' "$pid" ;;
        esac
    done
    return 0
}

# 每 60 秒(无事件时)做一次维护: 日志规模 + 子进程存活
au_collect_maintain() {
    au_rotate
    au_pid_running "$AU_CT_PID" || { au_event WARN "collect.ct" "conntrack 事件流已断开, 重启"; au_ct_spawn; }
    au_pid_running "$AU_KM_PID" || { au_event WARN "collect.kmsg" "内核日志读取已断开, 重启"; au_km_spawn; }
    return 0
}

au_collect_cleanup() {
    au_log_rule_off
    kill "$AU_CT_PID" "$AU_KM_PID" 2>/dev/null
    [ -n "${AU_FIFO:-}" ] && rm -f "$AU_FIFO" 2>/dev/null
    return 0
}

# 采集主循环(常驻; 由 au_collect_start 后台拉起)
au_collect() {
    local line holder
    au_init
    au_rotate

    # 独占: pid 文件里已经有别的活采集器就不再起(不用扫 /proc ——
    # 命令替换/分组子 shell 会继承本进程 cmdline, 扫描必然把自己算进去)
    holder=""
    test -f "$AU_COLLECT_PIDFILE" && read -r holder < "$AU_COLLECT_PIDFILE"
    if [ -n "$holder" ] && [ "$holder" != "$$" ] && au_pid_running "$holder"; then
        au_log "已有采集器在运行(pid $holder), 本次退出"
        return 0
    fi
    printf '%s\n' "$$" > "$AU_COLLECT_PIDFILE"

    AU_FIFO="$AU_STATE/collect.$$.fifo"
    rm -f "$AU_FIFO" 2>/dev/null
    mkfifo "$AU_FIFO" 2>/dev/null

    au_log_rule_on
    au_event INFO "collect.begin" "被动采集启动(conntrack 事件 + 内核封锁日志)"

    # /dev/kmsg: 记下当前最大 seq, 跳过启动前的旧记录
    AU_KMSG_SEQ="$(au_kmsg_seq_now)"

    au_ct_spawn
    au_km_spawn

    trap 'au_collect_cleanup' INT TERM EXIT
    exec 9<> "$AU_FIFO"

    while :; do
        if read -r -t 60 -u 9 line; then
            case "$line" in
                *'[NEW]'*|*'[DESTROY]'*|*'[UPDATE]'*) au_ct_event "$line" ;;
                *"$AU_LOG_TAG"*)                      au_kmsg_event "$line" ;;
            esac
        else
            au_collect_maintain
        fi
    done
}

au_collect_start() {
    local bin pid others
    au_init
    if au_collect_running; then
        au_log "采集器已在运行"
        return 0
    fi
    # 进程在跑但 pid 文件丢了(被 -9 之类): 直接认领, 不要重复起一个
    others="$(au_collect_others)"
    if [ -n "$others" ]; then
        printf '%s\n' "${others%% *}" > "$AU_COLLECT_PIDFILE"
        au_log "已有采集器在运行($others), 已认领"
        return 0
    fi
    bin="$(P /etc/mnt/.boot/bin/ikaudit)"
    ( trap '' HUP; exec "$bin" collect ) >> "$(au_dir)/collect.log" 2>&1 &
    pid=$!
    printf '%s\n' "$pid" > "$AU_COLLECT_PIDFILE"
    sleep 1
    if au_collect_running; then
        au_event INFO "collect.start" "被动采集器已启动 (pid $pid)"
        return 0
    fi
    au_event WARN "collect.start" "被动采集器启动失败"
    rm -f "$AU_COLLECT_PIDFILE"
    return 1
}

au_collect_stop() {
    local pid="" p c
    au_init
    test -f "$AU_COLLECT_PIDFILE" && read -r pid < "$AU_COLLECT_PIDFILE"
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null
        sleep 1
        au_pid_running "$pid" && kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$AU_COLLECT_PIDFILE"

    # 兜底: 主进程被 -9 时 trap 不会执行, 这里清残留的采集器/子进程/FIFO 与 LOG 规则
    for p in /proc/[0-9]*/cmdline; do
        [ -r "$p" ] || continue
        c="$( { tr '\0' ' ' < "$p"; } 2>/dev/null )"
        case "$c" in
            *"conntrack -E"*|*"cat /dev/kmsg"*|*"ikaudit collect "*)
                kill -9 "${p#/proc/}" 2>/dev/null
                kill -9 "$(echo "${p#/proc/}" | cut -d/ -f1)" 2>/dev/null
                ;;
        esac
    done
    au_log_rule_off
    rm -f "$AU_STATE"/collect.*.fifo 2>/dev/null
    au_event INFO "collect.stop" "被动采集器已停止"
    return 0
}

# ---------------------------------------------------------------- 主动探测(手动)

au_tcp_probe() {
    local ip="$1" port="$2" pid
    ( exec 3<>"/dev/tcp/$ip/$port" ) 2>/dev/null &
    pid=$!
    ( sleep 3; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    if wait "$pid" 2>/dev/null; then
        return 0
    fi
    return 1
}

# 云端连通性自检(手动触发; probe=1 时才由 cron 定时执行)
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

# ---------------------------------------------------------------- 报告

# 封锁规则累计命中包数
au_blocked_hits() {
    { iptables -nvx -L OUTPUT 2>/dev/null; iptables -nvx -L FORWARD 2>/dev/null; } | \
        awk '/ikuai_blk|multiport/{s+=$1} END{print s+0}'
    return 0
}

# 生成报告(返回 0=正常 1=异常)
au_report() {
    local audit_on collect_on xt_ok n_conn n_dns n_block ipset rules hits verdict=0
    au_init
    au_rotate

    audit_on="$(au_flag audit 0)"
    au_collect_running && collect_on=1 || collect_on=0
    au_xt_log_ok && xt_ok=1 || xt_ok=0
    n_conn="$(au_count "$(au_file conn)" 'conn\.(NEW|DESTROY)')"
    n_dns="$(au_count "$(au_file dns)" 'dns\.query')"
    n_block="$(au_count "$(au_file block)" 'block\.hit')"
    ipset="$(ipset -L "$IPSET_NAME" 2>/dev/null | grep -c '^[0-9]')"
    rules="$(iptables -S 2>/dev/null | grep -c ikuai_blk)"
    hits="$(au_blocked_hits)"
    case "$ipset" in ''|*[!0-9]*) ipset=0 ;; esac
    case "$rules" in ''|*[!0-9]*) rules=0 ;; esac

    if [ "$audit_on" = "1" ] && [ "$collect_on" = 0 ]; then verdict=1; fi
    [ "$ipset" -gt 0 ] || verdict=1
    [ "$rules" -ge 2 ] || verdict=1

    {
        echo "ikguard 被动采集报告 $(au_stamp)"
        echo "-------------------------------------------------"
        echo "采集器   : $([ "$collect_on" = 1 ] && echo 运行中 || echo 未运行)   (开关 audit=$audit_on, 默认关闭)"
        echo "事件源   : conntrack 事件流 $([ "$collect_on" = 1 ] && echo 已订阅 || echo 未订阅)"
        echo "           内核封锁日志 $([ "$xt_ok" = 1 ] && echo 可用 || echo '不可用(iptables 无 -j LOG)')"
        echo "今日事件 : 连接 $n_conn 条 / DNS(dport=53) $n_dns 条 / 封锁命中 $n_block 条"
        echo "封锁     : ipset $IPSET_NAME $ipset 条 / 规则 $rules 条 / 命中包数 $hits 包"
        echo "日志     : $(au_dir) 保留 $AU_KEEP_DAYS 天 / 单文件上限 $AU_MAX_FILE 字节"
        echo "-------------------------------------------------"
        if [ "$verdict" = 1 ]; then
            echo "结论: 异常(采集器未按开关运行, 或封锁规则/ipset 缺失)"
        else
            echo "结论: 正常"
        fi
    } > "$(au_dir)/$AU_REPORT" 2>/dev/null
    cat "$(au_dir)/$AU_REPORT" 2>/dev/null

    return "$verdict"
}

# ---------------------------------------------------------------- 定时任务(仅可选自检)

au_probe_cron_on() { test "$(au_flag probe 0)" = "1"; }

# 移除本框架写入的定时任务
au_remove_cron() {
    local cron_dir root bin
    cron_dir="$(P /etc/crontabs/cron.d)"
    root="$(P /etc/crontabs/root)"
    bin="$(P /etc/mnt/.boot/bin/ikaudit)"
    if [ -f "$root" ]; then
        grep -v "$bin" "$root" > "$root.ikguard.tmp" 2>/dev/null || :
        mv -f "$root.ikguard.tmp" "$root" 2>/dev/null
    fi
    rm -f "$cron_dir/ikguard_audit" "$cron_dir/ikguard_report" "$cron_dir/ikguard_probe" 2>/dev/null
    return 0
}

# 重建定时任务: 采集是常驻进程, **不写任何 cron**;
# 只有 probe=1(定时自检)才写一条。
au_install_cron() {
    local root bin probe_state
    root="$(P /etc/crontabs/root)"
    bin="$(P /etc/mnt/.boot/bin/ikaudit)"
    mkdir -p "$(dirname "$root")" 2>/dev/null
    au_remove_cron

    if au_probe_cron_on; then
        printf '%s * * * * %s probe >/dev/null 2>&1\n' "$AU_PROBE_CRON" "$bin" >> "$root"
        printf '%s * * * * %s probe >/dev/null 2>&1\n' "$AU_PROBE_CRON" "$bin" > "$(P /etc/crontabs/cron.d/ikguard_probe)"
        probe_state="$AU_PROBE_CRON"
    else
        probe_state="未启用(probe=0)"
    fi
    au_event INFO "cron.install" "定时任务已重建(采集为常驻进程, 不占 cron; 定时自检 $probe_state)"

    if [ -f "$(P /usr/ikuai/include/crond.sh)" ]; then
        ( . "$(P /usr/ikuai/include/crond.sh)"; crond_commit >/dev/null 2>&1 )
    fi
    return 0
}
