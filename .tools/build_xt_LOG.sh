#!/bin/bash
#
# 重新生成 lib/xtables/libxt_LOG.so (随框架分发的 iptables LOG 用户态扩展)
#
# 背景(结论: iKuai 3.7.16 实测**不需要**这个 .so, 留作备用):
#   设备内核编了 LOG 目标(CONFIG_NETFILTER_XT_TARGET_LOG=y), 需要用户态扩展才能用
#   `iptables -j LOG`。实测 iKuai 3.7.16 x64 的 /usr/sbin/iptables **自带** LOG
#   (strace 显示它根本不 dlopen libxt_LOG.so, `iptables -j LOG -h` 直接能列出
#    --log-prefix, 加规则后内核日志也确实出现命中记录), 所以框架不再分发该 .so。
#
#   仅当遇到"iptables -j LOG -h 里没有 log-prefix"的固件时, 才需要用它补:
#       bash .tools/build_xt_LOG.sh
#       cp lib/xtables/libxt_LOG.so <设备>/usr/lib/iptables/     (或设 XTABLES_LIBDIR)
#
#   注意: 曾经把 `iptables -C OUTPUT -j LOG` 的
#   "No chain/target/match by that name" 误判成"缺 LOG 扩展" —— 那是 -C 的
#   "规则不存在"报错; 判可用性要用 `iptables -j LOG -h | grep log-prefix`。
#
# 为什么这样编:
#   * 设备是 x86_64 + uClibc-ng 1.0.40, 宿主 glibc 编出来的 .so 在设备上加载不了;
#     所以用 -nostdlib 编"零 libc 依赖"的 .so: 不写 DT_NEEDED,
#     运行时 printf/puts/strchr 由进程内已加载的 libc 解析,
#     xtables_* 由设备自带的 libxtables.so.12 解析(iptables 进程里已经是全局符号)。
#   * 必须用**同版本** iptables 源码的 xtables.h, 才能保证扩展 ABI 一致
#     (设备 iptables 1.8.3 / libxtables.so.12)。
#
# 用法: bash .tools/build_xt_LOG.sh    (需要 gcc/curl; 产物覆盖 lib/xtables/libxt_LOG.so)
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/tmp/xtbuild}"
VER="1.8.3"
OUT="$REPO_DIR/lib/xtables/libxt_LOG.so"

mkdir -p "$WORK"
cd "$WORK"

if [ ! -d "iptables-$VER" ]; then
    curl -sSLO "https://www.netfilter.org/pub/iptables/iptables-$VER.tar.bz2"
    tar xf "iptables-$VER.tar.bz2"
fi
cd "iptables-$VER"

# configure 才会生成 xtables-version.h; 我们只需要那个头文件, 直接写出来
printf '#define XTABLES_VERSION "libxtables.so.12"\n#define XTABLES_VERSION_CODE 12\n' \
    > include/xtables-version.h

# ARRAY_SIZE 正常由 iptables 的 config.h 提供, 这里用 -include 补上
cat > "$WORK/pre.h" <<'EOF'
#ifndef ARRAY_SIZE
#define ARRAY_SIZE(x) (sizeof(x) / sizeof(*(x)))
#endif
EOF

mkdir -p "$(dirname "$OUT")"
gcc -O2 -fPIC -shared -nostdlib -fno-stack-protector \
    -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 \
    -include "$WORK/pre.h" \
    -I. -Iinclude \
    -o "$OUT" extensions/libipt_LOG.c

echo "已生成: $OUT"
readelf -d "$OUT" | grep -c NEEDED || true
nm -D "$OUT" | grep ' U ' || true
