#!/bin/bash
#
# 插件系统库(参考官方 firmwareid=90001 插件方案)
#
# 目录布局(全部位于持久盘 /etc/mnt，重启不丢):
#   /etc/mnt/plugins/               插件根目录
#   /etc/mnt/plugins/*.zip          待安装插件包(开机自动安装, 装完归档到 .installed/)
#   /etc/mnt/plugins/<name>/        已安装插件本体
#   /etc/mnt/plugins/.state/<name>  安装状态(版本/时间)
#   /etc/mnt/plugins/.installed/    已安装的 zip 归档
#   /etc/mnt/.boot/plugin.pub       插件校验公钥(可选)
#   /etc/mnt/plugins/plugin.key     打包签名私钥(可选)
#
# 插件包(zip)格式:
#   Release           必需  plugin=<name>  version=<ver>
#   install.sh        必需  安装/每次开机执行(需幂等, 因为根分区每次重启还原)
#   boot.sh           可选  仅每次开机执行(优先于 install.sh)
#   uninstall.sh      可选  卸载
#   MANIFEST.MF       可选  Name: / SHA-256-Digest: 摘要清单
#   SIGNATURE.RSA     可选  openssl dgst -sha256 -sign 结果
#   bin/*             可选  自动软链到 /usr/sbin (去掉 .sh 后缀)
#   etc/*             可选  自动软链到 /usr/local/etc
#
# 依赖: 由 common.sh 提供 P()/log()/get_flag()，调用前需先 source

PLUGIN_ROOT="/etc/mnt/plugins"
PLUGIN_STATE="/etc/mnt/plugins/.state"
PLUGIN_ARCHIVE="/etc/mnt/plugins/.installed"
PLUGIN_PUBKEY="/etc/mnt/.boot/plugin.pub"
PLUGIN_KEY="/etc/mnt/plugins/plugin.key"
# 插件强校验(plugins_verify)已废弃: 插件包不再强制要求签名, 见 plugin_verify()
# 《使用条款》同意记录: 没有它不显示/不启用插件功能(前端只给一个灰色按钮)
PLUGIN_EULA="/etc/mnt/plugins/.eula"
PLUGIN_CARD_STUB="terms"

plugin_eula_accepted() {
    test -f "$(P "$PLUGIN_EULA")" || return 1
    grep -q "^accepted=1" "$(P "$PLUGIN_EULA")" 2>/dev/null
}

plugin_log() { log "[plugin] $*"; }

plugin_ensure_dirs() {
    mkdir -p "$(P "$PLUGIN_ROOT")" "$(P "$PLUGIN_STATE")" "$(P "$PLUGIN_ARCHIVE")" 2>/dev/null
}

# ---------------------------------------------------------------- 插件存储
# 「插件存储」是用户在「系统设置→磁盘分区」里把某块数据盘绑成的业务(见 plugin_fw_patch),
# 绑定后 disk_mgmt 会把它挂到 /etc/disk_sys/plugin。
#
#   绑了数据盘: 把 /etc/mnt/plugins 变成 <数据盘>/plugins 的 bind 挂载 ——
#               插件本体就落在数据盘上, 装多大都行; 而所有既有路径
#               (/etc/mnt/plugins/**、ikplugin、ikguard、文档里的写法)完全不用改。
#   没绑数据盘: 什么都不做, 插件照旧放系统盘 /etc/mnt(43.4M 那个分区)。
#
# 幂等(每次开机挂一次; 挂载不持久)、失败安全(任何一步不满足就保持原样, 不碰插件数据)。
PLUGIN_STORE_LINK="/etc/disk_sys/plugin"
PLUGIN_PURPOSE=6     # 「插件存储」绑定业务的编号(见 plugin_fw_patch)

# 找出"绑了插件存储"的那个分区。直接读分区里写的业务标记(和 disk_mgmt 的
# __part_purpose_get 一个套路: 第 2 个扇区偏移 896 起的 1 个字节), 不依赖 iKuai 的
# cache, 也不依赖它什么时候挂盘 —— 开机时我们可能比它的 disk_mgmt init 跑得早,
# 那时候 cache 还是空的、盘还没挂, 只认 cache 就会误判成"未绑定数据盘"。
plugin_store_find_dev() {
    local d b
    for d in /dev/sd?[0-9]* /dev/hd?[0-9]* /dev/vd?[0-9]* /dev/nvme[0-9]n[0-9]p[0-9]*; do
        [ -b "$d" ] || continue
        b="$(dd if="$d" bs=1 skip=896 count=1 2>/dev/null)"
        [ "$b" = "$PLUGIN_PURPOSE" ] && { printf '%s' "$d"; return 0; }
    done
    return 1
}

# 插件包归档: 放在**系统盘**、且在插件目录之外 —— 插件目录会被 bind 到数据盘上,
# 数据盘万一被格式化(用户在磁盘页点了格式化/换盘), 插件本体就没了; 这里留底才能装回来。
# 系统盘只有 43.4M, 所以只给"不占地方"的包留底(超过 PLUGIN_ZIP_MAX_KB 就跳过并说明)。
PLUGIN_ZIP_ARCHIVE="/etc/mnt/.plugin-zips"
PLUGIN_ZIP_MAX_KB=16384

plugin_zip_keep() {   # <zip>
    local zip="$1" d kb
    case "$zip" in *.zip|*.ZIP) ;; *) return 0 ;; esac
    d="$(P "$PLUGIN_ZIP_ARCHIVE")"
    mkdir -p "$d" 2>/dev/null || return 0
    kb="$(du -k "$zip" 2>/dev/null | awk '{print $1}')"
    case "${kb:-}" in '' | *[!0-9]*) return 0 ;; esac
    if [ "$kb" -gt "$PLUGIN_ZIP_MAX_KB" ]; then
        plugin_log "  包 ${kb}KB 偏大, 不在系统盘留底(数据盘被格式化后需手工重装)"
        return 0
    fi
    cp -f "$zip" "$d/$(basename "$zip")" 2>/dev/null
}

