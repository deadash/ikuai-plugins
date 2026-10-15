#!/bin/bash
#
# 后门 & 云端更新通道 禁用库
#
# 设计原则(目标设备固定: iKuai 3.7.16 x64, 二进制不变):
#   1) 只针对"与爱快云端通信"的进程/通道，不动路由、DHCP、NAT、QoS 等本地功能
#   2) 两层阻断: 进程层(空壳+杀灭) + 文件层(改写宿主脚本); 网络层只用 /etc/hosts 封域名
#      —— 不碰 ipset/iptables: 防火墙会被系统重建、规则丢失后无从察觉, 且影响转发
#   3) 幂等: 可重复执行。**只在开机执行一次**(boot.sh -> scripts/02), 不装任何定时器:
#      空壳启动即记一笔日志然后退出、被禁用的宿主脚本启动即 exit 0, 每分钟复查纯属空转
#   4) **空壳即监控**: 任何代码路径尝试启动被禁组件, /etc/log/ikguard/stub.log 都会记下
#      "时间 + 组件名 + 拉起者的 cmdline" —— 没有新记录 = 没有启动尝试(零代价的启动监控)
#
# 名单依据 2026-10-15 在 3.7.16 真机上逐项核实, 不存在的一律不写(不做兼容其它设备的兜底):
#   进程/二进制: /usr/sbin/{ik_rc_client,cre,pmd,dtalkd,dtalkc}
#   启动点(全部是脚本, 已逐一改写):
#     rc                          cre / cre_client / ik_rc_client / pmd / submit.lua / update_hosts.sh
#     utils/monitor_process.sh    守护重拉 pmd / ik_rc_client / cre / cre_client + ikaudit_update.sh
#     utils/update_hosts.sh       会 killall pmd && pmd(云端取址)
#     utils/submit.lua            云端指令通道(submit3)
#     dingtalk.sh -> DTalkInside/monidtalk.sh   dtalkd(钉钉云管)
#     catcherd.sh                 抓包上报(rc 里的启动行固件自己已注释)
#     ikaudit_update.sh           audit.ikuai8.com / routers.ikuai8.com:6444 的 .so/二进制下载器
#
# 依赖: 由 common.sh 提供 P()/log()，调用前需先 source

BD_MARK="ikblock"

# 需要杀灭/禁止的进程名(精确匹配; 仅本设备实际存在的 5 个)
BD_PROCS="ik_rc_client cre pmd dtalkd dtalkc"

# 按命令行关键字杀灭的脚本实例(只在开机清一次"补丁前已启动"的旧实例;
# 之后这些脚本已被禁用, 新实例启动即自灭, 不需要再扫)
BD_KILL_PATTERNS="utils/update_hosts.sh utils/submit.lua \
DTalkInside/monidtalk.sh script/dingtalk.sh script/catcherd.sh ikaudit_update.sh"

# 需要被替换成空壳的程序(本设备实际存在的 5 个云端客户端)
BD_STUBS="/usr/sbin/ik_rc_client /usr/sbin/cre /usr/sbin/pmd /usr/sbin/dtalkd /usr/sbin/dtalkc"

# 需要封锁的云端域名(写入 /etc/hosts.d 片段 -> /etc/hosts 指向 0.0.0.0)
# update.ikuai8.com = /usr/ikuai/ctrlclient/conf.json 里配的 domain(端口 443、路径
# /.services/redirect、带 token = 云端远程控制/重定向通道), v0.0.6 真机核实补入
BD_DOMAINS="302.ikuai8.com download.ikuai8.com update.ikuai8.com pkgmanager.ikuai8.com dpi.ikuai8.com \
audit.ikuai8.com routers.ikuai8.com coll.ikuai8.com dis.ikuai8.com datacollect.ikuai8.com \
ctrl1.ikuai8.com ctrl2.ikuai8.com as1.ikuai8.com as2.ikuai8.com youyu.api.ikuai8.com \
genuine.ikuai8.com iapi.ikuai8.com yun.ikuai8.com portal.ikuai8.com local.ikuai8.com \
2021.ikuai8.com bm.ikuai8.com report.ikuai8.com www.ikuai8.com ikuai8.com"

# 用户扩展域名文件(可选, 一行一条, 追加进 hosts)
BD_EXT_DOMAINS="/etc/mnt/ikblock.domains"

