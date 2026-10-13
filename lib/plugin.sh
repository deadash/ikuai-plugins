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
PLUGIN_VERIFY="$(get_flag plugins_verify 0)"

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

# 插件包校验: 有清单则校验摘要; 有签名+公钥则校验签名; plugins_verify=1 时强制要求签名
plugin_verify() {
    local dir="$1" key
    key="$(P "$PLUGIN_PUBKEY")"

    if test -f "$dir/MANIFEST.MF"; then
        plugin_check_manifest "$dir" || return 1
        if test -f "$dir/SIGNATURE.RSA"; then
            if test -f "$key"; then
                plugin_check_signature "$dir" "$key" || { plugin_log "签名校验失败"; return 1; }
            else
                plugin_log "无公钥, 仅校验摘要"
            fi
        elif test "$PLUGIN_VERIFY" = "1"; then
            plugin_log "缺少 SIGNATURE.RSA 且 plugins_verify=1"
            return 1
        fi
    elif test "$PLUGIN_VERIFY" = "1"; then
        plugin_log "缺少 MANIFEST.MF 且 plugins_verify=1"
        return 1
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

# 删除指向某插件目录的所有软链接
plugin_unlink() {
    local dir="$1" base item
    for base in "$(P /usr/sbin)" "$(P /usr/local/etc)"; do
        test -d "$base" || continue
        find "$base" -maxdepth 4 -type l -print0 2>/dev/null | \
        while IFS= read -r -d '' item; do
            case "$(readlink "$item" 2>/dev/null)" in "$dir"/*) rm -f "$item" ;; esac
        done
    done
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
    local src="$1" name dest tmp
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
        name=$(plugin_name "$tmp")
        if ! plugin_verify "$tmp"; then
            rm -rf "$tmp"
            return 1
        fi
        dest="$(P "$PLUGIN_ROOT")/$name"
        rm -rf "$dest"
        mkdir -p "$(dirname "$dest")"
        mv "$tmp" "$dest"
    fi

    plugin_log "安装插件: $name (版本 $(plugin_version "$dest"))"
    plugin_run "$dest" "install"
    plugin_link "$dest"
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
#   <boot>/www/plugins/<name>/<name>.json  -> /usr/ikuai/www/plugins/<name>/<name>.json
#   <boot>/www/plugins/docker/<name>.html  -> /usr/ikuai/www/plugins/docker/<name>.html
# 说明: iKuai 前端(/usr/ikuai/function/plugins 的 __show_data)会读取
#       /usr/ikuai/www/plugins/*/*.json 生成"系统设置->插件管理"卡片列表,
#       卡片点击后以 iframe 打开 /plugins/docker/<name>.html
plugin_web_sync() {
    local src="$PLUGIN_WWW_SRC/plugins" dst="$PLUGIN_WWW_DST" f d
    test -d "$src" || return 0
    mkdir -p "$dst" 2>/dev/null

    find "$src" -mindepth 2 -maxdepth 2 -name '*.json' -print0 2>/dev/null | \
    while IFS= read -r -d '' f; do
        d="$(basename "$(dirname "$f")")"
        mkdir -p "$dst/$d" 2>/dev/null
        cp -f "$f" "$dst/$d/" 2>/dev/null
    done

    test -d "$src/docker" && {
        mkdir -p "$dst/docker" 2>/dev/null
        find "$src/docker" -maxdepth 1 -type f -print0 2>/dev/null | \
        while IFS= read -r -d '' f; do
            cp -f "$f" "$dst/docker/" 2>/dev/null
        done
    }
    plugin_log "Web 插件资源已同步: $dst"
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
