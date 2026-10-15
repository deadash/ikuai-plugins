#!/bin/bash

# 框架功能库: SSH 加固 —— ① 封禁公网访问 SSH ② 按来源 IP 一键封禁 ③ 读 SSH 登录/注销/失败日志
#
# 全部基于官方现成机制与官方数据, 不碰内核、不装常驻(只在开机与"重新应用"时落规则):
#
# 真机核实(iKuai 3.7.16 x64):
#   * SSH 服务是 dropbear, 由官方 /usr/ikuai/script/remote_control.sh __set_sshd 拉起:
#       killall -q dropbear; env - PATH=$PATH dropbear -p $sshd_port
#     它监听 0.0.0.0(所有网卡), 而官方**没有**对 SSH 做任何 WAN 侧限制 —— 22 不在 iKuai 的
#     DROP_T_PORTS_WAN_IN 集合里(该集合只有 53 54 680~690 700 1900), WEBACL 只管 web 端口。
#     所以 open_sshd=1 时只要上游把端口映射到公网, 任何人都能连上来爆破。
#   * "公网网卡"官方自己是怎么判断的: /usr/ikuai/include/iptables.sh 里
#       IPT_WAN_NO_VPN_IFACE_IN="-m ifaces --ifaces wan*,vwan*,adsl* --dir in"
#     用的是 iKuai 自研的 iptables 扩展模块 ifaces, 按**接口名前缀**一次匹配所有
#     WAN/VPN/ADSL 网卡(多拨/多 WAN/PPPoE 一网打尽), 比看路由表或默认网关可靠得多。
#     本库直接读官方这行定义(不 source, 避免副作用), 固件升级自动跟随。
#   * 官方对 WEB 就是这么管的: remote_control.sh __set_wanweb 维护 WEBACL 链,
#       -A WEBACL -p tcp -m ifaces --ifaces wan,vwan,adsl --dir in \
#           -m set --match-set Linux_webport_default dst -j DROP
#     本库给 SSH 补一条同款链条(自建链, 不动官方 WEBACL, 免得被官方 -F WEBACL 冲掉)。
#   * 所有规则都带 -m conntrack --ctstate NEW: iKuai 的 INPUT 是"默认 ACCEPT + 靶向 DROP",
#     没有 ESTABLISHED 放行规则, 不限 NEW 会把正在操作的管理会话一起打断(自己把自己踢下线)。
#   * SSH 日志官方已经在记: /usr/sbin/iksyslogd(Lua) 把 dropbear 的 syslog 落进
#     /etc/log/syslog.db 的 messages 表(process='dropbear[pid]'), 持久盘、重启不丢,
#     成功/失败/注销都有, 详见 sg_log_rows()。

SG_SSH_BAN_LIST="/etc/mnt/ikguard/ssh-ban.list"   # 封禁名单(持久盘; 开机由 scripts/07 重放)
SG_PUB_MARK="/etc/mnt/ikguard/sshguard.on"       # "公网封禁曾经生效"的标记(关掉开关时要撤规则)
SG_WAN_CHAIN="IKG_SSH_WAN"                       # 公网访问 SSH 的封禁链(wan/vwan/adsl 入向 NEW)
SG_BAN_CHAIN="IKG_SRC_BAN"                       # 来源 IP 封禁链(只挡 SSH 端口, 留 Web 救援通道)
SG_OFFICIAL_IPT="/usr/ikuai/include/iptables.sh" # 官方 iptables 定义(取公网网卡参数)
SG_DB_CONF="/etc/mnt/ikuai/config.db"            # 官方配置库(读 open_sshd/sshd_port)
SG_DB_SYSLOG="/etc/log/syslog.db"                # 官方日志库(messages 表 = dropbear 日志)
SG_WAN_ARG_FALLBACK="-m ifaces --ifaces wan,vwan,adsl --dir in"

sg_has() { command -v "$1" >/dev/null 2>&1; }