# 域名封锁写进 /etc/hosts.d/ 的一个片段, 而不是直接追加 /etc/hosts:
#   固件多处会**重建** /etc/hosts —— 都是 `cat /etc/hosts.d/* >/etc/hosts`:
#     basic.sh:__set_hostname()(开机必经, rc 里排在 plugins.sh 之后)
#     function/basic(网页改主机名) / pppoe_server.sh(NAS 名变更)
#   直接追加会被它们冲掉(真机首测即被 basic.sh 冲掉)。写成片段与固件同源, 上述重建都会带上。
BD_HOSTS_FRAG="/etc/hosts.d/ikblock"

# 空壳/被禁脚本共用的"启动尝试"监控日志(持久分区, 重启不丢)
BD_WATCH_LOG="/etc/log/ikguard/stub.log"

bd_log() { log "[backdoor] $*"; }

# ---------------------------------------------------------------- 进程层

# 按进程名杀灭(便宜: 每个名字一次 pidof/killall/pkill)
bd_kill_procs() {
    local p
    for p in $BD_PROCS; do
        if pidof "$p" >/dev/null 2>&1; then
            bd_log "kill 进程: $p"
            killall -q "$p" 2>/dev/null
            pkill -9 -x "$p" 2>/dev/null
        fi
    done
    return 0
}

# 一次遍历 /proc, 按命令行关键字杀灭脚本实例(每个进程只读一次 cmdline, 匹配全部关键字;
# 排除自身/SSH 会话/交互式 shell, 避免误杀维护命令)
bd_kill_pattern() {
    local dir pid cmd pat
    for dir in /proc/[0-9]*; do
        pid="${dir#/proc/}"
        case "$pid" in "$$"|"$PPID") continue ;; esac
        cmd="$( { tr '\0' ' ' < "$dir/cmdline"; } 2>/dev/null )"
        [ -n "$cmd" ] || continue
        case "$cmd" in *sshd*|*dropbear*) continue ;; esac
        case "$cmd" in *" -c "*) continue ;; esac
        for pat in $BD_KILL_PATTERNS; do
            case "$cmd" in
                *"$pat"*)
                    bd_log "kill($pat) pid=$pid cmd=$cmd"
                    kill -9 "$pid" 2>/dev/null
                    break
                    ;;
            esac
        done
    done
    return 0
}

# 杀灭后门进程(只在开机的 bd_apply 里用: 名字匹配 + 一次 /proc 命令行清扫)
bd_kill() {
    bd_kill_procs
    bd_kill_pattern
}

# 空壳与被禁脚本共用的"启动尝试"记录代码(生成进目标文件, 只能用设备上的 sh / busybox 内建)。
#   $1 = 日志里的动作文字, $2 = 组件名(生成时的字面量或运行期表达式)
#
# 开机竞态(真机 3.7.16 实测, strace 抓到 execve 现场): rc 的 start_remote_services()/
#   start_ikuai_services() 函数体、boot() 里的启动行, 都在我们打补丁之前就被 bash 解析进内存
#   了(补丁走的是 boot() 中段的 plugins.sh 钩子, 改的只是磁盘副本) —— 所以**每次开机 rc 仍会
#   按内存旧副本把这些组件拉起一遍**(已被空壳/被禁脚本拦下, 阻断效果不受影响)。
#   这类启动不是"新启动点": 判据 = 拉起者是 rc 且磁盘上的 rc 已经带补丁。
#
# 为什么要向上找祖先, 而不是直接看 $PPID: rc 的 `boot_load_async X &` 会先 fork 一个后台
#   子 shell、子 shell 再 exec 目标脚本 —— 中间那个子 shell 可能已经退出(留下 cmdline 读出来
#   是空的僵尸), 真机首测就是这么漏记/错记的。僵尸的 /proc/<pid>/stat 仍可读, 顺着它可以找到
#   真正的拉起者。取**最近的、cmdline 可读的那个祖先**作为拉起者即可: 若某脚本(如 register.sh)
#   才是真正的调用方, 它自己是活着的、会被优先读到, 不会误判成开机竞态。
#   找不到就明说: 中间进程被完全回收后子进程会被 init 收养, 走到 init 不代表 init 是拉起者,
#   所以循环里跳过 pid 1 —— 归属不了就记"(拉起者已退出, 无法归属)", 而不是伪造一个拉起者。
bd_watch_body() {
    local rc
    rc="$(P /usr/ikuai/script/rc)"
    cat <<EOF
pp=\${PPID:-0}
launcher=""
p=\$pp
i=0
while [ -n "\$p" ] && [ "\$p" != 0 ] && [ "\$p" != 1 ] && [ "\$i" -lt 4 ]; do
    launcher="\$(tr '\0' ' ' < "/proc/\$p/cmdline" 2>/dev/null)"
    [ -n "\$launcher" ] && break
    p="\$(cat "/proc/\$p/stat" 2>/dev/null)"; p="\${p#*) }"; p="\${p#* }"; p="\${p%% *}"
    launcher=""
    i=\$((i+1))
done
case "\$launcher" in
    *"$rc boot"*) grep -q "\[$BD_MARK\]" "$rc" 2>/dev/null && exit 0 ;;
