#!/bin/bash
#
# 09_expand_mnt.sh —— 开机时执行 /etc/mnt 扩容请求(见 docs/OPERATIONS.md §1.3)
#
# 请求文件: /etc/mnt/.expand, 内容形如 "mnt_mib=1024"(由 bin/ikexpand set 写入)
#
# 全部用设备自带工具, 不引入任何自研二进制:
#   fdisk   改分区表(非交互驱动: 删掉扩展分区与第3分区, 再按目标大小重建)
#   mke2fs  按目标大小重建两个文件系统(-d 灌内容, -U 保持 UUID 不变)
#   dd/cmp  备份/回滚分区表扇区, 把文件系统写到各自的新偏移, 并回读校验
#
# 只动"属于自己"的三处: sda3(/etc/mnt)、扩展区 sda4、扩展区里第一个逻辑分区 sda5(/etc/log)。
# 其它逻辑分区(比如用户绑了业务的数据盘 sda6...)只在扩展区里**原样重建**,
# 起始/结束扇区一个字节都不挪 —— 它们的容量会压缩 /etc/log 能用的上限, 但绝不动它们的数据。
#
# 一次请求跨两次启动:
#   第 1 次: 卸载两个分区 -> 写新分区表并复核 -> 重建文件系统并写到新偏移 -> 重启
#   第 2 次: 新分区表已生效、两个文件系统已是目标大小 -> 清掉请求标记
# 为什么非得分两次: 分区表要内核重新读表才生效, 而 / 与 /etc/mnt 都是常驻挂载,
#   运行中重读分区表(BLKRRPART)只要有分区被挂载就一定 EBUSY。
# 为什么先写表再写文件系统: 表写坏了还能把备份的扇区 dd 回去(此时盘上内容一个没动),
#   反过来先写文件系统就没法回头了。
#
# 安全线(很重要):
#   * 必须**真正卸载** /etc/mnt、/etc/log 才能往它们占过的区域裸写 —— 只要还挂着,
#     内核随时可能回写脏页, 把新写的内容盖掉(实测会把新 /etc/mnt 写坏, 导致开机
#     挂不上、被固件重新格式化)。ext4 已挂载时 remount,ro 会 EBUSY, 所以先请走写者
#     再 umount。框架自己开机已从 /etc/mnt copy 到 /tmp 执行(见 boot.sh), 不挡路。
#   * 动盘之前每一步失败都直接放弃(分区表还是旧的, 系统照常能起, 下次开机重试)。
#   * 写完之后回读校验; 不过就重试, 再不过也要把分区表写完重启(否则新旧表不一致
#     更糟)。连续失败 MAX_TRIES 次自动放弃请求。
#

# 本脚本会卸载 /etc/mnt, 所以先把自己拷到内存里再从那儿跑
if [ "$0" != "/tmp/.ikexpand.sh" ]; then
    mkdir -p /tmp 2>/dev/null
    cp -f "$0" /tmp/.ikexpand.sh 2>/dev/null || exit 0
    chmod +x /tmp/.ikexpand.sh 2>/dev/null
    exec /tmp/.ikexpand.sh "$@"
fi

set -u

DEV=/dev/sda
REQ=/etc/mnt/.expand
TRIES=/etc/mnt/.expand.tries
WORK=/tmp/ikexpand
LOGF="$WORK/log.txt"
MAX_TRIES=3

mkdir -p "$WORK" 2>/dev/null
log() { echo "[expand] $*"; echo "$*" >> "$LOGF" 2>/dev/null; }

# 我们这棵树(自己/父/祖父)不能杀
GPID="$(awk '{print $4}' "/proc/$PPID/stat" 2>/dev/null)"
UNMOUNTED=0

umounts_back()
{
    [ "$UNMOUNTED" = 1 ] || return 0
    grep -qs " /etc/mnt " /proc/mounts || mount /dev/sda3 /etc/mnt 2>/dev/null
    grep -qs " /etc/log " /proc/mounts || mount /dev/sda5 /etc/log 2>/dev/null
}

# 动盘之前的失败: 恢复挂载, 保留旧表, 下次开机重来
fail() { log "!! $*"; umounts_back; log "本次放弃(保持原样), 不影响开机"; exit 0; }

