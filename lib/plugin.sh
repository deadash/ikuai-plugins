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
            cp -rf "$src"/. "$dest"/
        fi
    else
        case "$src" in
            *.zip|*.ZIP) ;;
            *) plugin_log "不支持的包(需为 zip): $src"; return 1 ;;
        esac
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
        mv "$tmp" "$dest"
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

# 暴露命令行 /usr/sbin/ikplugin
plugin_link_cli() {
    mkdir -p "$(P /usr/sbin)" 2>/dev/null
    ln -sf "$(P /etc/mnt/.boot/bin/ikplugin)" "$(P /usr/sbin)/ikplugin" 2>/dev/null
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
        zcat "$f" 2>/dev/null | grep -q -e "Plugin_management" -e "plugins/docker/" -e "tipCloudBind" 2>/dev/null || continue

        tmp="$(mktemp)"; patched="$(mktemp)"; gz="$(mktemp)"
        if ! zcat "$f" > "$tmp" 2>/dev/null; then
            rm -f "$tmp" "$patched" "$gz"; continue
        fi

        want_ub=0; want_dir=0; want_title=0; want_bind=0; want_label=0
        grep -q 'yunbindstatus=""!=i.code?2:1' "$tmp" 2>/dev/null && want_ub=1
        grep -q 'plugins/docker/' "$tmp" 2>/dev/null && want_dir=1
        grep -q 't\._v("Docker")' "$tmp" 2>/dev/null && want_title=1
        grep -q 'tipCloudBind=!0' "$tmp" 2>/dev/null && want_bind=1
        grep -q '_s(e\.name)' "$tmp" 2>/dev/null && want_label=1
        if [ "$want_ub" = 0 ] && [ "$want_dir" = 0 ] && [ "$want_title" = 0 ] && \
           [ "$want_bind" = 0 ] && [ "$want_label" = 0 ]; then
            rm -f "$tmp" "$patched" "$gz"; continue
        fi

        sed -e 's|yunbindstatus=""!=i.code?2:1|yunbindstatus=2|g' \
            -e 's|plugins/docker/|plugins/app/|g' \
            -e 's|t\._v("Docker")|t._v("插件")|g' \
            -e 's|\.tipCloudBind=!0|.tipCloudBind=!1|g' \
            -e 's@_s(e\.name)@_s(e.title||e.name)@g' "$tmp" > "$patched"

        if gzip -9 -c < "$patched" > "$gz" 2>/dev/null && \
           { [ "$want_ub" = 0 ] || zcat "$gz" 2>/dev/null | grep -q 'yunbindstatus=2'; } && \
           { [ "$want_dir" = 0 ] || zcat "$gz" 2>/dev/null | grep -q 'plugins/app/'; } && \
           { [ "$want_title" = 0 ] || zcat "$gz" 2>/dev/null | grep -q 't._v("插件")'; } && \
           { [ "$want_bind" = 0 ] || zcat "$gz" 2>/dev/null | grep -q 'tipCloudBind=!1'; } && \
           { [ "$want_label" = 0 ] || zcat "$gz" 2>/dev/null | grep -q 'e.title||e.name'; }; then
            cat "$gz" > "$f"
            n=$((n + 1))
            plugin_log "  已打补丁: $(basename "$f") (云拦截=$want_ub 目录=$want_dir 标题=$want_title 云弹框=$want_bind 卡片名=$want_label)"
        else
            plugin_log "  补丁未生效(保留原文件): $(basename "$f")"
        fi
        rm -f "$tmp" "$patched" "$gz"
    done
    plugin_log "Web 前端补丁完成(修改 $n 个分包)"
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