# 写开关(boot_args): 键不存在时补上(common.sh 的 enable/disable 只改已存在的键)
sg_flag_set() {
    local k="$1" v="$2"
    test -f "$(P "$BOOT_ARGS")" || : > "$(P "$BOOT_ARGS")"
    if grep -q "^$k=" "$(P "$BOOT_ARGS")" 2>/dev/null; then
        sed -i "s|^$k=.*|$k=$v|" "$(P "$BOOT_ARGS")"
    else
        echo "$k=$v" >> "$(P "$BOOT_ARGS")"
    fi
}

sg_ipt()  { iptables -w "$@" 2>/dev/null; }
sg_ipt6() { sg_has ip6tables || return 1; ip6tables -w "$@" 2>/dev/null; }

# ---------------------------------------------------------------- 读官方配置

# 官方 SSH 端口(remote_control.sshd_port; 取不到就按 22)
sg_ssh_port() {
    local p=""
    if sg_has sqlite3; then
        p="$(sqlite3 "$(P "$SG_DB_CONF")" \
            "select sshd_port from remote_control where id=1" 2>/dev/null | tr -dc '0-9')"
    fi
    case "$p" in ''|0) p=22 ;; esac
    printf '%s' "$p"
}

# 官方 SSH 开关(remote_control.open_sshd): 1=开
sg_ssh_open() {
    local v=""
    if sg_has sqlite3; then
        v="$(sqlite3 "$(P "$SG_DB_CONF")" \
            "select open_sshd from remote_control where id=1" 2>/dev/null | tr -dc '0-9')"
    fi
    printf '%s' "${v:-0}"
}

# 官方"公网网卡"参数: 直接取官方定义; 取不到用等价的字面量
sg_wan_arg() {
    local a=""
    a="$(sed -n 's/^IPT_WAN_NO_VPN_IFACE_IN="\(.*\)"$/\1/p' "$(P "$SG_OFFICIAL_IPT")" 2>/dev/null | head -n1)"
    printf '%s' "${a:-$SG_WAN_ARG_FALLBACK}"
}

# ---------------------------------------------------------------- 规则(公网访问 SSH)

# 应用: 建链 -> 只挡 wan/vwan/adsl 入向的新连接 -> 挂到 INPUT 最前(幂等)
sg_pub_on() {
    local port wan_arg
    port="$(sg_ssh_port)"
    wan_arg="$(sg_wan_arg)"

    sg_ipt -F "$SG_WAN_CHAIN" 2>/dev/null
    sg_ipt -N "$SG_WAN_CHAIN" 2>/dev/null
    # shellcheck disable=SC2086  # $wan_arg 需要按空格拆成多个参数
    sg_ipt -A "$SG_WAN_CHAIN" -p tcp $wan_arg -m conntrack --ctstate NEW \
        --dport "$port" -j DROP
    sg_ipt -C INPUT -j "$SG_WAN_CHAIN" 2>/dev/null || sg_ipt -I INPUT 1 -j "$SG_WAN_CHAIN"

    if sg_has ip6tables; then
        sg_ipt6 -F "$SG_WAN_CHAIN" 2>/dev/null
        sg_ipt6 -N "$SG_WAN_CHAIN" 2>/dev/null
        # shellcheck disable=SC2086
        sg_ipt6 -A "$SG_WAN_CHAIN" -p tcp $wan_arg -m conntrack --ctstate NEW \
            --dport "$port" -j DROP
        sg_ipt6 -C INPUT -j "$SG_WAN_CHAIN" 2>/dev/null || sg_ipt6 -I INPUT 1 -j "$SG_WAN_CHAIN"
    fi

    mkdir -p "$(dirname "$(P "$SG_PUB_MARK")")" 2>/dev/null
    : > "$(P "$SG_PUB_MARK")" 2>/dev/null
    log "[ssh] 已封禁公网访问 SSH: 端口=$port, 公网网卡参数=[$wan_arg], 只拦新连接"
    return 0
}