# 已经写过盘之后的失败: 别把系统停在半路, 直接把表写完重启
fail_after_write() { log "!! $*"; log "已写过盘, 直接重启让系统回到一致状态"; sync; reboot 2>/dev/null; sleep 30; exit 0; }

[ -f "$REQ" ] || exit 0

mib=$(sed -n 's/^mnt_mib=//p' "$REQ" 2>/dev/null | head -1 | tr -d ' \r')
case "$mib" in ''|*[!0-9]*) log "请求文件格式不对: $REQ"; exit 0 ;; esac

cur=$(cat /sys/class/block/sda/sda3/size 2>/dev/null || echo 0)
want=$((mib * 2048))

# ---------------------------------------------------------------- 已经生效?
if [ "$cur" -ge "$want" ]; then
    log "扩容已完成: /etc/mnt = $((cur / 2048)) MiB"
    rm -f "$REQ" "$TRIES" 2>/dev/null
    if [ -f /etc/mnt/.expand.log ]; then
        {
            echo "===== 扩容完成 $(date '+%F %T') ====="
            cat /etc/mnt/.expand.log
        } >> /etc/log/ikguard/expand.log 2>/dev/null
        rm -f /etc/mnt/.expand.log 2>/dev/null
    fi
    exit 0
fi

tries=$(cat "$TRIES" 2>/dev/null || echo 0)
case "$tries" in ''|*[!0-9]*) tries=0 ;; esac
if [ "$tries" -ge "$MAX_TRIES" ]; then
    log "!! 已连续失败 $tries 次, 放弃本次扩容请求(详见 /etc/log/ikguard/expand.log)"
    rm -f "$REQ" "$TRIES" 2>/dev/null
    exit 0
fi
echo $((tries + 1)) > "$TRIES" 2>/dev/null
log "开始扩容 /etc/mnt: ${mib} MiB (当前 $((cur / 2048)) MiB), 第 $((tries + 1))/$MAX_TRIES 次"

# ---------------------------------------------------------------- 算新布局
# 设备上只有 fdisk(没有 sfdisk), 分区表就从它的输出解析:
#   /dev/sda3  114688  2213887  2099200  1G 83 Linux
part_field() {   # part_field <分区名> <列号>
    fdisk -l "$DEV" 2>/dev/null | awk -v d="/dev/$1" -v c="$2" '$1==d{print $c; exit}'
}
is_num() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; return 0; }

total=$(cat /sys/class/block/sda/size 2>/dev/null || echo 0)
mnt_start=$(part_field sda3 2)
is_num "$total" && is_num "$mnt_start" || fail "读不到分区表信息"

mnt_secs=$((mib * 2048))
mnt_end=$((mnt_start + mnt_secs - 1))
# 扩展区(/etc/log 的容器)紧跟在新的 /etc/mnt 之后, 1MiB 对齐
ext_start=$(( (mnt_end + 1 + 2047) / 2048 * 2048 ))
ext_end=$((total - 1))
p5_start=$((ext_start + 2048))

# 扩展区里除 sda5 之外还有别的逻辑分区吗(sda6 及以后, 比如用户绑了业务的数据盘)?
# 它们**原地不动**, 只在扩展区里按原起止重建; 于是 /etc/log 只能长到它们前面
# (每个逻辑分区前面还要腾出一个 EBR 扇区)。
keep_list=""
p5_end=$ext_end
for p in sda6 sda7 sda8 sda9 sda10 sda11 sda12; do
    ks=$(part_field "$p" 2)
    ke=$(part_field "$p" 3)
    is_num "$ks" && is_num "$ke" || continue
    keep_list="$keep_list $p=$ks:$ke"
    lim=$((ks - 2049))
    [ "$lim" -lt "$p5_end" ] && p5_end=$lim
done
p5_secs=$((p5_end - p5_start + 1))

if [ "$p5_secs" -lt $((256 * 2048)) ]; then
    fail "留给 /etc/log 的空间只有 $((p5_secs / 2048)) MiB, 太少(后面是不是还有别的分区占着)"
fi
if [ "$mnt_end" -ge "$p5_start" ]; then
    fail "目标大小把扩展区挤掉了(每 1MiB 对齐还要留 EBR 位置)"
fi

