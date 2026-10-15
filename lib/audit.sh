#!/bin/bash
#
# 审计/取证库 —— **被动采集**(事件驱动, 不用 cron, 不做轮询)
#
# 设计要点:
#   1) 只有一个常驻采集器(bin/ikaudit collect), 由开关 audit 控制启停:
#        audit=1 开机自动拉起、=0 停止; 默认关闭(install.sh 写入 audit=0)
#   2) 事件全部来自内核推送, 没有任何定时轮询:
#        conntrack -E   连接事件([NEW]/[DESTROY]); dport=53 的另存为 DNS 事件
#   3) 封锁只走 /etc/hosts + 空壳(见 lib/backdoor.sh), 不碰 iptables —— 所以没有
#      "封锁命中"事件源; 被禁组件的启动尝试由空壳自己记入 stub.log(零代价的启动监控)
#
# 日志(持久分区 /etc/log, 重启不丢):
#   boot.log            框架日志
#   audit-YYYYMMDD.log  结构化事件
#   conn-YYYYMMDD.log   连接事件
#   dns-YYYYMMDD.log    DNS(dport=53)事件
#   stub.log            被禁组件的启动尝试(空壳记录, 见 lib/backdoor.sh)
#   report.txt          最近一次报告
#
# 依赖: common.sh 的 P()/log()/get_flag()

AU_DIR="${AU_DIR:-/etc/log/ikguard}"
AU_KEEP_DAYS="${AU_KEEP_DAYS:-3}"           # 时间周期: 日志保留天数
AU_MAX_TOTAL="${AU_MAX_TOTAL:-314572800}"   # 大小限制: 日志目录总量(默认 300MB)
AU_MAX_FILE="${AU_MAX_FILE:-10485760}"      # 大小限制: 单个日志文件(默认 10MB)
AU_STATE="/tmp/.ikaudit"
AU_REPORT="report.txt"
AU_COLLECT_PIDFILE="$AU_STATE/collect.pid"

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
    local f="$1" pat="$2" n
    [ -f "$f" ] || { printf '0'; return 0; }
    # 注意: grep -c 无匹配时**自己就会打印 0**(退出码 1), 再 `|| printf 0` 会打出两行 "0\n0",
    # 报告/接口里就会出现两个值。这里先取输出再收敛成纯数字。
    if [ -n "$pat" ]; then
        n="$(grep -cE "$pat" "$f" 2>/dev/null)"
    else
        n="$(grep -c . "$f" 2>/dev/null)"
    fi
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s' "$n"
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

    for f in audit conn dns; do
        au_cap_file "$(au_file "$f")" "$AU_MAX_FILE"
    done
    au_cap_file "$(au_dir)/boot.log" "$AU_MAX_FILE"
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

# 每 60 秒(无事件时)做一次维护: 日志规模 + 事件流存活
au_collect_maintain() {
    au_rotate
    au_pid_running "$AU_CT_PID" || { au_event WARN "collect.ct" "conntrack 事件流已断开, 重启"; au_ct_spawn; }
    return 0
}

au_collect_cleanup() {
    kill "$AU_CT_PID" 2>/dev/null
    [ -n "${AU_FIFO:-}" ] && rm -f "$AU_FIFO" 2>/dev/null
    return 0
}

# 采集主循环(常驻; 由 au_collect_start 后台拉起)
au_collect() {
    local line holder n=0
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

    au_event INFO "collect.begin" "被动采集启动(conntrack 事件)"

    command -v conntrack >/dev/null 2>&1 || {
        au_event WARN "collect.ct" "设备上没有 conntrack, 采集器直接退出(不空转)"
        rm -f "$AU_COLLECT_PIDFILE" 2>/dev/null
        return 1
    }
    au_ct_spawn

    trap 'au_collect_cleanup' INT TERM EXIT
    exec 9<> "$AU_FIFO"

    # 维护既要能被"60 秒没事件"触发, 也要能被"事件很多"触发 —— 否则流量一直不断时 read 永不
    # 超时, au_rotate 永远轮不到, 日志会无上限长下去(撑爆 /etc/log)
    while :; do
        if read -r -t 60 -u 9 line; then
            case "$line" in
                *'[NEW]'*|*'[DESTROY]'*|*'[UPDATE]'*) au_ct_event "$line" ;;
            esac
            n=$((n + 1))
            [ $((n % 500)) -eq 0 ] && au_collect_maintain
        else
            n=0
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

    # 兜底: 主进程被 -9 时 trap 不会执行, 这里清残留的事件流子进程与 FIFO
    for p in /proc/[0-9]*/cmdline; do
        [ -r "$p" ] || continue
        c="$( { tr '\0' ' ' < "$p"; } 2>/dev/null )"
        case "$c" in
            *"conntrack -E"*|*"ikaudit collect "*)
                kill -9 "$(echo "${p#/proc/}" | cut -d/ -f1)" 2>/dev/null
                ;;
        esac
    done
    rm -f "$AU_STATE"/collect.*.fifo 2>/dev/null
    au_event INFO "collect.stop" "被动采集器已停止"
    return 0
}