esac
{ printf "[%s] [$BD_MARK] %s $1 ppid=%s\n" "\$(date "+%F %T")" "$2" "\$pp"; printf "%s\n" "\${launcher:-(拉起者已退出, 无法归属)}"; } >> $(P "$BD_WATCH_LOG") 2>/dev/null
EOF
}

# 用空壳替换程序: 启动即记一笔"谁想启动我"(零代价启动监控), 睡 1 秒防被守护进程
# 紧密循环重拉, 然后退出
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
            printf '# [%s] disabled —— 空壳: 记一笔"谁想启动我"后立即退出\n' "$BD_MARK"
            bd_watch_body "被启动(已拦截)" '${0##*/}'    # 空壳是被 exec 起来的, $0 就是组件名
            printf 'sleep 1\nexit 0\n'
        } > "$path"
        chmod +x "$path"
        bd_log "空壳替换: $f"
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

# 让整个脚本在 shebang 之后立即退出(启动尝试会先记进监控日志)
# 两个真机上踩到的点:
#   1) **不能用 awk -v 传多行片段** —— awk 会把片段里 printf 格式串中的 \n 当成真换行写进
#      文件, 生成的脚本引号不闭合, 整脚本解析失败, 连启动尝试都记不下来。改用 head/tail +
#      printf/cat 拼装, 生成物语法正确(测试里带 bash -n 断言)。
#   2) 这些脚本是被 /etc/ikcommon `source` 起来再按参数调函数的(`. $1 ""; Command $S0`),
#      所以 $0 是 /etc/ikcommon 而不是脚本名 —— 组件名必须在生成时写死字面量。
bd_neuter_script() {
    local f="$1" p tmp
    p="$(P "$f")"
    test -f "$p" || return 0
    grep -q "\[$BD_MARK\]" "$p" 2>/dev/null && return 0
    tmp="$p.$BD_MARK.tmp"
    {
        head -n 1 "$p"                  # 保留首行(#!/bin/bash /etc/ikcommon), 启动方式不变
        printf '# [%s] 已禁用: 记一笔启动尝试后立即退出\n' "$BD_MARK"
        bd_watch_body "被启动(已禁用拦截)" "$(basename "$f")"
        printf 'exit 0\n'
        tail -n +2 "$p"                 # 原内容留在 exit 之后(死代码, 便于比对/回滚)
    } > "$tmp" && mv "$tmp" "$p"
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

# monitor_process.sh: 进程守护会重新拉起后门(还会用 start-stop-daemon 拉起云端下载器)
bd_patch_monitor() {
    local f="/usr/ikuai/script/utils/monitor_process.sh" p
    p="$(P "$f")"
    test -f "$p" || { bd_log "跳过(不存在): $f"; return 0; }
    grep -q "\[$BD_MARK\]" "$p" && return 0

    bd_sed "$p" "s|^\([[:space:]]*\)cgroup_exec[[:space:]][[:space:]]*pmd[[:space:]]|\1# [$BD_MARK] cgroup_exec pmd |"
    bd_sed "$p" "s|^\([[:space:]]*\)cgroup_exec[[:space:]][[:space:]]*ik_rc_client[[:space:]]|\1# [$BD_MARK] cgroup_exec ik_rc_client |"
    bd_sed "$p" "s|^\([[:space:]]*\)cgroup_exec[[:space:]][[:space:]]*cre[[:space:]]|\1# [$BD_MARK] cgroup_exec cre |"
    bd_sed "$p" "s|^\([[:space:]]*\)cgroup_exec[[:space:]][[:space:]]*cre_client[[:space:]]|\1# [$BD_MARK] cgroup_exec cre_client |"
    # 云端审计组件下载器(audit.ikuai8.com / routers.ikuai8.com:6444), 常驻 while 循环
    bd_sed "$p" "s|^\([[:space:]]*\)start-stop-daemon[[:space:]][[:space:]]*-S[[:space:]]*-x[[:space:]]*.*ikaudit_update.sh|\1# [$BD_MARK] start-stop-daemon ikaudit_update.sh |"
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

# 更新通道: 取址脚本 / submit3 指令通道 / 云端自动升级 / 云端审计组件下载器
bd_patch_updates() {
    bd_neuter_script "/usr/ikuai/script/utils/update_hosts.sh"
    bd_neuter_script "/usr/ikuai/script/ikaudit_update.sh"
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

# ---------------------------------------------------------------- 域名封锁

# 把云端域名写进 /etc/hosts.d/ 片段, 再用固件自己的方式(`cat /etc/hosts.d/* >/etc/hosts`)重建
# /etc/hosts —— 这是唯一的网络层手段。只影响本机自己的域名解析(零进程、零防火墙规则);
# 局域网客户端的 DNS 查询不经过本机 hosts, 不受影响。根分区每次开机还原, 所以每次开机重写。
bd_block_hosts() {
    local dir p frag d hits
    dir="$(P "/etc/hosts.d")"
    p="$(P "/etc/hosts")"
    frag="$(P "$BD_HOSTS_FRAG")"
    test -d "$dir" || { bd_log "跳过(不存在): /etc/hosts.d"; return 0; }
    {
        echo "# [$BD_MARK] 屏蔽爱快云端域名(本文件由 /etc/hosts.d/* 汇总成 /etc/hosts)"
        for d in $BD_DOMAINS; do echo "0.0.0.0 $d"; done
        test -f "$(P "$BD_EXT_DOMAINS")" && \
            while IFS= read -r d; do
                case "$d" in ''|\#*) continue ;; esac
                echo "0.0.0.0 $d"
            done < "$(P "$BD_EXT_DOMAINS")"
    } > "$frag"
    cat "$dir"/* > "$p"
    hits="$(grep -c '^0\.0\.0\.0' "$p" 2>/dev/null)"
    bd_log "已写入 hosts 域名封锁: $BD_HOSTS_FRAG (重建 /etc/hosts, $hits 条)"
}

# ---------------------------------------------------------------- 对外接口

# 完整应用一次(开机调用; 需要"重新应用"时手动执行 bin/backdoor_guard 或 Web 页"重新应用")
bd_apply() {
    bd_log "开始禁用后门/更新通道"
    bd_kill
    bd_stub
    bd_patch_system
    bd_block_hosts
    bd_log "完成"
}

# 清掉历史遗留的"每分钟守卫"定时任务(旧版本装的), 并保证之后不会再装。
# 升级到本版本后第一次开机就会执行; 幂等, 没有遗留时什么都不做。
bd_remove_guard() {
    local cron_dir root guard tmp kept=0
    cron_dir="$(P "/etc/crontabs/cron.d")"
    root="$(P "/etc/crontabs/root")"
    guard="$(P "/etc/mnt/.boot/bin/backdoor_guard")"

    test -f "$cron_dir/ikblock_guard" && kept=1
    rm -f "$cron_dir/ikblock_guard" 2>/dev/null

    if [ -f "$root" ] && grep -q "backdoor_guard" "$root" 2>/dev/null; then
        # 只删守卫行(按完整路径或脚本名匹配), 其它 cron 行(iKuai 自带任务)原样保留
        tmp="$root.ikblock.tmp"
        if grep -v -e "$guard" -e "backdoor_guard" "$root" > "$tmp" 2>/dev/null; then
            mv -f "$tmp" "$root" 2>/dev/null          # 还有其它行: 换掉
        elif [ $? -eq 1 ]; then
            rm -f "$tmp" 2>/dev/null                  # 文件里只剩守卫行: 清空(而不是留下)
            : > "$root" 2>/dev/null
        else
            rm -f "$tmp" 2>/dev/null                  # grep 本身出错: 原样保留, 下次开机再试
        fi
        kept=1
    fi

    if [ "$kept" = 1 ]; then
        bd_log "已移除历史遗留的每分钟守卫(本版本改为开机一次性应用, 不装定时器)"
        if [ -f "$(P /usr/ikuai/include/crond.sh)" ]; then
            ( . "$(P /usr/ikuai/include/crond.sh)"; crond_commit >/dev/null 2>&1 )
        fi
    fi
    return 0
}