used_kb=$(df -k /etc/log 2>/dev/null | tail -1 | awk '{print $3}')
case "${used_kb:-}" in '' | *[!0-9]*) fail "读不到 /etc/log 用量" ;; esac
log_kb=$((p5_secs / 2))                       # 1 扇区 = 512B = 0.5KB
if [ $((log_kb * 9 / 10)) -lt $((used_kb + 64 * 1024)) ]; then
    fail "新的 /etc/log 只有 $((p5_secs / 2048)) MiB, 装不下现有内容 $((used_kb / 1024)) MiB"
fi
log "新布局: /etc/mnt=[$mnt_start,$mnt_end] (${mib}MiB)  /etc/log=[$p5_start,$p5_end] ($((p5_secs / 2048))MiB)"
[ -n "$keep_list" ] && log " 原地保留的逻辑分区:$keep_list"

# ---------------------------------------------------------------- 内容暂存到内存
# 重建文件系统要用它当源目录, 必须在卸载之前把内容读出来
rm -rf "$WORK/mnt" "$WORK/log" 2>/dev/null
mkdir -p "$WORK/mnt" "$WORK/log" 2>/dev/null || fail "建暂存目录失败"
tar -C /etc/mnt -cf - . 2>/dev/null | tar -C "$WORK/mnt" -xf - 2>/dev/null || fail "暂存 /etc/mnt 失败"
tar -C /etc/log -cf - . 2>/dev/null | tar -C "$WORK/log" -xf - 2>/dev/null || fail "暂存 /etc/log 失败"
log "已暂存到内存: /etc/mnt=$(du -sm "$WORK/mnt" 2>/dev/null | cut -f1)MiB, /etc/log=$(du -sm "$WORK/log" 2>/dev/null | cut -f1)MiB"

