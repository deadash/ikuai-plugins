# 编译与语言选择：shell 优先 → uClibc 交叉编译 → Rust

## 决策顺序

1. **先问能不能用 shell 解决。**
   设备自带 `bash 4.4` + busybox + `sqlite3` + `luajit` + `jq` + `curl` + `openssl` + `flock` + `nc` + `zip/unzip`。
   绝大多数插件(采集、看门狗、配置下发、打补丁、数据统计)纯 shell 就能完成，
   **不用编译 = 不用交叉工具链、不用管 libc、整包小、升级简单**。
   参见 `examples/bnfix-plugin/`(整包约 15KB，零编译)。

2. **需要 C/C++ → 用 iKuai SDK(Buildroot / uClibc-ng 1.0.40)**，动态链接设备自带 libc，产物几百 KB。

3. **要写有类型、有依赖管理的程序 → Rust**。
   - 方式 A(推荐、最简单)：`x86_64-unknown-linux-musl` **静态**链接，自带 libc，一次编译到处跑(~950KB)。
   - 方式 B(体积敏感)：自定义 target + nightly `-Zbuild-std` 动态链接设备 uClibc(未在本仓库实测)。

> 设备是 **uClibc-ng 1.0.40**(`/lib/ld64-uClibc.so.0` → `libuClibc-1.0.40.so`)，**没有 glibc、没有 musl 运行时**，
> 也没有 `gcc/cc/make`。**动态链接的 glibc 二进制在设备上跑不起来**。

## 方式 A：纯 shell（默认，强烈优先）

```bash
# 最小可运行包: 只需要 Release + install.sh(+ boot.sh)
mkdir -p pkg/bin
printf 'plugin=mytool\nversion=1.0.0\n' > pkg/Release
cat > pkg/install.sh <<'EOF'
#!/bin/bash
set -u
ROOT="${PLUGIN_DIR:-/etc/mnt/plugins/mytool}"
"$ROOT/bin/mytool" init
exit 0
EOF
chmod +x pkg/install.sh
cp mytool.sh pkg/bin/mytool && chmod +x pkg/bin/mytool
( cd pkg && zip -qr ../dist/mytool.zip . )
```

## 方式 B：iKuai SDK 交叉编译 C/C++

```bash
mkdir -p /opt/sdk/ikuai && cd /opt/sdk/ikuai
wget https://github.com/deadash/ikuai-sdk/releases/download/v0.0.1/x86_64-buildroot-linux-uclibc_sdk-buildroot.tar.gz  # ~166MiB
tar xf x86_64-buildroot-linux-uclibc_sdk-buildroot.tar.gz
cd x86_64-buildroot-linux-uclibc_sdk-buildroot && ./relocate-sdk.sh "$(pwd)"

export SDK=$PWD
export SDKTARGETSYSROOT="$SDK/x86_64-buildroot-linux-uclibc/sysroot"
export PATH="$SDK/bin:$PATH"
export CC=x86_64-buildroot-linux-uclibc-gcc
export CXX=x86_64-buildroot-linux-uclibc-g++
export CROSS_COMPILE=x86_64-buildroot-linux-uclibc-
export PKG_CONFIG_PATH="$SDKTARGETSYSROOT/usr/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SDKTARGETSYSROOT"

# 先验证工具链(一定要先跑通 hello 再上复杂项目)
printf '#include <stdio.h>\nint main(void){puts("hello uClibc");return 0;}\n' > /tmp/hello.c
$CC /tmp/hello.c -o /tmp/hello && file /tmp/hello    # interpreter /lib/ld64-uClibc.so.0

$CC -O2 -s -o pkg/bin/mytool main.c                  # -s 去符号
$CXX -O2 -s -o pkg/bin/mytool main.cpp               # C++ 注意 libstdc++ 的静态/动态取舍
```

设备端检查链接：`ldd /usr/sbin/mytool`(设备上有 `ldd`)，确认依赖都在设备里。

## 方式 C：Rust

### C.1 musl 静态(仓库默认，已实测)

```bash
rustup target add x86_64-unknown-linux-musl
cd examples/rust-plugin && bash build.sh      # = cargo build --release --target x86_64-unknown-linux-musl + 组包
```

`Cargo.toml` 建议(体积)：

```toml
[profile.release]
opt-level = "z"
lto = true
codegen-units = 1
panic = "abort"
strip = true
```

实测产物：`967,328` 字节二进制 / `464,506` 字节整包；设备上 `file` 显示
`ELF 64-bit LSB pie executable, x86-64, statically linked, stripped`。

### C.2 动态链接 uClibc(体积更小，需自定义 target)

Rust **没有** `x86_64-unknown-linux-uclibc` 内置目标(实测 `rustc --print target-list`)，
需要自定义 target spec + nightly `-Zbuild-std`：

```bash
rustup toolchain install nightly
rustup component add rust-src --toolchain nightly
export CC_x86_64_unknown_linux_uclibc="$SDK/bin/x86_64-buildroot-linux-uclibc-gcc"
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_UCLIBC_LINKER="$CC_x86_64_unknown_linux_uclibc"
export RUSTFLAGS="-L $SDKTARGETSYSROOT/lib -C link-arg=-Wl,-rpath-link,$SDKTARGETSYSROOT/lib"
cargo +nightly build -Z build-std=std,panic_abort --release --target x86_64-ikuai-uclibc.json
```

* 完整的 `x86_64-ikuai-uclibc.json` 与逐步说明见 `examples/rust-plugin/README.md`。
* 风险：`libc` crate 对这个 `env=uclibc` 组合可能报未知平台/缺符号(map 相关)；遇到就退回 musl 静态。
* **这是未在本仓库实测的组合**，动手前先用方式 B 的 C hello 把工具链跑通。

## 二进制怎么进包

把编译产物放到 `pkg/bin/<name>`，框架安装时自动软链到 `/usr/sbin/<name>`。
`bin/*.sh` 会去掉 `.sh` 后缀。**编译产物不要进 git**，用 `.gitignore` 排除 `pkg/bin/`、`dist/`、`target/`。

## 体积参考

| 方式 | 实测/预期 | 依赖设备 libc | 备注 |
| --- | --- | --- | --- |
| 纯 shell | 10~20 KB 整包 | — | 首选 |
| C + uClibc | 几十 KB~几百 KB | 是 | SDK 直接支持 |
| Rust musl 静态 | ~950 KB 二进制 / ~454 KB 整包 | 否 | 最省心 |
| Rust + uClibc | 预期 300~500 KB | 是 | 需自定义 target |