# ---------------------------------------------------------------- 报告

# 生成报告(返回 0=正常 1=异常)
au_report() {
    local audit_on collect_on n_conn n_dns verdict=0
    au_init
    au_rotate

    audit_on="$(au_flag audit 0)"
    au_collect_running && collect_on=1 || collect_on=0
    n_conn="$(au_count "$(au_file conn)" 'conn\.(NEW|DESTROY)')"
    n_dns="$(au_count "$(au_file dns)" 'dns\.query')"

    if [ "$audit_on" = "1" ] && [ "$collect_on" = 0 ]; then verdict=1; fi

    {
        echo "ikguard 被动采集报告 $(au_stamp)"
        echo "-------------------------------------------------"
        echo "采集器   : $([ "$collect_on" = 1 ] && echo 运行中 || echo 未运行)   (开关 audit=$audit_on, 默认关闭)"
        echo "事件源   : conntrack 事件流 $([ "$collect_on" = 1 ] && echo 已订阅 || echo 未订阅)"
        echo "今日事件 : 连接 $n_conn 条 / DNS(dport=53) $n_dns 条"
        echo "启动监控 : stub.log(空壳记录被禁组件的启动尝试, 见 lib/backdoor.sh)"
        echo "日志     : $(au_dir) 保留 $AU_KEEP_DAYS 天 / 单文件上限 $AU_MAX_FILE 字节"
        echo "-------------------------------------------------"
        if [ "$verdict" = 1 ]; then
            echo "结论: 异常(采集器未按开关运行)"
        else
            echo "结论: 正常"
        fi
    } > "$(au_dir)/$AU_REPORT" 2>/dev/null
    cat "$(au_dir)/$AU_REPORT" 2>/dev/null

    return "$verdict"
}

# ---------------------------------------------------------------- 历史遗留清理

# 移除旧版本写入的 ikaudit 定时任务(本版本不写任何 cron, 只做清理)
# 按 "bin/ikaudit" 匹配: 真机遗留行是 /etc/mnt/.boot/bin/ikaudit ...,
# 不会误伤 /usr/ikuai/script/ikaudit_update.sh(不含 bin/ikaudit)
au_remove_cron() {
    local cron_dir root tmp rc
    cron_dir="$(P /etc/crontabs/cron.d)"
    root="$(P /etc/crontabs/root)"
    if [ -f "$root" ]; then
        # 与 bd_remove_guard 同一套写法: grep 成功才换; 只剩本行则清空; grep 本身出错就原样保留
        # (原来写成 `grep ... || :` 后无条件 mv, grep 出错时会用半截文件覆盖掉整个 crontab)
        tmp="$root.ikguard.$$"
        rc=0
        grep -v "bin/ikaudit" "$root" > "$tmp" 2>/dev/null || rc=$?
        if [ "$rc" = 0 ]; then
            mv -f "$tmp" "$root" 2>/dev/null
        elif [ "$rc" = 1 ]; then
            rm -f "$tmp" 2>/dev/null
            : > "$root" 2>/dev/null
        else
            rm -f "$tmp" 2>/dev/null
        fi
    fi
    rm -f "$cron_dir/ikguard_audit" "$cron_dir/ikguard_report" "$cron_dir/ikguard_probe" 2>/dev/null
    return 0
}