# ---------------------------------------------------------------- 卸载两个分区
# umount 要求"一个打开者都没有"(只读打开、cwd/exe 指向它一样会 EBUSY), 所以这里
# 不区分读写, 凡是碰过这两个分区文件的进程都请走(插件守护进程、syslog 之类)。
# 跳过 init 和我们自己这棵树(父进程 boot.sh 已从 /tmp 跑, 不再占 /etc/mnt)。
holders() {   # <挂载点> -> 持有它的 pid
    local mnt="$1" p fd l pid k
    for p in /proc/[0-9]*; do
        pid="${p#/proc/}"
        case "$pid" in 1 | "$$" | "$PPID" | "$GPID") continue ;; esac
        for fd in "$p"/fd/*; do
            l="$(readlink "$fd" 2>/dev/null)" || continue
            case "$l" in
                "$mnt" | "$mnt"/*)
                    printf '%s\n' "$pid"
                    continue 2
                    ;;
            esac
        done
        for k in cwd root exe; do
            l="$(readlink "$p/$k" 2>/dev/null)" || continue
            case "$l" in
                "$mnt" | "$mnt"/*)
                    printf '%s\n' "$pid"
                    continue 2
                    ;;
            esac
        done
    done
}

show_holders() {   # <挂载点> 诊断
    local mnt="$1" p fd l k
    for p in /proc/[0-9]*; do
        for fd in "$p"/fd/*; do
            l="$(readlink "$fd" 2>/dev/null)" || continue
            case "$l" in
                "$mnt" | "$mnt"/*)
                    echo "  $(cat "$p/comm" 2>/dev/null)(${p#/proc/}) fd -> $l"
                    continue 2
                    ;;
            esac
        done
        for k in cwd root exe; do
            l="$(readlink "$p/$k" 2>/dev/null)" || continue
            case "$l" in
                "$mnt" | "$mnt"/*)
                    echo "  $(cat "$p/comm" 2>/dev/null)(${p#/proc/}) $k -> $l"
                    break
                    ;;
            esac
        done
    done
}

umount_retry() {   # <挂载点>
    local m="$1" i err
    for i in 1 2 3 4 5 6 7 8 9 10; do
        grep -qs " $m " /proc/mounts || return 0
        err="$(umount "$m" 2>&1)"
        [ -n "$err" ] && log "  umount $m: $err"
        sleep 1
    done
    grep -qs " $m " /proc/mounts && return 1
    return 0
}

for pass in 1 2 3; do
    for m in /etc/log /etc/mnt; do
        for pid in $(holders "$m"); do
            log "请走 $(cat "/proc/$pid/comm" 2>/dev/null)($pid) [$m]"
            kill -9 "$pid" 2>/dev/null
        done
    done
    sleep 1
done
sync
cd / || true

umount_retry /etc/log || {
    log "!! /etc/log 卸不掉, 占用者:"
    show_holders /etc/log
    fail "本次放弃(下次开机再试)"
}
UNMOUNTED=1
umount_retry /etc/mnt || {
    log "!! /etc/mnt 卸不掉, 占用者:"
    show_holders /etc/mnt
    fail "本次放弃(下次开机再试)"
}
sync
log "两个分区都已卸载, 可以安全改写这一片磁盘"

# ---------------------------------------------------------------- 重建文件系统
muuid=$(tune2fs -l /dev/sda3 2>/dev/null | awk '/Filesystem UUID/{print $NF}')
luuid=$(tune2fs -l /dev/sda5 2>/dev/null | awk '/Filesystem UUID/{print $NF}')
[ -n "$muuid" ] && [ -n "$luuid" ] || fail "取不到文件系统 UUID"

fdisk -l "$DEV" > "$WORK/old-table.txt" 2>/dev/null
{
    echo "===== 扩容请求 ${mib} MiB @ $(date '+%F %T') ====="
    cat "$LOGF" 2>/dev/null
} > "$WORK/mnt/.expand.log"

log "重建 /etc/mnt 镜像(UUID=$muuid)"
mke2fs -t ext4 -b 1024 -U "$muuid" -d "$WORK/mnt" -F "$WORK/mnt.img" "$((mnt_secs / 2))" \
    >> "$LOGF" 2>&1 || fail "重建 /etc/mnt 失败"
log "重建 /etc/log 镜像(UUID=$luuid)"
mke2fs -t ext4 -b 4096 -U "$luuid" -d "$WORK/log" -F "$WORK/log.img" "$((p5_secs / 8))" \
    >> "$LOGF" 2>&1 || fail "重建 /etc/log 失败"

# 先验镜像本身干净、UUID 对得上, 免得把坏镜像写下去
check_image() {   # <镜像> <期望UUID>
    local img="$1" uuid="$2" got
    if ! e2fsck -fn "$img" >/dev/null 2>&1; then
        log "!! $img 自检不干净:"
        e2fsck -fn "$img" 2>&1 | tail -8 >> "$LOGF"
        return 1
    fi
    got=$(tune2fs -l "$img" 2>/dev/null | awk '/Filesystem UUID/{print $NF}')
    if [ "$got" != "$uuid" ]; then
        log "!! $img UUID 不对: 期望 $uuid 实际 $got"
        return 1
    fi
    return 0
}
check_image "$WORK/mnt.img" "$muuid" || fail "重建出来的 /etc/mnt 镜像没通过自检"
check_image "$WORK/log.img" "$luuid" || fail "重建出来的 /etc/log 镜像没通过自检"
log "两个镜像自检通过(e2fsck 干净 + UUID 正确)"

# ---------------------------------------------------------------- 备份分区表扇区
# 表没写对就把这几个扇区 dd 回去 —— 此时文件系统镜像还一个字节都没写到盘上, 回滚是干净的。
img_size() { ls -l "$1" 2>/dev/null | awk '{print $5}'; }
verify_written() {   # <镜像> <起始扇区> <校验字节数, 0=全部>
    local img="$1" start="$2" limit="$3" sz
    sz=$(img_size "$img")
    case "$sz" in ''|*[!0-9]*) return 1 ;; esac
    [ "$limit" -gt 0 ] && [ "$limit" -lt "$sz" ] && sz="$limit"
    dd if="$DEV" bs=512 skip="$start" count=$((sz / 512)) 2>/dev/null | \
        cmp -s - <(dd if="$img" bs=512 count=$((sz / 512)) 2>/dev/null)
}

BK="$WORK/table.bak"
rm -rf "$BK" 2>/dev/null
mkdir -p "$BK" 2>/dev/null || fail "建分区表备份目录失败"
save_sec() {
    case "$1" in '' | *[!0-9]*) return 0 ;; esac
    dd if="$DEV" of="$BK/$1" bs=512 skip="$1" count=1 2>/dev/null
}
restore_table() {
    local f s
    for f in "$BK"/*; do
        [ -f "$f" ] || continue
        s="${f##*/}"
        dd if="$f" of="$DEV" bs=512 seek="$s" count=1 conv=notrunc 2>/dev/null
    done
    sync
    log "已把备份的分区表扇区写回"
}
save_sec 0
save_sec "$(part_field sda4 2)"
for item in $keep_list; do                      # 各保留分区的 EBR 在它前面 2048 扇区处
    tok=${item#*=}
    save_sec $(( ${tok%%:*} - 2048 ))
done
log "已备份分区表扇区(MBR+EBR) $(ls "$BK" 2>/dev/null | wc -l) 个"

# ---------------------------------------------------------------- 先写分区表(可回滚)
# 先动表: 写坏了还能把备份扇区 dd 回去, 而盘上文件系统一个字节都没改。
# 保留分区(sda6...)只在扩展区里按原起止重建, 数据不动。
KEEP_INPUT=""
for item in $keep_list; do
    ks=${item#*=}
    KEEP_INPUT="$KEEP_INPUT
n
${ks%%:*}
${ks##*:}"
    log "  重建保留分区 ${item%%=*} = ${ks%%:*}:${ks##*:}(原地)"
done

log "用 fdisk 写新分区表"
fdisk --wipe=never -W never "$DEV" > "$WORK/fdisk.out" 2>&1 <<EOF
d
4
d
3
n
p
3
$mnt_start
$mnt_end
n
e
$ext_start
$ext_end
n
$p5_start
$p5_end$KEEP_INPUT
w
EOF
rc=$?
sync
[ "$rc" = 0 ] || log "!! fdisk 退出码 $rc"

# 复核: 期望的三个位置要一致, 保留分区必须一个字节没挪
norm=$(fdisk -l "$DEV" 2>/dev/null | tr -s ' ')
bad=""
case "$norm" in *"sda3 $mnt_start $mnt_end $mnt_secs "*) ;; *) bad="sda3 期望 $mnt_start-$mnt_end" ;; esac
if [ -z "$bad" ]; then
    case "$norm" in *"sda5 $p5_start $p5_end $p5_secs "*) ;; *) bad="sda5 期望 $p5_start-$p5_end" ;; esac
