#!/bin/bash
#
# 模拟设备端挂载校验(打包后必跑) —— 复刻 /usr/ikuai/script/plugins.sh:boot() 的逻辑:
#
#   1) openssl dgst -sha256 -verify <固件内置公钥> -signature SIGNATURE.RSA MANIFEST.MF
#   2) 逐行读 MANIFEST.MF 的 Name/SHA-256-Digest, 与 /etc/mnt/.boot 下实际文件比对
#   3) test -x /etc/mnt/.boot/install.sh
#   三条全过才会执行 install.sh 并写 /etc/plugins_ok=1
#
# 任何一条不过 → 设备上整包不挂载(框架/SSH/Web 插件全部不生效)。
#
# 用法:
#   bash .tools/verify_package.sh [包路径]      # 默认 .dist/custom.bin
#
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.." || exit 1
BIN="${1:-.dist/custom.bin}"
PUBKEY="$SCRIPT_DIR/public.pem"

test -f "$BIN" || { echo "找不到包: $BIN"; exit 1; }
test -f "$PUBKEY" || { echo "找不到公钥: $PUBKEY"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- 1) 拆包: 4 字节大端头长度 + 头部(gzip, 去掉前 10 字节) + tar.gz ----
HEADLEN=$(printf "%u" 0x$(hexdump -v -n 4 "$BIN" -e '4/1 "%02x"'))
mkdir -p "$TMP/pack" "$TMP/boot"
tail -c +$((4 + HEADLEN + 1)) "$BIN" | tar xz -C "$TMP/pack" || exit 1

# ---- 2) 复刻 install.sh 的铺设规则, 得到设备上 .boot 的真实布局 ----
for f in "$TMP"/pack/*; do
    name="$(basename "$f")"
    case "$name" in
        .*)      continue ;;                 # 点开头不拷
        install.sh) continue ;;              # install.sh 自己不拷进 .boot
        boot.sh) cp -p "$f" "$TMP/boot/install.sh"; chmod +x "$TMP/boot/install.sh"; continue ;;
    esac
    cp -rp "$f" "$TMP/boot/"
done

# ---- 3) 校验 ----
FAIL=0
printf '== 包内文件: %s 个, 实际铺开: %s 个\n' \
    "$(find "$TMP/pack" -type f | wc -l)" "$(find "$TMP/boot" -type f | wc -l)"

if [ ! -f "$TMP/boot/MANIFEST.MF" ] || [ ! -f "$TMP/boot/SIGNATURE.RSA" ]; then
    echo "[FAIL] 包内缺少 MANIFEST.MF / SIGNATURE.RSA"; exit 1
fi

echo "== 1) 签名校验(用 .tools/public.pem)"
if openssl dgst -sha256 -verify "$PUBKEY" \
        -signature "$TMP/boot/SIGNATURE.RSA" "$TMP/boot/MANIFEST.MF" >/dev/null 2>&1; then
    echo "   OK"
else
    echo "   [FAIL] 签名验证失败"; FAIL=1
fi

echo "== 2) 清单摘要比对(设备端逐条 sha256sum)"
LISTED=0; BAD=0
cur=""
while IFS= read -r line; do
    case "$line" in
        "Name: "*) cur="${line#Name: }"; LISTED=$((LISTED + 1)) ;;
        "SHA-256-Digest: "*)
            exp="${line#SHA-256-Digest: }"
            p="$TMP/boot/$cur"
            if [ ! -f "$p" ]; then
                echo "   缺失: $cur"; BAD=$((BAD + 1))
            else
                act=$(sha256sum "$p" | cut -d' ' -f1)
                [ "$act" = "$exp" ] || { echo "   摘要不一致: $cur"; BAD=$((BAD + 1)); }
            fi
            ;;
    esac
done < "$TMP/boot/MANIFEST.MF"
echo "   清单 $LISTED 条, 异常 $BAD 条"
[ "$BAD" = 0 ] || FAIL=1

echo "== 3) install.sh 可执行"
if [ -x "$TMP/boot/install.sh" ]; then echo "   OK"; else echo "   [FAIL] install.sh 不可执行"; FAIL=1; fi

# ---- 4) 额外提示: 清单里有、但没打进包的(反向检查) ----
echo "== 4) 反向检查: 包内文件是否都在清单里"
while IFS= read -r f; do
    rel="${f#$TMP/boot/}"
    case "$rel" in MANIFEST.MF|SIGNATURE.RSA|install.sh) continue ;; esac
    grep -q "^Name: $rel$" "$TMP/boot/MANIFEST.MF" || { echo "   未列入清单: $rel"; BAD=$((BAD + 1)); FAIL=1; }
done < <(find "$TMP/boot" -type f)

echo
if [ "$FAIL" = 0 ]; then
    echo ">>> 通过: 该包在设备上可正常挂载(签名+清单+install.sh 均 OK)"
else
    echo ">>> 失败: 该包在设备上不会挂载! 修好再发版"
fi
exit "$FAIL"