plugin_zip_restore() {   # 数据盘空 + 系统盘也没有时, 用归档装回来
    local d z n=0
    d="$(P "$PLUGIN_ZIP_ARCHIVE")"
    [ -d "$d" ] || return 0
    for z in "$d"/*.zip; do
        [ -f "$z" ] || continue
        plugin_log "  从归档装回: $(basename "$z")"
        plugin_install "$z" >/dev/null 2>&1 && n=$((n + 1))
    done
    [ "$n" -gt 0 ] && plugin_log "已从 $PLUGIN_ZIP_ARCHIVE 装回 $n 个插件"
    return 0
}

plugin_store_ready() {
    local link="$1" root="$2" d_root d_store
    [ -d "$(P "$link")" ] || return 1
    d_root="$(stat -c %d "$(P "$root")" 2>/dev/null)"
    d_store="$(stat -c %d "$(P "$link")" 2>/dev/null)"
    # 必须是"真的另一块盘": 绑定后这条软链指向 /etc/disk/<UUID> 挂载点
    [ -n "$d_root" ] && [ -n "$d_store" ] && [ "$d_root" != "$d_store" ]
}
plugin_store_setup() {
    local link="$PLUGIN_STORE_LINK" store="$PLUGIN_STORE_LINK/plugins"
    local root need_restore=0 dev uuid

    root="$(P "$PLUGIN_ROOT")"
    # 挂载不持久, 每次开机都得挂; 同一次启动里也可能被调用两次(03 和"同意条款"后又跑一遍 03),
    # 所以先卸掉旧的再重挂 —— 数据盘被格式化过时, 老的 bind 会指着那个已经没人管的旧文件系统
    # (写进去的东西重启就没), 必须重挂到**当前**这块盘上。卸不掉(插件进程占着)就沿用旧的,
    # 那种情况下旧挂载本来就是对的。
    if grep -qs " $root " /proc/mounts 2>/dev/null; then
        umount "$root" 2>/dev/null || return 0
    fi

    # 链接不存在(开机时 iKuai 还没把它挂好/建链): 自己找那块盘, 挂上并补链接。
    # 关键 —— 少了这步, 开机就会误判成"未绑定数据盘": 插件目录留在系统盘 ->
    # 看不到 .eula -> 页面提示"需要开启插件功能"、工具页盘符也不对(偶发, 看谁跑在前)。
    if [ ! -d "$(P "$link")" ]; then
        dev="$(plugin_store_find_dev)"
        if [ -n "$dev" ]; then
            uuid="$(blkid "$dev" -o value -s UUID 2>/dev/null)"
            if [ -n "$uuid" ]; then
                if [ ! -d "$(P "/etc/disk/$uuid")" ]; then
                    mkdir -p "$(P "/etc/disk/$uuid")" 2>/dev/null
                    mount -o noatime "$dev" "$(P "/etc/disk/$uuid")" 2>/dev/null
                fi
                mkdir -p "$(P /etc/disk_sys)" 2>/dev/null
                ln -sfn "/etc/disk/$uuid" "$(P "$link")" 2>/dev/null
                plugin_log "插件存储: $PLUGIN_STORE_LINK -> $dev ($uuid) [自行挂载/建链, 不等 iKuai]"
            fi
        fi
    fi

    plugin_store_ready "$link" "$PLUGIN_ROOT" || {
        plugin_log "插件存储: 系统盘 $PLUGIN_ROOT (未绑定数据盘)"
        return 0
    }

    mkdir -p "$(P "$store")" 2>/dev/null || {
        plugin_log "插件存储: 数据盘上建目录失败, 本次沿用系统盘"
        return 0
    }
    # 数据盘上还是空的(刚绑定 / 被格式化过):
    #   系统盘上还有插件  -> 搬过去(不删源, 万一挂载失败也不丢)
    #   系统盘也没有了    -> 用系统盘留的 zip 归档装回来(见 plugin_zip_keep)
    if [ -z "$(ls -A "$(P "$store")" 2>/dev/null)" ]; then
        if [ -n "$(ls -A "$root" 2>/dev/null)" ]; then
            cp -a "$root"/. "$(P "$store")"/ 2>/dev/null || {
                plugin_log "插件存储: 迁移已有插件失败, 本次沿用系统盘"
                return 0
            }
            plugin_log "插件存储: 已把 $PLUGIN_ROOT 的内容迁到数据盘"
        elif [ -n "$(ls -A "$(P "$PLUGIN_ZIP_ARCHIVE")" 2>/dev/null)" ]; then
            plugin_log "插件存储: 数据盘是空的(新建或被格式化), 先挂上去再用归档装回"
            need_restore=1
        fi
    fi
    mount --bind "$(P "$store")" "$root" 2>/dev/null || {
        plugin_log "插件存储: bind 挂载失败, 本次沿用系统盘"
        return 0
    }
    plugin_log "插件存储: 数据盘 $store (插件不再占系统盘 $PLUGIN_ROOT)"
    # 挂在后面再装: 这样装回去的插件也落在数据盘上
    [ "$need_restore" = 1 ] && plugin_zip_restore
    return 0
}

# 解绑「插件存储」: 先把插件搬回系统盘再卸挂载 —— 不然插件会跟着数据盘一起"消失"。
plugin_store_off() {
    local store="$PLUGIN_STORE_LINK/plugins" root tmp bare
    root="$(P "$PLUGIN_ROOT")"
    grep -qs " $root " /proc/mounts 2>/dev/null || return 0

    # 1) 把数据盘上的插件拷回**系统盘的真实目录**。
    #    不能直接 cp 到 $root —— 那正是数据盘的 bind, 等于往自己身上拷(实测报"有文件没放下")。
    #    用扩容脚本里的老办法: 对 /etc/mnt 再做一次"裸 bind", 就能看到被挂载遮住的底层目录。
    tmp="$(mktemp -d 2>/dev/null)"
    bare=""
    if [ -n "$tmp" ] && mount --bind "$(P /etc/mnt)" "$tmp" 2>/dev/null; then
        bare="$tmp/plugins"
    fi
    if [ -n "$bare" ] && [ -d "$bare" ] && \
       [ -n "$(ls -A "$(P "$store")" 2>/dev/null)" ]; then
        cp -a "$(P "$store")"/. "$bare"/ 2>/dev/null || \
            plugin_log "插件存储: 部分文件没拷回(系统盘空间不够?), 缺的可在清出空间后重装"
        plugin_log "插件存储: 已把数据盘上的插件拷回系统盘"
    else
        plugin_log "插件存储: 拿不到底层目录, 跳过拷回(插件仍在数据盘上)"
    fi
    if [ -n "$tmp" ]; then
        umount "$tmp" 2>/dev/null
        rmdir "$tmp" 2>/dev/null
    fi

    # 2) 卸挂载。插件进程还占着就试懒卸载; 再不行就保持原样 ——
    #    内容已经在系统盘上了, 下次开机(那时本就没有 bind)自然就用系统盘那份。
    if ! umount "$root" 2>/dev/null; then
        if umount -l "$root" 2>/dev/null; then
            plugin_log "插件存储: 已解除挂载(懒卸载; 运行中的插件下次启动即用系统盘)"
            return 0
        fi
        plugin_log "插件存储: 插件进程正占用, 本次未卸挂载; 内容已拷回系统盘, 重启后生效"
        return 0
    fi
    plugin_log "插件存储: 业务已解绑, 插件回到系统盘 $PLUGIN_ROOT"
    return 0
}

# 注册「免重启」回调: iKuai 的 disk_mgmt 在绑定/解绑业务时会执行
# /etc/disk_notify/<name> disk_setting|disk_remove(<name> 是绑定目标路径的最后一段,
# 业务 6 的落点是 /etc/disk_sys/plugin, 所以 <name>=plugin)。和 2/3/4/5 那几个业务
# (dingtalk/video/audit/youyu)完全一样的套路 —— 绑定后立即挂载, 不用重启。
PLUGIN_NOTIFY="/etc/disk_notify/plugin"
plugin_store_notify_install() {
    local f tmp
    f="$(P "$PLUGIN_NOTIFY")"
    if [ -x "$f" ] && grep -q 'ikplugin store' "$f" 2>/dev/null; then
        return 0
    fi
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
    tmp="$(mktemp)" || return 0
    {
        echo '#!/bin/sh'
        echo '# 「插件存储」业务(绑定业务=插件存储)的回调, 由 disk_mgmt.__notify_service 调用:'
        echo '#   disk_setting -> 立即把插件目录挂到数据盘; disk_remove -> 搬回系统盘并卸挂载'
        echo '# 目的: 和视频缓存/行为记录那些业务一样, 绑定后立刻生效, 不需要重启。'
        echo 'case "$1" in'
        echo '    disk_remove) exec /etc/mnt/.boot/bin/ikplugin store off ;;'
        echo '    *)'
        echo '        /etc/mnt/.boot/bin/ikplugin store on'
        echo '        # 换个盘之后插件卡片/页面/启动都要重铺一遍(后台跑, 别拖住 iKuai 的磁盘流程)'
        echo '        bash /etc/mnt/.boot/scripts/03_enable_plugins.sh >/dev/null 2>&1 &'
        echo '        ;;'
        echo 'esac'
    } > "$tmp" 2>/dev/null
    if [ -s "$tmp" ]; then
        cat "$tmp" > "$f" && chmod +x "$f" 2>/dev/null
    fi
    rm -f "$tmp"
    return 0
}

# 从 Release 读取字段
plugin_meta() {
    sed -n "s/^$2=//p" "$1/Release" 2>/dev/null | head -n1
}

plugin_name() {
    local n
    n=$(plugin_meta "$1" "plugin")
    test -n "$n" || n=$(plugin_meta "$1" "name")
    test -n "$n" || n=$(basename "$1")
    printf '%s' "$n"
}

plugin_version() {
    local v
    v=$(plugin_meta "$1" "version")
    printf '%s' "${v:--}"
}

# ---------------------------------------------------------------- 校验

# 校验 MANIFEST.MF 内所有文件的 SHA-256
plugin_check_manifest() {
    local dir="$1" line fname="" digest actual
    while IFS= read -r line; do
        case "$line" in
            "Name: "*) fname="${line#Name: }" ;;
            "SHA-256-Digest: "*) digest="${line#SHA-256-Digest: }" ;;
            *) continue ;;
        esac
        test -n "$fname" || continue
        test -n "$digest" || continue
        actual=$(sha256sum "$dir/$fname" 2>/dev/null | cut -d' ' -f1)
        if test "$actual" != "$digest"; then
            plugin_log "摘要不匹配: $fname"
            return 1
        fi
        fname=""; digest=""
    done < "$dir/MANIFEST.MF"
    return 0
}

# 校验 RSA 签名
plugin_check_signature() {
    local dir="$1" key="$2"
    test -f "$dir/SIGNATURE.RSA" || return 1
    test -f "$key" || return 1
    openssl dgst -sha256 -verify "$key" \
        -signature "$dir/SIGNATURE.RSA" "$dir/MANIFEST.MF" >/dev/null 2>&1
}

# 插件包校验: 不强制要求签名(强校验已废弃)
#   带 MANIFEST.MF  -> 校验其中每个文件的 SHA-256(防传输损坏/被改动)
#   同时带 SIGNATURE.RSA 且配置了 plugin.pub -> 额外校验签名
#   只有 install.sh 的普通 zip 也能直接安装
plugin_verify() {
    local dir="$1" key
    key="$(P "$PLUGIN_PUBKEY")"

    test -f "$dir/MANIFEST.MF" || return 0
    plugin_check_manifest "$dir" || return 1
    if test -f "$dir/SIGNATURE.RSA" && test -f "$key"; then
        plugin_check_signature "$dir" "$key" || { plugin_log "签名校验失败"; return 1; }
    fi
    return 0
}

# ---------------------------------------------------------------- 链接/执行

# bin/* -> /usr/sbin ; etc/* -> /usr/local/etc
plugin_link() {
    local dir="$1" item name target rel
    if test -d "$dir/bin"; then
        mkdir -p "$(P /usr/sbin)" 2>/dev/null
        find "$dir/bin" -type f -print0 | while IFS= read -r -d '' item; do
            name=$(basename "$item")
            case "$name" in *.sh) name="${name%.sh}" ;; esac
            ln -sf "$item" "$(P /usr/sbin)/$name" 2>/dev/null
        done
    fi
    if test -d "$dir/etc"; then
        mkdir -p "$(P /usr/local/etc)" 2>/dev/null
        ( cd "$dir/etc" && find . -mindepth 1 -print0 | while IFS= read -r -d '' item; do
            rel="${item#./}"
            target="$(P /usr/local/etc)/$rel"
            test -d "$(dirname "$target")" || mkdir -p "$(dirname "$target")"
            ln -sf "$dir/etc/$rel" "$target" 2>/dev/null
        done )
    fi
}

# 插件自带的 Web 资源与后端接口(可选), 链接到根分区:
#   <plugin>/www/plugins/<name>/<name>.json -> /usr/ikuai/www/plugins/<name>/  (插件卡片)
#   <plugin>/www/plugins/app/*              -> /usr/ikuai/www/plugins/app/     (页面/图标)
#   <plugin>/function/<func_name>           -> /usr/ikuai/function/<func_name> (后端接口)
# 用软链而不是拷贝: 卸载时能精确清理, 且根分区重启还原后重建代价更低。
plugin_web_link() {
    local dir="$1" item rel target base
    # 未同意《使用条款》时不链接插件的 Web 资源与后端接口(插件管理页只应有"同意入口"),
    # 并把"同意之前"可能残留的链接撤掉(比如先同意、后又撤销)。
    if ! plugin_eula_accepted; then
        for base in "$(P /usr/ikuai/function)" "$(P /usr/ikuai/www/plugins)"; do
            test -d "$base" || continue
            find "$base" -maxdepth 4 -type l -print0 2>/dev/null | \
            while IFS= read -r -d '' item; do
                case "$(readlink "$item" 2>/dev/null)" in "$dir"/*) rm -f "$item" ;; esac
            done
        done
        plugin_log "未同意使用条款, 暂不链接插件 Web 资源/接口: $(basename "$dir")"
        return 0
    fi
    if test -d "$dir/www/plugins"; then
        ( cd "$dir/www" && find plugins -type f -print0 2>/dev/null | \
          while IFS= read -r -d '' item; do
              rel="${item#plugins/}"
              target="$(P /usr/ikuai/www/plugins)/$rel"
              mkdir -p "$(dirname "$target")" 2>/dev/null
              ln -sf "$dir/www/$item" "$target" 2>/dev/null
          done )
    fi
    if test -d "$dir/function"; then
        mkdir -p "$(P /usr/ikuai/function)" 2>/dev/null
        ( cd "$dir/function" && find . -type f -print0 2>/dev/null | \
          while IFS= read -r -d '' item; do
              rel="${item#./}"
              chmod +x "$dir/function/$rel" 2>/dev/null
              ln -sf "$dir/function/$rel" "$(P /usr/ikuai/function)/$rel" 2>/dev/null
          done )
    fi
    return 0
}

# 删除指向某插件目录的所有软链接(含 Web 卡片/页面与后端接口)
plugin_unlink() {
    local dir="$1" base item
    for base in "$(P /usr/sbin)" "$(P /usr/local/etc)" \
                "$(P /usr/ikuai/function)" "$(P /usr/ikuai/www/plugins)"; do
        test -d "$base" || continue
        find "$base" -maxdepth 4 -type l -print0 2>/dev/null | \
        while IFS= read -r -d '' item; do
            case "$(readlink "$item" 2>/dev/null)" in "$dir"/*) rm -f "$item" ;; esac
        done
    done
    # 顺手删掉因此变空的插件卡片目录
    find "$(P /usr/ikuai/www/plugins)" -mindepth 1 -maxdepth 1 -type d -empty 2>/dev/null | \
    while IFS= read -r item; do rmdir "$item" 2>/dev/null; done
    return 0
}

# 执行插件脚本(带环境变量)
plugin_run() {
    local dir="$1" action="$2" script="" name ver
    if test "$action" = "boot" && test -x "$dir/boot.sh"; then
        script="$dir/boot.sh"
    elif test "$action" != "uninstall" && test -x "$dir/install.sh"; then
        script="$dir/install.sh"
    elif test "$action" = "uninstall" && test -x "$dir/uninstall.sh"; then
        script="$dir/uninstall.sh"
    fi

    if test -z "$script"; then
        plugin_link "$dir"
        plugin_web_link "$dir"
        return 0
    fi

    name=$(plugin_name "$dir"); ver=$(plugin_version "$dir")
    PLUGIN_NAME="$name" PLUGIN_VERSION="$ver" PLUGIN_DIR="$dir" \
    PLUGIN_ROOT="$(P "$PLUGIN_ROOT")" PLUGIN_ACTION="$action" \
    IK_SYSROOT="$IK_SYSROOT" "$script"
}

plugin_record() {
    local name="$1" dir="$2"
    plugin_ensure_dirs
    {
        echo "name=$name"
        echo "version=$(plugin_version "$dir")"
        echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$(P "$PLUGIN_STATE")/$name"
}

# ---------------------------------------------------------------- 增删查

# 安装插件: plugin_install <zip|目录>
plugin_install() {
    local src="$1" name dest tmp bak keep_data=0
    test -e "$src" || { plugin_log "不存在: $src"; return 1; }
    plugin_ensure_dirs

    if test -d "$src"; then
        name=$(plugin_name "$src")
        plugin_verify "$src" || return 1
        dest="$(P "$PLUGIN_ROOT")/$name"
        if test "$(cd "$src" && pwd)" != "$dest"; then
            rm -rf "$dest"
            mkdir -p "$dest"
            cp -rf "$src"/. "$dest"/ || { plugin_log "复制失败: $src"; rm -rf "$dest"; return 1; }
        fi
    else
        case "$src" in
            *.zip|*.ZIP) ;;
            *) plugin_log "不支持的包(需为 zip): $src"; return 1 ;;
        esac
        plugin_zip_keep "$src"      # 系统盘留底, 数据盘被格式化后能装回来
        tmp=$(mktemp -d)
        if ! unzip -o -q "$src" -d "$tmp" 2>/dev/null; then
            plugin_log "解压失败: $src"
            rm -rf "$tmp"
            return 1
        fi
        # 兼容 "zip -r pack.zip <目录>" 打出来的包: 解压后只有一层目录、
        # 且 Release 在该目录里时自动下钻一层(否则会被当成名字为 tmp.XXXX 的插件)
        if [ ! -f "$tmp/Release" ]; then
            local cnt sub tmp2
            cnt="$(find "$tmp" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
            sub="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)"
            if [ "$cnt" = "1" ] && [ -n "$sub" ] && [ -f "$sub/Release" ]; then
                tmp2="$(mktemp -d)"
                if mv "$sub" "$tmp2/pkg" 2>/dev/null; then
                    plugin_log "包内是单层目录, 自动下钻: $(basename "$sub")"
                    rm -rf "$tmp"
                    tmp="$tmp2/pkg"
                else
                    rm -rf "$tmp2"
                fi
            fi
        fi
        name=$(plugin_name "$tmp")
        if ! plugin_verify "$tmp"; then
            rm -rf "$tmp"
            return 1
        fi
        dest="$(P "$PLUGIN_ROOT")/$name"
        # 升级安装: 先保留插件自己的持久数据目录 data/(数据库/状态), 否则重装即丢数据。
        # 用同分区 rename 做暂存(bak 目录与插件目录同一个文件系统), 不经过 /tmp。
        if [ -d "$dest/data" ]; then
            bak="$(P "$PLUGIN_ROOT")/.backup-$name"
            rm -rf "$bak"
            mkdir -p "$bak"
            if mv "$dest/data" "$bak/data" 2>/dev/null; then
                keep_data=1
                plugin_log "已暂存持久数据: $dest/data"
            fi
        fi
        rm -rf "$dest"
        mkdir -p "$(dirname "$dest")"
        mv "$tmp" "$dest" || { plugin_log "移动失败: $tmp -> $dest"; rm -rf "$tmp"; return 1; }
        if [ "$keep_data" = "1" ]; then
            rm -rf "$dest/data"
            if mv "$bak/data" "$dest/data" 2>/dev/null; then
                plugin_log "已恢复持久数据: $dest/data"
            fi
            rm -rf "$bak"
        fi
    fi

    plugin_log "安装插件: $name (版本 $(plugin_version "$dest"))"
    plugin_run "$dest" "install"
    plugin_link "$dest"
    plugin_web_link "$dest"
    plugin_record "$name" "$dest"
    return 0
}

# 卸载插件: plugin_remove <name>
plugin_remove() {
    local name="$1" dir
    dir="$(P "$PLUGIN_ROOT")/$name"
    test -d "$dir" || { plugin_log "未安装: $name"; return 1; }
    plugin_run "$dir" "uninstall"
    plugin_unlink "$dir"
    rm -rf "$dir" "$(P "$PLUGIN_STATE")/$name"
    plugin_log "已卸载: $name"
}

# 列出已安装插件
plugin_list() {
    local root="$1" d name ver
    root="$(P "$PLUGIN_ROOT")"
    printf '%-24s %-12s %s\n' NAME VERSION LOCATION
    find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 2>/dev/null | \
    while IFS= read -r -d '' d; do
        test -f "$d/Release" || continue
        name=$(plugin_name "$d"); ver=$(plugin_version "$d")
        printf '%-24s %-12s %s\n' "$name" "$ver" "$d"
    done
}

# 开机: 重新铺开所有已安装插件
plugin_boot() {
    local root d
    root="$(P "$PLUGIN_ROOT")"
    test -d "$root" || return 0
    find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 2>/dev/null | \
    while IFS= read -r -d '' d; do
        test -f "$d/Release" || continue
        plugin_verify "$d" || { plugin_log "校验失败, 跳过: $d"; continue; }
        plugin_log "启动插件: $(plugin_name "$d")"
        plugin_run "$d" "boot"
        plugin_link "$d"
        plugin_web_link "$d"
    done
}

# 扫描并安装 upload 进来的 zip 包
plugin_scan_zips() {
    local root z
    root="$(P "$PLUGIN_ROOT")"
    find "$root" -maxdepth 1 -type f \( -name '*.zip' -o -name '*.ZIP' \) -print0 2>/dev/null | \
    while IFS= read -r -d '' z; do
        plugin_log "发现插件包: $z"
        if plugin_install "$z"; then
            mv -f "$z" "$(P "$PLUGIN_ARCHIVE")/" 2>/dev/null
        else
            plugin_log "安装失败(保留): $z"
        fi
    done
}

# 暴露命令行 /usr/sbin/ikplugin、/usr/sbin/ikexpand
plugin_link_cli() {
    mkdir -p "$(P /usr/sbin)" 2>/dev/null
    ln -sf "$(P /etc/mnt/.boot/bin/ikplugin)" "$(P /usr/sbin)/ikplugin" 2>/dev/null
    # ikexpand: 给 /etc/mnt 扩容(写请求 -> 开机时由 scripts/09 执行)
    ln -sf "$(P /etc/mnt/.boot/bin/ikexpand)" "$(P /usr/sbin)/ikexpand" 2>/dev/null
}

# ---------------------------------------------------------------- Web 插件(网页版)

# 框架自带 Web 插件资源目录(随 .boot 一起部署)
PLUGIN_WWW_SRC="$(P /etc/mnt/.boot/www)"
PLUGIN_WWW_DST="$(P /usr/ikuai/www/plugins)"
PLUGIN_FUNCTION_SRC="$(P /etc/mnt/.boot/usr/ikuai/function)"
PLUGIN_FUNCTION_DST="$(P /usr/ikuai/function)"

# 同步 Web 插件资源到根分区(根分区每次重启还原, 必须每开机重建)
#   <boot>/www/plugins/<name>/<name>.json  -> /usr/ikuai/www/plugins/<name>/<name>.json (卡片)
#   <boot>/www/plugins/app/<name>.{html,png} -> /usr/ikuai/www/plugins/app/          (页面/图标)
# 说明: iKuai 前端(/usr/ikuai/function/plugins 的 __show_data)读取
#       /usr/ikuai/www/plugins/*/*.json 生成"系统设置->插件管理"卡片列表, 卡片点击后
#       以 iframe 打开 /plugins/app/<name>.html (原路径是 /plugins/docker/, 见 plugin_web_patch)。
#
# 使用条款(PLUGIN_EULA)未同意时: 只铺"需要同意条款"的占位卡片(PLUGIN_CARD_STUB),
# 不显示任何真实插件; 同意后由 ikguard 的 eula 动作重新调用本函数换成正式卡片。
plugin_web_sync() {
    local src="$PLUGIN_WWW_SRC/plugins" dst="$PLUGIN_WWW_DST" f d name
    test -d "$src" || return 0

    mkdir -p "$dst" 2>/dev/null
    # 整棵树由本函数负责: 先清空再按"是否已同意条款"重新铺。
    # 依赖 scripts/03 里的调用顺序 —— 必须先 sync(本函数) 再 plugin_boot(plugin_web_link),
    # 否则会把插件刚建好的卡片/页面软链一起清掉。
    rm -rf "$dst"/* 2>/dev/null

    if plugin_eula_accepted; then
        for f in "$src"/*/*.json; do
            [ -f "$f" ] || continue
            d="$(basename "$(dirname "$f")")"
            [ "$d" = "$PLUGIN_CARD_STUB" ] && continue
            mkdir -p "$dst/$d" 2>/dev/null
            cp -f "$f" "$dst/$d/" 2>/dev/null
        done
        plugin_log "使用条款已同意, 已铺开插件卡片"
    else
        f="$src/$PLUGIN_CARD_STUB/$PLUGIN_CARD_STUB.json"
        if [ -f "$f" ]; then
            mkdir -p "$dst/$PLUGIN_CARD_STUB" 2>/dev/null
            cp -f "$f" "$dst/$PLUGIN_CARD_STUB/" 2>/dev/null
        fi
        plugin_log "使用条款未同意, 仅显示同意入口(插件功能未启用)"
    fi

    # 页面与图标(含占位卡片用的 terms.html)
    if test -d "$src/app"; then
        mkdir -p "$dst/app" 2>/dev/null
        for f in "$src/app"/*; do
            [ -f "$f" ] || continue
            cp -f "$f" "$dst/app/" 2>/dev/null
        done
    fi
    plugin_log "Web 插件资源已同步: $dst"
    return 0
}

# Web 前端补丁(每个开机执行一次, 根分区每次重启还原):
#   1) 去掉「插件管理」页"使用插件功能需要绑定爱快云平台！"的拦截
#      前端逻辑 yunbindstatus = ("" != code ? 2 : 1), code 来自 func_name=register(云平台
#      绑定码), 为空即未绑定 -> 1 = 只显示"前往绑定"。本框架插件不读云平台, 直接置 2。
#   2) 插件页面目录 /plugins/docker/ 改名 /plugins/app/ (避免与 Docker 功能混淆)
#   3) 点开插件后小标题写死的 "Docker" 文案改成 "插件"
#   4) 顶部"爱快e云APP 掌上办"云绑定二维码弹框不再弹出(tipCloudBind=!0 -> !1)
#   5) 插件卡片显示 title 而不是 name(卡片的 name 必须是文件名, 显示不友好)
#   6) 「系统设置→磁盘分区」的"绑定业务"下拉加第 6 项 —— 插件存储(见 plugin_fw_patch)
# 前端分包是 gzip 静态资源, 做法: 解开 -> sed 改写 -> 重新压缩 -> 复核后写回。
plugin_web_patch() {
    local dir f tmp patched gz n=0 want_ub want_dir want_title
    dir="$(P /usr/ikuai/www/static/js)"
    if [ ! -d "$dir" ]; then
        plugin_log "跳过 Web 前端补丁(无 $dir)"
        return 0
    fi
    command -v zcat >/dev/null 2>&1 || { plugin_log "跳过 Web 前端补丁(无 zcat)"; return 0; }

    for f in "$dir"/*.js.gz; do
        [ -f "$f" ] || continue
        zcat "$f" 2>/dev/null | grep -q -e "Plugin_management" -e "plugins/docker/" -e "tipCloudBind" -e "binding_business_name" 2>/dev/null || continue

        tmp="$(mktemp)"; patched="$(mktemp)"; gz="$(mktemp)"
        if ! zcat "$f" > "$tmp" 2>/dev/null; then
            rm -f "$tmp" "$patched" "$gz"; continue
        fi

        want_ub=0; want_dir=0; want_title=0; want_bind=0; want_label=0; want_purpose=0; want_opt=0
        grep -q 'yunbindstatus=""!=i.code?2:1' "$tmp" 2>/dev/null && want_ub=1
        grep -q 'plugins/docker/' "$tmp" 2>/dev/null && want_dir=1
        grep -q 't\._v("Docker")' "$tmp" 2>/dev/null && want_title=1
        grep -q 'tipCloudBind=!0' "$tmp" 2>/dev/null && want_bind=1
        grep -q '_s(e\.name)' "$tmp" 2>/dev/null && want_label=1
        # 磁盘分区页: 绑定业务下拉加第 6 项(插件存储) + 表格里的业务名数组加第 7 项
        # 注意: /usr/ikuai/www/static/js 是**持久**目录(不像根分区每次还原), 所以这两条补丁
        # 必须幂等 —— 否则每次开机都会再插一条, 下拉里就会攒出一堆"插件存储"。
        grep -q 't\.\$t(i+"5")\]\[1\*s\]' "$tmp" 2>/dev/null && want_purpose=1
        # 下拉项: 0=没插过, 1=已经插过(不动它), 2=插重了(清干净重插)
        case "$(grep -o 'binding_business_name6' "$tmp" 2>/dev/null | wc -l | tr -d ' ')" in
            0) grep -q 'binding_business_name5")))]):t\._e()' "$tmp" 2>/dev/null && want_opt=1 ;;
            1) want_opt=0 ;;
            *) want_opt=2 ;;
        esac
        if [ "$want_ub" = 0 ] && [ "$want_dir" = 0 ] && [ "$want_title" = 0 ] && \
           [ "$want_bind" = 0 ] && [ "$want_label" = 0 ] && \
           [ "$want_purpose" = 0 ] && [ "$want_opt" = 0 ]; then
            rm -f "$tmp" "$patched" "$gz"; continue
        fi

        sed -e 's|yunbindstatus=""!=i.code?2:1|yunbindstatus=2|g' \
            -e 's|plugins/docker/|plugins/app/|g' \
            -e 's|t\._v("Docker")|t._v("插件")|g' \
            -e 's|\.tipCloudBind=!0|.tipCloudBind=!1|g' \
            -e 's@_s(e\.name)@_s(e.title||e.name)@g' \
            -e 's|t\.\$t(i+"5")\]\[1\*s\]|t.$t(i+"5"),t.$t(i+"6")][1*s]|g' \
            "$tmp" > "$patched"

        # 下拉第 6 项(插件存储)用 awk 按"整串"增删: busybox sed 对带 {} 的长模式不靠谱。
        # 顺序 = 先删掉历史插入的(可能积了好几条), 再在"钉钉闪传"那项后面插恰好一条。
        if [ "$want_opt" != 0 ]; then
            awk -v bad='e("option",{attrs:{value:"6"}},[t._v(t._s(t.$t("common.disk-management.diskshowtable.binding_business_name6")))]),t._v(" "),' \
                -v anchor='binding_business_name5")))]):t._e()' \
                -v ins=',t._v(" "),e("option",{attrs:{value:"6"}},[t._v(t._s(t.$t("common.disk-management.diskshowtable.binding_business_name6")))])' '
                {
                    out = ""; rest = $0
                    while ((p = index(rest, bad)) > 0) {          # 清掉所有历史插入
                        out = out substr(rest, 1, p - 1)
                        rest = substr(rest, p + length(bad))
                    }
                    line = out rest
                    p = index(line, anchor)                        # 在最后一项后面插一条
                    if (p > 0 && !done) {
                        line = substr(line, 1, p + length(anchor) - 1) ins substr(line, p + length(anchor))
                        done = 1
                    }
                    print line
                }' "$patched" > "$patched.new" && mv -f "$patched.new" "$patched"
        fi

        if gzip -9 -c < "$patched" > "$gz" 2>/dev/null && \
           { [ "$want_ub" = 0 ] || zcat "$gz" 2>/dev/null | grep -q 'yunbindstatus=2'; } && \
           { [ "$want_dir" = 0 ] || zcat "$gz" 2>/dev/null | grep -q 'plugins/app/'; } && \
           { [ "$want_title" = 0 ] || zcat "$gz" 2>/dev/null | grep -q 't._v("插件")'; } && \
           { [ "$want_bind" = 0 ] || zcat "$gz" 2>/dev/null | grep -q 'tipCloudBind=!1'; } && \
           { [ "$want_label" = 0 ] || zcat "$gz" 2>/dev/null | grep -q 'e.title||e.name'; } && \
           { [ "$want_purpose" = 0 ] || zcat "$gz" 2>/dev/null | grep -q 't\.\$t(i+"6")\]\[1\*s\]'; } && \
           { [ "$want_opt" = 0 ] || [ "$(zcat "$gz" 2>/dev/null | grep -o 'binding_business_name6' | wc -l)" = 1 ]; }; then
            cat "$gz" > "$f"
            n=$((n + 1))
            plugin_log "  已打补丁: $(basename "$f") (云拦截=$want_ub 目录=$want_dir 标题=$want_title 云弹框=$want_bind 卡片名=$want_label 业务下拉=$want_opt 业务名表=$want_purpose)"
        else
            plugin_log "  补丁未生效(保留原文件): $(basename "$f")"
        fi
        rm -f "$tmp" "$patched" "$gz"
    done
    plugin_log "Web 前端补丁完成(修改 $n 个分包)"
    return 0
}

# ------------------------------------------------------------------ 固件侧补丁
# 给 iKuai 自带「系统设置→磁盘分区」加第 6 种绑定业务 = **插件存储**。
#
# 为什么要打补丁: 业务枚举是写死在固件里的三处 ——
#   1) /usr/ikuai/script/disk_mgmt.sh 的 __link_setting(): purpose -> 链接路径
#   2) 同一个文件 partition_set(): 哪些 purpose 不需要用户起名
#   3) 磁盘分区页分包(下拉 option + 表格里的业务名数组) + www/static/i18n/*.json
# 而 /usr/ikuai 是只读固件、每次开机还原, 所以框架每次开机都得重打一遍。
#
# 绑定后该分区会被挂到 /etc/disk_sys/plugin(见 __link_setting),
# 于是插件/框架的大件数据可以直接放那块数据盘, 不再受 43.4M 系统盘(/etc/mnt)限制。
plugin_fw_patch() {
    local s tmp n=0 i18n f label
    s="$(P /usr/ikuai/script/disk_mgmt.sh)"

    # 1) 业务枚举, 三处都要改:
    #    ① __link_setting 加 6) 分支   ② partition_set 的"不用起名"列表
    #    ③ __notify_service 的两个分支(绑定时回调 /etc/disk_notify/plugin, 免重启)
    #    判定"要不要动": 缺任何一条都算缺 —— 只看"有没有 6) 分支"会让新增的回调枚举补不上。
    if [ -f "$s" ]; then
        want_fw=0
        grep -q 'disk_sys/plugin' "$s" 2>/dev/null || want_fw=1
        grep -q '2|3|4|5)' "$s" 2>/dev/null && want_fw=1
    fi
    if [ "${want_fw:-0}" = 1 ]; then
        tmp="$(mktemp)" || tmp=""
        if [ -n "$tmp" ]; then
            ins6=1
            grep -q 'disk_sys/plugin' "$s" 2>/dev/null && ins6=0   # 已有 6) 分支就别重复插
            awk -v ins="$ins6" '
                { print }
                /__link_replace \$uuid \/etc\/disk_sys\/dingtalk/ {
                    if (ins) {
                        print "\t\t;;"
                        print "\t6)"
                        print "\t\t__link_replace $uuid /etc/disk_sys/plugin"
                        ins = 0
                    }
                }
            ' "$s" > "$tmp" 2>/dev/null
            # 三处业务枚举: ①__link_setting 加 6) 分支 ②partition_set 的"免起名"列表
            # ③__notify_service 的两个分支(绑定/解绑时要回调 /etc/disk_notify/plugin)
            # 按"整行相等"改那三行业务枚举(busybox sed 对 \t 缩进不靠谱, awk 稳)
            awk -v a="$(printf '\t2|3|4|5)')"     -v A="$(printf '\t2|3|4|5|6)')" \
                -v b="$(printf '\t\t2|3|4|5)')"   -v B="$(printf '\t\t2|3|4|5|6)')" '
                { if ($0 == a) print A; else if ($0 == b) print B; else print }' \
                "$tmp" > "$tmp.2" && mv -f "$tmp.2" "$tmp"
            # 复核: 6) 分支在, 且**那两行 switch 标签**已经改到
            # (不能只 grep '2|3|4|5)' —— partition_set 里还有一行 `1|2|3|4|5)`
            #  是"内部盘 sda1~sda5 禁止绑定"的列表, 那行本来就不该动)
            if grep -q 'disk_sys/plugin' "$tmp" 2>/dev/null && \
               [ "$(awk -v b="$(printf '\t\t2|3|4|5)')" '$0 == b' "$tmp" 2>/dev/null | wc -l)" = 0 ]; then
                cat "$tmp" > "$s"
                n=$((n + 1))
                plugin_log "  已补丁 disk_mgmt.sh(绑定业务 6=插件存储 -> /etc/disk_sys/plugin)"
            else
                plugin_log "  disk_mgmt.sh 补丁未生效(保留原文件)"
            fi
            rm -f "$tmp"
        fi
    fi

    # 1b) disk_find.lua: 它按 df 的"设备名"建表, 业务取自挂载路径里的 /etc/disk/<uuid>。
    #     而「插件存储」会把同一块盘再挂到 /etc/mnt/plugins —— df 里那条路径匹配不到 uuid,
    #     于是把已经取到的业务覆盖成 "0", 页面就显示成"不使用"(其实是绑着的)。
    #     改成: 取不到非 0 业务时, 保留同一设备上已经取到的那个。
    lua="$(P /usr/ikuai/script/utils/disk_find.lua)"
    if [ -f "$lua" ] && ! grep -q 'diskf_tab\[part\] and diskf_tab\[part\].mt_purpose' "$lua" 2>/dev/null; then
        tmp="$(mktemp)" || tmp=""
        if [ -n "$tmp" ]; then
            # 只认那一行赋值(mount_cache_p[uuid] 在文件里还有别处出现, 锚点必须更精确)
            awk -v to='mt_purpose = (mount_cache_p[uuid] and mount_cache_p[uuid] ~= "0" and mount_cache_p[uuid]) or (diskf_tab[part] and diskf_tab[part].mt_purpose) or "0",' '
                !done && /mt_purpose = mount_cache_p\[uuid\]/ {
                    match($0, /^[ \t]*/)
                    print substr($0, 1, RLENGTH) to
                    done = 1
                    next
                }
                { print }' "$lua" > "$tmp" 2>/dev/null
            if grep -q 'diskf_tab\[part\] and diskf_tab\[part\].mt_purpose' "$tmp" 2>/dev/null; then
                cat "$tmp" > "$lua"
                n=$((n + 1))
                plugin_log "  已补丁 disk_find.lua(同设备多处挂载时, 绑定业务不再显示成\"不使用\")"
            else
                plugin_log "  disk_find.lua 补丁未生效(保留原文件)"
            fi
            rm -f "$tmp"
        fi
    fi

    # 2) i18n: 业务名(页面用 common.disk-management.diskshowtable.binding_business_name6)
    #    注意: 新键**插在 name5 前面**, 这样原有的逗号结构原封不动 ——
    #    早先"插在 name5 后面"的写法会让 JSON 少一个逗号, i18n 直接加载失败、整个页面文案全乱。
    i18n="$(P /usr/ikuai/www/static/i18n)"
    for f in "$i18n"/zh-CN.json "$i18n"/zh-TW.json "$i18n"/en-US.json; do
        [ -f "$f" ] || continue
        grep -q 'binding_business_name6' "$f" 2>/dev/null && continue
        case "${f##*/}" in
            en-US.json) label="Plugin storage" ;;
            zh-TW.json) label="插件存儲" ;;
            *)          label="插件存储" ;;
        esac
        tmp="$(mktemp)" || continue
        sed "s|\"binding_business_name5\": \"[^\"]*\"|\"binding_business_name6\": \"$label\", &|" \
            "$f" > "$tmp" 2>/dev/null
        # 复核: 新键必须紧跟着 name5(说明逗号结构没被破坏)
        if grep -q "binding_business_name6\": \"$label\", \"binding_business_name5\"" "$tmp" 2>/dev/null; then
            cat "$tmp" > "$f"
            n=$((n + 1))
        else
            plugin_log "  i18n 补丁未生效(保留原文件): ${f##*/}"
        fi
        rm -f "$tmp"
    done

    # 3) 已经绑定过 purpose=6 的分区: 补丁生效后把链接补上
    #    (IK_DIR_CACHE=/tmp/iktmp/cache, 由 iKuai 开机时 init() 从 sqlite 刷进来)
    #
    #    **不要**去跑 disk_mgmt.sh init: 它内部会 `rm -rf /etc/disk/<UUID>` 再重挂,
    #    而 /etc/mnt/plugins 正是 bind 到那个目录下的 —— 源目录一没, 挂载就变成死挂载,
    #    往里写的东西全部无效(现象: 插件装不上、条款存不下、重启后插件"消失")。
    #    这里只补一条软链就够了(分区本身由 iKuai 开机时的 init 挂好)。
    if grep -qs 'mt_purpose=6' "$(P /tmp/iktmp/cache/disk_mount)" 2>/dev/null; then
        local puuid
        puuid="$(grep 'mt_purpose=6' "$(P /tmp/iktmp/cache/disk_mount)" 2>/dev/null | \
                 tr ' ' '\n' | sed -n 's/^mt_uuid=//p' | head -n1)"
        if [ -n "$puuid" ] && [ -d "/etc/disk/$puuid" ]; then
            mkdir -p /etc/disk_sys 2>/dev/null
            ln -sfn "/etc/disk/$puuid" /etc/disk_sys/plugin 2>/dev/null && \
                plugin_log "  插件存储: /etc/disk_sys/plugin -> /etc/disk/$puuid"
        fi
    fi

    plugin_log "固件侧补丁完成(修改 $n 处)"
    return 0
}