fi
for item in $keep_list; do
    [ -n "$bad" ] && continue
    ks=${item#*=}
    case "$norm" in *"${item%%=*} ${ks%%:*} ${ks##*:} "*) ;; *) bad="${item%%=*} 被改动了" ;; esac
done

if [ "$rc" != 0 ] || [ -n "$bad" ]; then
    log "!! 分区表复核失败: ${bad:-fdisk 退出码 $rc}"
    sed 's/^/   /' "$WORK/fdisk.out" 2>/dev/null | tail -20 >> "$LOGF"
    restore_table
    log "已回滚(文件系统未改动), 重启回到原状态"
    sync
    reboot 2>/dev/null
    sleep 30
    exit 0
fi
log "分区表复核通过(sda3/sda5 符合预期, 保留分区未动)"

# ---------------------------------------------------------------- 写文件系统镜像
log "写入 /etc/mnt 新位置(偏移 $((mnt_start / 2048))MiB)"
dd if="$WORK/mnt.img" of="$DEV" bs=1M seek=$((mnt_start / 2048)) conv=notrunc 2>/dev/null \
    || fail_after_write "写 /etc/mnt 新位置失败"
log "写入 /etc/log 新位置(偏移 $((p5_start / 2048))MiB)"
dd if="$WORK/log.img" of="$DEV" bs=1M seek=$((p5_start / 2048)) conv=notrunc 2>/dev/null \
    || fail_after_write "写 /etc/log 新位置失败"
sync

log "回读校验 ..."
[ "$(img_size "$WORK/mnt.img")" = "0" ] && fail_after_write "镜像大小异常"
verify_written "$WORK/mnt.img" "$mnt_start" 0 \
    || fail_after_write "/etc/mnt 新位置回读不一致"
log "  /etc/mnt 回读一致"
# /etc/log 镜像十几 G 全读太慢, 只校验最容易出问题的头部 512MiB
verify_written "$WORK/log.img" "$p5_start" $((512 * 1024 * 1024)) \
    || fail_after_write "/etc/log 新位置回读不一致"
log "  /etc/log 回读一致(前 512MiB)"

# ---------------------------------------------------------------- 重启
log "扩容已就绪(/etc/mnt -> ${mib} MiB), 重启以让新分区表生效 ..."
log "(这次重启后会自动再重启一次, 第二次起来就是目标大小)"
sync
reboot 2>/dev/null
sleep 30
exit 0