# 撤销: 摘掉跳转 + 清链接删链(没有生效过就什么都不碰)
sg_pub_off() {
    [ -f "$(P "$SG_PUB_MARK")" ] || return 0
    while sg_ipt -C INPUT -j "$SG_WAN_CHAIN" 2>/dev/null; do
        sg_ipt -D INPUT -j "$SG_WAN_CHAIN" 2>/dev/null || break
    done
    sg_ipt -F "$SG_WAN_CHAIN" 2>/dev/null
    sg_ipt -X "$SG_WAN_CHAIN" 2>/dev/null
    while sg_ipt6 -C INPUT -j "$SG_WAN_CHAIN" 2>/dev/null; do
        sg_ipt6 -D INPUT -j "$SG_WAN_CHAIN" 2>/dev/null || break
    done
    sg_ipt6 -F "$SG_WAN_CHAIN" 2>/dev/null
    sg_ipt6 -X "$SG_WAN_CHAIN" 2>/dev/null
    rm -f "$(P "$SG_PUB_MARK")" 2>/dev/null
    log "[ssh] 已解除公网访问 SSH 的封禁"
    return 0
}

# 公网封禁是否生效(链已挂到 INPUT 且里面有 DROP 规则)
sg_pub_state() {
    sg_ipt -C INPUT -j "$SG_WAN_CHAIN" 2>/dev/null || return 1
    sg_ipt -S "$SG_WAN_CHAIN" 2>/dev/null | grep -q -- "-j DROP" || return 1
    return 0
}

# ---------------------------------------------------------------- 规则(来源 IP 封禁)

sg_ban_chain_init() {
    sg_ipt -N "$SG_BAN_CHAIN" 2>/dev/null
    sg_ipt -C INPUT -j "$SG_BAN_CHAIN" 2>/dev/null || sg_ipt -I INPUT 1 -j "$SG_BAN_CHAIN"
    sg_has ip6tables && sg_ipt6 -N "$SG_BAN_CHAIN" 2>/dev/null
    return 0
}

# 粗校验: 只收 IPv4/IPv6 字面量(拒绝把 shell 元字符带进命令行)
sg_ip_ok() {
    case "$1" in
        *[!0-9a-fA-F:.]*|'') return 1 ;;
    esac
    case "$1" in
        *:*:*)    ;;   # IPv6
        *.*.*.*)  ;;   # IPv4
        *) return 1 ;;
    esac
    return 0
}

sg_is_v6() { case "$1" in *:*) return 0 ;; *) return 1 ;; esac; }

# 规范化: 去掉 "ip:端口" 的端口部分(IPv4); IPv6/裸 IP 原样
sg_ip_norm() {
    local ip="$1"
    case "$ip" in
        ''|*:*:*:*) printf '%s' "$ip" ;;
        *:*)        printf '%s' "${ip%%:*}" ;;
        *)          printf '%s' "$ip" ;;
    esac
}

sg_ban_present() {
    if sg_is_v6 "$1"; then
        sg_ipt6 -C "$SG_BAN_CHAIN" -s "$1" -p tcp --dport "$(sg_ssh_port)" -j DROP 2>/dev/null
    else
        sg_ipt -C "$SG_BAN_CHAIN" -s "$1" -p tcp --dport "$(sg_ssh_port)" -j DROP 2>/dev/null
    fi
}

sg_ban_rule_add() {
    sg_ban_present "$1" && return 0
    if sg_is_v6 "$1"; then
        sg_ipt6 -I "$SG_BAN_CHAIN" 1 -s "$1" -p tcp --dport "$(sg_ssh_port)" -j DROP
    else
        sg_ipt -I "$SG_BAN_CHAIN" 1 -s "$1" -p tcp --dport "$(sg_ssh_port)" -j DROP
    fi
}

sg_ban_rule_del() {
    if sg_is_v6 "$1"; then
        sg_ipt6 -D "$SG_BAN_CHAIN" -s "$1" -p tcp --dport "$(sg_ssh_port)" -j DROP 2>/dev/null
    else
        sg_ipt -D "$SG_BAN_CHAIN" -s "$1" -p tcp --dport "$(sg_ssh_port)" -j DROP 2>/dev/null
    fi
}