# 挂载后端接口: <boot>/usr/ikuai/function/<name> -> /usr/ikuai/function/<name>
# (func_api.sh 通过 /usr/ikuai/function/<func_name> 分发页面请求)
plugin_function_link() {
    local src="$PLUGIN_FUNCTION_SRC" dst="$PLUGIN_FUNCTION_DST" f n
    test -d "$src" || return 0
    mkdir -p "$dst" 2>/dev/null
    find "$src" -maxdepth 1 -type f -print0 2>/dev/null | \
    while IFS= read -r -d '' f; do
        n="$(basename "$f")"
        chmod +x "$f" 2>/dev/null
        ln -sf "$f" "$dst/$n" 2>/dev/null
    done
    plugin_log "Web 后端接口已挂载: $dst"
    return 0
}

# ---------------------------------------------------------------- 打包工具

# 生成 MANIFEST.MF
plugin_manifest() {
    local dir="$1" f rel
    {
        echo "Manifest-Version: 1.0"
        echo "Created-By: ikplugin 1.0"
        echo
        ( cd "$dir" && find . -type f ! -name MANIFEST.MF ! -name SIGNATURE.RSA -print0 | sort -z | \
          while IFS= read -r -d '' f; do
              rel="${f#./}"
              echo "Name: $rel"
              echo "SHA-256-Digest: $(sha256sum "$rel" | cut -d' ' -f1)"
              echo
          done )
    } > "$dir/MANIFEST.MF"
}

