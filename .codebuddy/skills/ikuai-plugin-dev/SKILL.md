---
name: ikuai-plugin-dev
description: This skill should be used when creating, packaging, deploying or debugging iKuai (爱快) third-party plugin packages for the ikuai-plugins framework (firmwareid=90001) — writing Release/install.sh/boot.sh/uninstall.sh, Web cards/pages and backend function interfaces, sqlite3 (3.8.11) storage scripts, LuaJIT helper calls, compiling with the iKuai uClibc SDK or Rust, and testing install/uninstall/reboot over SSH on a real device. Covers plugin packages only; the base framework package (.boot, which must be signed) is out of scope.
---

# iKuai 插件开发

为 iKuai (爱快) x64 路由上的 **ikuai-plugins 框架**编写第三方**插件包**。
框架本体(`/etc/mnt/.boot`，必须签名)不在本技能范围内 —— 这里只做插件包。

## 三条红线

1. **只交付插件包，不动基础包。**
   插件包是普通 zip(`Release` + `install.sh` 即可)，**不需要签名**；框架本体必须用配对私钥签名，失败则整机不挂载。
   插件的 Web 资源与后端接口由框架自动软链到根分区，**不要自己往 `/usr/ikuai/...` 写文件**。
2. **数据与日志只能写持久分区。**
   根分区 `/`(111MB) **每次重启从固件镜像还原**；持久的是 `/etc/mnt`(43MB) 与 `/etc/log`(15.5G)。
   插件的库/状态放 `/etc/mnt/plugins/<name>/data/`，日志放 `/etc/log/`。往根分区放大文件必然失败。
3. **优先 shell，其次 uClibc 编译，要写代码用 Rust。**
   设备自带 bash 4.4 + busybox + sqlite3 + LuaJIT + jq + curl + openssl，绝大多数需求纯 shell 就能解决。
   需要 C/C++ 时用 **iKuai SDK(uClibc-ng 1.0.40，与设备同版本)** 交叉编译；
   需要写较复杂程序时用 **Rust**(musl 静态最简单，或自定义 target 走 uClibc)。详见 `references/build.md`。
4. **插件页一律用统一 UI 套件 ikui（Element Plus + 设计令牌），不要自己写样式。**
   **套件由基础包提供**（`/plugins/app/ikui.js`、`ikui.css`，开机软链自
   `/etc/mnt/.boot/www/ui/`），**插件不需要带**，页面里就两行：
   `<link rel="stylesheet" href="./ikui.css">` + `<script src="./ikui.js"></script>`
   目标是**插件之间统一好看、改一处全局生效**；**不要**去抄爱快前端的样式
   （它的组件库拿不到、内部类名扒不完，试过，是精力黑洞）。
   详见 `references/ui.md`，用法权威在 `<skill>/assets/ui/README.md`。

## 标准流程

```bash
# 0) 脚手架(从已验证模板生成, 自动改名)
bash <skill>/scripts/new-plugin.sh mytool ~/work/mytool

# 1) 写逻辑(默认模板已含 shell + sqlite3 + LuaJIT + Web 页 + 开机自启)
#    ~/work/mytool/pkg/bin/mytool          CLI / 守护进程
#    ~/work/mytool/pkg/function/mytool     Web 后端接口(action)
#    ~/work/mytool/pkg/www/plugins/app/mytool.html  页面
#    ~/work/mytool/pkg/Release             plugin=mytool / version / comment

# 2) 打包(zip 保留执行位; 先 chmod +x install.sh 等)
bash ~/work/mytool/build.sh

# 3) 真机安装(SSH 推送 -> ikplugin install)
export IK_PASS='<控制台密码>'
bash <skill>/scripts/deploy-plugin.sh ~/work/mytool/dist/mytool.zip --install

# 4) 观测 / 重启验证自启 / 卸载
bash <skill>/scripts/deploy-plugin.sh --status
bash <skill>/scripts/deploy-plugin.sh --reboot
bash <skill>/scripts/deploy-plugin.sh --remove mytool --reboot
```

## 插件包格式速查

```
Release            必需  plugin=<名称>  version=<版本>  [comment=...]
                         -> 名称决定安装目录 /etc/mnt/plugins/<名称> 与卡片名
install.sh         必需  安装动作执行, 必须幂等
boot.sh            可选  每次开机执行(存在时优先于 install.sh) —— 自启动的关键
uninstall.sh       可选  卸载动作执行(框架随后删目录并清理软链)
bin/*              可选  自动软链到 /usr/sbin/, 去掉 .sh 后缀
etc/*              可选  自动软链到 /usr/local/etc/
www/plugins/<n>/<n>.json   可选  插件卡片(<n> 必须等于文件名)
www/plugins/app/<n>.html   可选  插件页面(iframe 打开, 目录被改名为 app)
www/plugins/app/<n>.png    可选  卡片图标(建议 64x64)
function/<func_name>       可选  后端接口(shebang 必须是 #!/bin/bash /etc/ikcommon)
MANIFEST.MF/SIGNATURE.RSA  可选  带清单才校验 SHA-256; 插件不强制签名
```

