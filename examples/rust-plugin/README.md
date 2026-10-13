# rustdemo - Rust 示例插件(插件开发模板)

这个目录是一个**完整的第三方插件示例**，用 Rust 写一个采集守护进程 + 嵌入式数据库 +
Web 配置页，用来演示插件框架的全部能力，同时也可以直接当作自己写插件的模板。

## 它演示了什么

| 能力 | 实现位置 |
| --- | --- |
| 安装 / 卸载 | `pkg/install.sh`、`pkg/uninstall.sh`(由框架在 install/uninstall 动作时执行) |
| 开机自启 | `pkg/boot.sh`(框架每次开机调用, 优先级高于 install.sh) |
| 命令行入口 | `pkg/bin/rustdemo` → 框架自动软链到 `/usr/sbin/rustdemo` |
| 前端设置页 | `pkg/www/plugins/app/rustdemo.html` → 软链到 `/usr/ikuai/www/plugins/app/` |
| 插件卡片 | `pkg/www/plugins/rustdemo/rustdemo.json` → 软链到 `/usr/ikuai/www/plugins/rustdemo/` |
| 后端接口 | `pkg/function/rustdemo` → 软链到 `/usr/ikuai/function/rustdemo`(`func_name=rustdemo`) |
| **持久化 + 数据库** | redb 嵌入式数据库, 落地在 `/etc/mnt/plugins/rustdemo/data/rustdemo.redb`(持久分区, 重启不丢) |
| 守护进程 + IPC | 守护进程独占数据库(redb 是独占锁), 命令行/后端通过 Unix socket 查询 |

插件包内 `www/` 与 `function/` 这两个目录由框架自动识别并建立软链（`lib/plugin.sh:plugin_web_link()`），
卸载时由 `plugin_unlink()` 精确清理，所以你不需要自己在 install.sh 里手工维护这些链接。

## 目录结构

```
examples/rust-plugin/
├── Cargo.toml / src/main.rs     Rust 源码(单文件, 只依赖 redb + serde_json)
├── build.sh                     一键: 编译 musl 静态二进制 + 组装 pkg/ + 打成 dist/rustdemo.zip
└── pkg/                         插件包骨架(= 会被 zip 的内容)
    ├── Release                  plugin=rustdemo / version=1.0.0
    ├── install.sh               安装: 初始化数据库 + 拉起守护进程
    ├── boot.sh                  每次开机: 重新拉起守护进程
    ├── uninstall.sh             卸载: 停守护 + 清理
    ├── bin/rustdemo             编译产物(build.sh 生成)
    ├── function/rustdemo        后端接口: show/seting/clear/sample
    └── www/plugins/...          前端页面 + 卡片元数据 + 图标
```

## 编译方式(两条路都可行)

设备是 **uClibc-ng 1.0.40**(`/lib/ld64-uClibc.so.0` → `libuClibc-1.0.40.so`)，既没有 glibc 也没有
musl 运行时。所以二进制要么**静态链接**(自带 libc)，要么**动态链接到设备自带的 uClibc**。
下面两种方式都能用，体积/通用性各有取舍。

### 方式 A: musl 静态链接(仓库默认, 本机已实测)

纯 Rust 依赖(redb / serde_json 都不需要 C 工具链)，`rustup` 一条命令就能加目标，产物自带 libc。

```bash
# 1) 构建
rustup target add x86_64-unknown-linux-musl
cd examples/rust-plugin
bash build.sh          # = cargo build --release --target x86_64-unknown-linux-musl + 组装 pkg/ + 打 zip
                       # 等价于: cargo build --release --target x86_64-unknown-linux-musl

# 2) 安装
#    A. 网页: 系统设置 -> 插件管理 -> ikguard -> 插件管理 -> 选择 rustdemo.zip -> 上传并安装
#    B. 命令行: 上传 rustdemo.zip 后  ikplugin install /root/rustdemo.zip
```

实测数据(本机 rustc 1.98.1；`Cargo.toml` 已开 `opt-level=z + lto + codegen-units=1 + panic=abort + strip`)：