# 封禁一个来源 IP(立即生效) + 记名单
sg_ban_add() {
    local ip note="${2:-手工封禁}"
    ip="$(sg_ip_norm "$1")"
    sg_ip_ok "$ip" || { echo "IP 格式不对: $1"; return 1; }
    sg_ban_chain_init
    sg_ban_rule_add "$ip"
    if ! grep -q "^$ip|" "$(P "$SG_SSH_BAN_LIST")" 2>/dev/null; then
        mkdir -p "$(dirname "$(P "$SG_SSH_BAN_LIST")")" 2>/dev/null
        printf '%s|%s|%s\n' "$ip" "$(date '+%Y-%m-%d %H:%M:%S')" "$note" \
            >> "$(P "$SG_SSH_BAN_LIST")" 2>/dev/null
    fi
    log "[ssh] 已封禁来源 IP: $ip ($note)"
    printf '%s' "$ip"
}

# 解除封禁
sg_ban_del() {
    local ip
    ip="$(sg_ip_norm "$1")"
    sg_ip_ok "$ip" || { echo "IP 格式不对: $1"; return 1; }
    sg_ban_rule_del "$ip"
    if [ -f "$(P "$SG_SSH_BAN_LIST")" ]; then
        grep -v "^$ip|" "$(P "$SG_SSH_BAN_LIST")" > "$(P "$SG_SSH_BAN_LIST").tmp" 2>/dev/null
        mv "$(P "$SG_SSH_BAN_LIST").tmp" "$(P "$SG_SSH_BAN_LIST")" 2>/dev/null
    fi
    log "[ssh] 已解除封禁: $ip"
    printf '%s' "$ip"
}

# 清空名单 + 清链
sg_ban_clear() {
    local n=0
    if [ -f "$(P "$SG_SSH_BAN_LIST")" ]; then
        n="$(grep -c . "$(P "$SG_SSH_BAN_LIST")" 2>/dev/null)"
        : > "$(P "$SG_SSH_BAN_LIST")" 2>/dev/null
    fi
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    sg_ipt -F "$SG_BAN_CHAIN" 2>/dev/null
    sg_ipt6 -F "$SG_BAN_CHAIN" 2>/dev/null
    log "[ssh] 已清空封禁名单($n 条)"
    printf '%s' "$n"
}

# 链上现有封禁条数
sg_ban_count() {
    local n
    n="$(sg_ipt -S "$SG_BAN_CHAIN" 2>/dev/null | grep -c -- "-j DROP")"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s' "$n"
}

# 名单(ip|时间|原因; 一行一条, 前端按 | 拆开)
sg_ban_list() {
    [ -f "$(P "$SG_SSH_BAN_LIST")" ] && grep . "$(P "$SG_SSH_BAN_LIST")" 2>/dev/null
    return 0
}

# 按持久名单重放规则(开机/重新应用时调用)
sg_ban_replay() {
    local ip _rest n=0
    sg_ban_chain_init
    [ -s "$(P "$SG_SSH_BAN_LIST")" ] || return 0
    while IFS='|' read -r ip _rest; do
        [ -n "$ip" ] || continue
        sg_ip_ok "$ip" || continue
        sg_ban_rule_add "$ip" && n=$((n + 1))
    done < "$(P "$SG_SSH_BAN_LIST")"
    [ "$n" -gt 0 ] && log "[ssh] 已重放封禁名单: $n 条"
    return 0
}

# ---------------------------------------------------------------- 应用 / 自检

# 开机与"重新应用"都走这里: 公网封禁跟开关走; 名单始终重放(显式封禁要跨重启保持)。
# 注意惰性: 没开过公网封禁(无标记)且名单为空时, 一次 iptables 都不碰。
sg_apply() {
    if [ -s "$(P "$SG_SSH_BAN_LIST")" ] || [ -f "$(P "$SG_PUB_MARK")" ]; then
        sg_ban_replay
    fi
    if is_enabled sshguard; then
        sg_pub_on
    else
        sg_pub_off
    fi
    return 0
}