脚本执行时框架传入环境变量：`PLUGIN_NAME` `PLUGIN_VERSION` `PLUGIN_DIR` `PLUGIN_ROOT` `PLUGIN_ACTION`(install/boot/uninstall) `IK_SYSROOT`。

## 生命周期(一句话版)

| 时机 | 框架做什么 | 插件要做什么 |
| --- | --- | --- |
| 安装 | 解压到 `/etc/mnt/plugins/<名>` → 跑 `install.sh` → 链接 bin/etc/www/function | 初始化数据、拉起进程，**幂等** |
| 开机 | 校验 → 跑 `boot.sh` → 重建全部软链 | **重新拉起进程**(根分区还原 + 进程已死) |
| 卸载 | 跑 `uninstall.sh` → 删目录 → 清理所有指向它的软链 | 停进程、停定时任务 |
| 升级 | 保留 `data/` 目录后覆盖其余文件，再走安装流程 | 版本迁移逻辑写在 `install.sh` |

## 自启动与持久化的唯一正确姿势

根分区每次重启还原、进程重启即死，所以"自启动"= **`boot.sh` 里重新拉起**。
设备**没有 `nohup`/`setsid`/`timeout`**，后台常驻必须这样写：

```bash
( trap '' HUP; exec "$ROOT/bin/myplugin" daemon >> /etc/log/myplugin.log 2>&1 ) &
```

幂等与去重只认 **pid 文件**(`$ROOT/data/daemon.pid`)，不要扫 `/proc` 或用 cmdline 子串匹配。
定时任务写到 `/etc/mnt/cron.d/`(框架开机软链进 `/etc/crontabs/cron.d/`)，细节见 `references/autostart.md`。

## 常用命令

```bash
# 设备侧(SSH 进去后)
ikplugin list|install <zip|目录>|remove <名>|scan|verify <zip>|pack <目录> <zip>
/usr/sbin/<name> ...                     # 插件自己的 CLI(bin/ 自动软链)
/usr/ikuai/function/<func_name> show TYPE=data   # 直接调后端接口(不登录也能看输出)

# 宿主机(仓库自带的运维工具)
IK_PASS=... python ikctl.py sh '<命令>'   # 在设备上执行命令
IK_PASS=... python ikctl.py push <本地> <远端>
IK_PASS=... python ikctl.py reboot --wait # 重启并等 SSH 回来
```

## 参考文件

| 文件 | 内容 |
| --- | --- |
| `references/package-format.md` | 包格式全字段、校验规则、打包与取名规则、`data/` 升级保留 |
| `references/lifecycle.md` | 安装/开机/卸载/升级的执行细节、`ikplugin` 行为、Web 上传安装通道 |
| `references/web-plugin.md` | 卡片 JSON、页面写法、后端接口 `func_api` 分发约定、JSON/参数限制、上传安装接口 |
| `references/ui.md` | **插件页 UI 规范**：统一套件 ikui 的接入与三条硬约束；附「确实想蹭爱快样式」的可选做法 |
| `references/autostart.md` | `boot.sh`、守护进程、pid 文件、cron.d 定时任务、抗挂断 |
| `references/sqlite3.md` | 设备 sqlite3 **3.8.11.1** 的语法边界与推荐脚本(建库/写入/清理/查询) |
| `references/lua.md` | LuaJIT 2.1 + cjson + lsqlite3 的调用方式与 Lua 5.1 语法限制 |
| `references/build.md` | shell 优先原则、uClibc SDK 交叉编译、Rust(musl 静态 / 自定义 target) |
| `references/device-testing.md` | 真机环境事实、SSH 接入、安装/卸载/重启观测流程与实测输出 |
| `assets/template/` | **已实机验证过的**完整模板插件(shell + sqlite3 + Lua + Web + 自启) |
| `scripts/new-plugin.sh` | 由模板脚手架新插件 |
| `scripts/deploy-plugin.sh` | SSH 推送/安装/卸载/重启/观测 |

## 高频坑(踩过的)

1. **`install.sh` 必须在 zip 里是可执行的** —— 框架会 `test -x install.sh`，不通过则**整包不安装**。
   zip 保存 unix 权限位，打包前务必 `chmod +x`。本仓库 `core.filemode=false`，提交后还要
   `git update-index --chmod=+x <file>` 才会记录执行位。
2. **换行必须是 LF** —— CRLF 会让设备上的 `*.sh` 直接语法报错。
3. **参数值不能含空格/引号** —— Web 请求经 lua 侧拦截；自由文本前端用 `+` 传，后端 `tr '+' ' '` 还原。
4. **动作名必须是 `name()` 形式**，不能以下划线开头，否则 `func_api.sh` 判 `invalid action`。
5. **`ps` 是 busybox 的** —— 没有 `ps aux`，用 `ps | grep <名>` 或 `kill -0 $(cat pidfile)`。
6. **不要把 `boot.sh` 写慢** —— 它串在开机流程里，失败要"打印日志继续"，不能卡住。
7. **设备时间在刚开机瞬间会跳变**(UTC+8 ↔ 宿主时区)，判断"开机是否执行"看 `uptime` 不要看时钟。
8. **卸载后卡片目录可能留一个空目录**(无软链)，下次开机 `plugin_web_sync` 会清掉，无害。