# 打包并签名: plugin_pack <目录> <输出zip>
plugin_pack() {
    local dir="$1" out="$2" key
    test -d "$dir" || { plugin_log "目录不存在: $dir"; return 1; }
    key="$(P "$PLUGIN_KEY")"
    plugin_manifest "$dir"
    if test -f "$key"; then
        if openssl dgst -sha256 -sign "$key" -out "$dir/SIGNATURE.RSA" "$dir/MANIFEST.MF" 2>/dev/null; then
            plugin_log "已签名"
        fi
    else
        plugin_log "无私钥, 生成未签名包"
    fi
    ( cd "$dir" && rm -f "$out" 2>/dev/null; zip -q -r "$out" . ) && plugin_log "已打包: $out"
}

# 生成签名密钥对
plugin_keygen() {
    local out="${1:-$(P "$PLUGIN_ROOT")}"
    mkdir -p "$out" 2>/dev/null
    openssl genrsa -out "$out/plugin.key" 2048 2>/dev/null
    openssl rsa -in "$out/plugin.key" -pubout -out "$out/plugin.pub" 2>/dev/null
    plugin_log "私钥: $out/plugin.key  (务必妥善保管)"
    plugin_log "公钥: $out/plugin.pub  -> 复制为 $(P "$PLUGIN_PUBKEY")"
}
