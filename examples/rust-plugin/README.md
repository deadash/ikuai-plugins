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

## 构建 / 安装

```bash
# 1) 构建(uClibc/musl 设备必须静态链接)
cd examples/rust-plugin
bash build.sh                 # 产出 dist/rustdemo.zip (约 450KB)

# 2) 安装方式 A: 网页
#    系统设置 -> 插件管理 -> ikguard -> 插件管理 -> 选择 rustdemo.zip -> 上传并安装

# 3) 安装方式 B: 命令行
scp/上传 rustdemo.zip 到设备后:
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
2. **必须静态编译**: 设备是 uClibc(`/lib/ld64-uClibc.so.0`)，动态 glibc 二进制跑不起来；
   `x86_64-unknown-linux-musl` + 纯 Rust 依赖(不引入需要 C 工具链的 crate)最省事。
3. **守护进程要抗挂断**: 设备没有 `nohup`/`setsid`，脚本里用
   `( trap '' HUP; exec <二进制> ... ) &` 拉起，否则父进程(安装脚本/SSH 会话)一退守护就跟着没。
4. **根分区每次重启还原**: 数据/日志一定放 `/etc/mnt/...` 或 `/etc/log/...`，不要写 `/`。
5. **Web 接口参数不能带空格和引号**(lua 侧会拒绝)，备注这类自由文本用 `+` 代替空格，后端再还原。