# 自检文本(Web"立即自检"与 bin/sshguard 共用)
sg_check_text() {
    local port wan_arg bann pub
    port="$(sg_ssh_port)"
    wan_arg="$(sg_wan_arg)"
    bann="$(sg_ban_count)"
    if sg_pub_state; then pub="已封禁(仅 wan/vwan/adsl 入向的新连接)"; else pub="未封禁(公网可直连 SSH)"; fi
    printf '=== SSH 加固自检 %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '1) SSH 服务: dropbear 端口=%s, 官方开关 open_sshd=%s\n' "$port" "$(sg_ssh_open)"
    printf '2) 公网访问 SSH: %s\n' "$pub"
    printf '   公网网卡参数(取官方定义): %s\n' "$wan_arg"
    printf '3) 来源 IP 封禁: %s 条(只挡该 IP 访问 SSH 端口, Web 不受影响, 便于随时解封)\n' "$bann"
    if [ "$bann" != 0 ]; then
        sg_ban_list | sed 's/^/     /'
    fi
    printf '4) SSH 日志来源: %s (messages 表内 process=dropbear*)\n' "$(P "$SG_DB_SYSLOG")"
    return 0
}

# ---------------------------------------------------------------- SSH 日志(官方 syslog 库)

# 读官方 syslog.db 里的 dropbear 事件, 输出 TSV: 时间 <TAB> 事件 <TAB> 账号 <TAB> 来源IP <TAB> 结果
#   result: ok(登录成功) / fail(失败) / info(连接、注销)
# 数据是官方 iksyslogd 已经落库的, 我们不额外采一份: 不常驻、不占 cron、不占额外空间。
sg_log_rows() {
    local n="${1:-200}" db
    case "$n" in ''|*[!0-9]*) n=200 ;; esac
    [ "$n" -gt 1000 ] && n=1000
    db="$(P "$SG_DB_SYSLOG")"
    [ -f "$db" ] || return 0
    sg_has sqlite3 || return 0
    # 用 char(9) 自己拼出 TSV: 不依赖 sqlite3 命令行选项(设备上是 3.8.11 的老 CLI)
    sqlite3 "$db" \
        "select datetime(timestamp,'unixepoch','localtime')||char(9)||content from messages \
         where process like 'dropbear%' order by id desc limit $n" 2>/dev/null | \
    tr -d "\047" | \
    awk -F'\t' '
        function strip_ip(s) { sub(/^</, "", s); sub(/>.*$/, "", s); sub(/:[0-9]+$/, "", s); return s }
        {
            ts = $1
            c = $0
            sub(/^[^\t]*\t/, "", c)
            ip = ""; user = ""; ev = ""; res = "info"

            if (match(c, /from <[^>]+>/))    ip = strip_ip(substr(c, RSTART + 5, RLENGTH - 5))
            else if (match(c, /from [^ ]+/)) { ip = substr(c, RSTART + 5, RLENGTH - 5); sub(/:[0-9]+$/, "", ip) }

            if (match(c, /for [^ ]+ from/))  user = substr(c, RSTART + 4, RLENGTH - 9)
            else if (match(c, /\([^)]+\) from/)) user = substr(c, RSTART + 1, RLENGTH - 7)

            if (c ~ /Pubkey.*succeeded/)           { ev = "登录成功(密钥)"; res = "ok" }
            else if (c ~ /auth succeeded for/)     { ev = "登录成功(密码)"; res = "ok" }
            else if (c ~ /attempt/)                { ev = "登录失败(口令错误)"; res = "fail" }
            else if (c ~ /^Child connection/)      { ev = "建立连接";   res = "info" }
            else if (c ~ /^Exit before auth/)      { ev = "未认证断开"; res = "info" }
            else if (c ~ /^Exit /)                 { ev = "注销断开";   res = "info" }
            else if (c ~ /nonexistent user/)       { ev = "用户名不存在"; res = "fail" }
            else if (c ~ /no auth methods/)        { ev = "认证失败";   res = "fail" }
            else                                   { ev = "其它";       res = "info" }

            printf "%s\t%s\t%s\t%s\t%s\n", ts, ev, user, ip, res
        }'
    return 0
}