| 产物 | 大小 |
| --- | --- |
| `pkg/bin/rustdemo`(static-pie, stripped) | **967,328 字节 ≈ 945 KB** |
| `dist/rustdemo.zip`(整包) | **464,506 字节 ≈ 454 KB** |

设备侧验证：

```bash
# file /etc/mnt/plugins/rustdemo/bin/rustdemo
ELF 64-bit LSB pie executable, x86-64, statically linked, stripped
# /usr/sbin/rustdemo stats
{"samples":159,"db_size":2293760,"interval":"15","retention":"500","daemon_running":true,...}
```

- 优点：一次编译到处跑，不依赖设备 libc 版本；没有静态 glibc 那堆(nss/dlopen)坑。
- 缺点：体积大(自己带了一份 libc)，约 950 KB。

### 方式 B: iKuai SDK 交叉编译 uClibc(体积最小)

[iKuai SDK](https://github.com/deadash/ikuai-sdk) 是 Buildroot 出的
`x86_64-buildroot-linux-uclibc` 工具链，里面的 uClibc 与设备**同版本 1.0.40**，
用它编译可以动态链接设备自带的 `/lib/ld64-uClibc.so.0`，二进制不再内嵌 libc。

#### B.0 准备 SDK

```bash
mkdir -p /opt/sdk/ikuai && cd /opt/sdk/ikuai
# release 资产: x86_64-buildroot-linux-uclibc_sdk-buildroot.tar.gz (174,297,502 字节 ≈ 166 MiB)
#              解压后约 520 MB
wget https://github.com/deadash/ikuai-sdk/releases/download/v0.0.1/x86_64-buildroot-linux-uclibc_sdk-buildroot.tar.gz
tar xf x86_64-buildroot-linux-uclibc_sdk-buildroot.tar.gz
cd x86_64-buildroot-linux-uclibc_sdk-buildroot
./relocate-sdk.sh "$(pwd)"     # 把工具链内部写死的绝对路径改到当前目录
```

解压后的布局(实测)：

```
x86_64-buildroot-linux-uclibc_sdk-buildroot/
├── bin/x86_64-buildroot-linux-uclibc-gcc       交叉编译器(另有短别名 x86_64-linux-gcc)
├── bin/x86_64-buildroot-linux-uclibc-g++       C++ 编译器
└── x86_64-buildroot-linux-uclibc/sysroot/      目标 sysroot
    ├── lib/libc.so.0                           uClibc-ng 1.0.40(与设备一致)
    ├── lib/ld64-uClibc.so.0                    动态加载器
    ├── include/                                uClibc 头文件
    └── usr/lib/libc.so
```

环境变量(官方 README 的写法，注意 sysroot 的实际路径)：

```bash
export SDK=/opt/sdk/ikuai/x86_64-buildroot-linux-uclibc_sdk-buildroot
export SDKTARGETSYSROOT="$SDK/x86_64-buildroot-linux-uclibc/sysroot"
export PATH="$SDK/bin:$PATH"
export CC=x86_64-buildroot-linux-uclibc-gcc
export CXX=x86_64-buildroot-linux-uclibc-g++
export CROSS_COMPILE=x86_64-buildroot-linux-uclibc-
export PKG_CONFIG_PATH="$SDKTARGETSYSROOT/usr/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SDKTARGETSYSROOT"
```

自检(先确认工具链真的产出 uClibc 动态二进制，再决定要不要上 Rust)：

```bash
cat > /tmp/hello.c <<'EOF'
#include <stdio.h>
int main(void) { printf("hello from uClibc\n"); return 0; }
EOF
$CC /tmp/hello.c -o /tmp/hello
file /tmp/hello     # ELF 64-bit LSB executable, ..., interpreter /lib/ld64-uClibc.so.0
ls -l  /tmp/hello   # 约 8~16 KB
# 传到设备跑: scp /tmp/hello sshd@<设备>:/tmp/ && /tmp/hello
```

#### B.1 C / C++ 插件(体积最敏感时用这条)

SDK 直接支持，把编译产物放进插件包的 `bin/` 即可(框架会自动软链到 `/usr/sbin`):

```bash
$CC -O2 -s -o myplug main.c            # -s 去符号
$CXX -O2 -s -o myplug main.cpp         # C++ 记得 -static-libstdc++ 或确认设备有对应 .so
# 组装插件包(最少只要 Release + install.sh + bin/xxx)
mkdir -p pkg/bin && cp myplug pkg/bin/
printf 'plugin=myplug\nversion=1.0.0\n' > pkg/Release
printf '#!/bin/bash\nexit 0\n' > pkg/install.sh && chmod +x pkg/install.sh
( cd pkg && zip -qr ../myplug.zip . )
```

#### B.2 Rust + uClibc 动态链接(需要自定义 target, 未在本机实测)

Rust 官方**没有** `x86_64-unknown-linux-uclibc` 目标 —— 实测
`rustc --print target-list | grep -i uclibc` 只有：

```
armv5te-unknown-linux-uclibceabi
armv7-unknown-linux-uclibceabi
armv7-unknown-linux-uclibceabihf
mips-unknown-linux-uclibc
mipsel-unknown-linux-uclibc
x86_64-unknown-l4re-uclibc
```

所以要走自定义 target spec + nightly 的 `-Zbuild-std`(从源码编译 std / panic_abort)。示例
`x86_64-ikuai-uclibc.json`(放在 `examples/rust-plugin/` 下)：

```json
{
  "llvm-target": "x86_64-unknown-linux-gnu",
  "data-layout": "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128",
  "arch": "x86_64",
  "target-endian": "little",
  "target-pointer-width": "64",
  "target-c-int-width": "32",
  "os": "linux",
  "env": "uclibc",
  "vendor": "unknown",
  "linker": "x86_64-buildroot-linux-uclibc-gcc",
  "linker-flavor": "gcc",
  "dynamic-linking": true,
  "crt-static-default": false,
  "crt-static-respected": true,
  "executables": true,
  "has-elf-tls": true,
  "max-atomic-width": 64,
  "panic-strategy": "abort",
  "position-independent-executables": true,
  "relro-level": "full",
  "stack-probes": { "kind": "none" }
}
```

编译：

```bash
rustup toolchain install nightly
rustup component add rust-src --toolchain nightly

export CC_x86_64_unknown_linux_uclibc="$SDK/bin/x86_64-buildroot-linux-uclibc-gcc"
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_UCLIBC_LINKER="$CC_x86_64_unknown_linux_uclibc"
export RUSTFLAGS="-L $SDKTARGETSYSROOT/lib -C link-arg=-Wl,-rpath-link,$SDKTARGETSYSROOT/lib"

cd examples/rust-plugin
cargo +nightly build -Z build-std=std,panic_abort --release \
      --target x86_64-ikuai-uclibc.json
```

注意事项：

1. `libc` crate(redb 依赖它做 mmap)对这个自定义 `env=uclibc` 组合可能报未知平台/缺符号；
   真遇到就只能改依赖或退回方式 A —— **这是未验证组合, 先用 B.0 的 C hello 打通工具链再说**。
2. uClibc 版本必须与设备一致：SDK 是 1.0.40 ↔ 设备 `libuClibc-1.0.40.so` ✓。
3. 产物仍是 PIE + 动态，设备有 `/lib/ld64-uClibc.so.0`，直接放 `bin/` 就能跑；
   `ldd` 用 SDK 的 `x86_64-buildroot-linux-uclibc-objdump -p` 或设备上的 `ldd` 检查。
4. 打包/安装流程与方式 A 完全相同，`build.sh` 里的 `cargo build` 换成上面这条即可。

### 体积与取舍

| | 方式 A: musl 静态 | 方式 B: SDK uClibc 动态 |
| --- | --- | --- |
| 实测二进制 | 945 KB | 预期 300~500 KB(未实测) |
| 依赖设备 libc | 否(自带) | 是(必须版本匹配) |
| Rust 支持 | 官方内置 target ✓ | 需自定义 target + nightly ✗ |
| C/C++ 支持 | 需要 musl 交叉工具链 | SDK 直接支持 ✓ |
| 推荐场景 | 默认/通用、纯 Rust 插件 | 体积敏感、或本来就用 C/C++ 写的插件 |

> 本仓库**只实测了方式 A**(967,328 字节)；方式 B 的步骤来自 iKuai SDK 官方 README + 本机实际
> 解压/relocate 得到的目录结构，其中的 Rust 路线(Rust 无 x86_64-uclibc 内置目标)需要在
> 你自己的环境实测。

## 安装 / 使用

```bash
# 1) 安装方式 A: 网页
#    系统设置 -> 插件管理 -> ikguard -> 插件管理 -> 选择 rustdemo.zip -> 上传并安装

# 2) 安装方式 B: 命令行
上传 rustdemo.zip 到设备后:
   ikplugin install /root/rustdemo.zip
   或者 cp rustdemo.zip /etc/mnt/plugins/ && ikplugin scan
```

## 插件包格式(实测约定)

```
Release           必需  plugin=<名称>  version=<版本>   (名称决定安装目录与卡片名)
install.sh        必需  安装/每次"安装"动作执行(需幂等)
boot.sh           可选  仅开机执行(存在时优先于 install.sh)
uninstall.sh      可选  卸载
bin/*             可选  自动软链到 /usr/sbin(去掉 .sh 后缀)
etc/*             可选  自动软链到 /usr/local/etc
www/plugins/<n>/<n>.json  可选  插件卡片(名字必须与 <n> 一致)
www/plugins/app/<n>.html  可选  插件页面(iframe 打开, 路径由前端补丁固定为 app)
www/plugins/app/<n>.png   可选  卡片图标(建议 64x64)
function/<func_name>      可选  后端接口(shebang 必须是 #!/bin/bash /etc/ikcommon)
MANIFEST.MF / SIGNATURE.RSA 可选  插件包不强制签名(带清单才校验摘要)
```

> **签名策略**: 框架本体(`/etc/mnt/.boot`)必须用配对的私钥签名，否则固件校验不过、整个框架不运行；
> **插件包不需要签名**，第三方插件可以直接 zip 上传安装。

## 命令行为(直接跑二进制)

```bash
rustdemo [--db <路径>] <命令>

daemon            守护进程: 周期采集 + Unix socket 服务
status/stats      状态与统计(JSON)
tail [n]          最近 n 条采样(JSON)
config            读取配置(JSON)
get <k> / set <k> <v>   读写配置项: interval(2~86400 秒) / retention(10~100000) / note
sample            立刻采集一条
clear             清空采样数据(保留配置)
drop / init       删表 / 初始化
```

设备上例子:

```bash
/usr/sbin/rustdemo stats
/usr/sbin/rustdemo set interval 10
/usr/sbin/rustdemo tail 5
/usr/sbin/rustdemo --db /etc/mnt/plugins/rustdemo/data/rustdemo.redb config
```

## 关键实现点(写自己插件时可以参考)

1. **redb 是独占锁**: 守护进程持有数据库时另一个进程 `open` 会报
   `Database already open. Cannot acquire lock.`
   → 本示例让守护进程在 `data/rustdemo.sock` 上开一个 Unix socket，命令行与后端接口都发一行命令、
   收一行 JSON；守护不在(比如还没装/已停)时才直接开库，两边共用同一套实现函数。
2. **链接方式要选对**: 设备是 uClibc-ng 1.0.40(`/lib/ld64-uClibc.so.0`)，动态 glibc 二进制跑不起来。
   要么用 `x86_64-unknown-linux-musl` 静态(本仓库默认，见上文"方式 A")，要么用 iKuai SDK 的
   uClibc 工具链动态链接设备自带 libc(见上文"方式 B")。
3. **守护进程要抗挂断**: 设备没有 `nohup`/`setsid`，脚本里用
   `( trap '' HUP; exec <二进制> ... ) &` 拉起，否则父进程(安装脚本/SSH 会话)一退守护就跟着没。
4. **根分区每次重启还原**: 数据/日志一定放 `/etc/mnt/...` 或 `/etc/log/...`，不要写 `/`。
5. **Web 接口参数不能带空格和引号**(lua 侧会拒绝)，备注这类自由文本用 `+` 代替空格，后端再还原。
