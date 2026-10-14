# 运行与生命周期

## 开关

插件系统由 `/etc/mnt/boot_args` 的 `plugins=1` 控制(默认开)。
首次使用需在 Web「插件管理」页同意《使用条款》，同意记录写在 `/etc/mnt/plugins/.eula`：

* **未同意**时：`plugin_web_link()` **拒绝并撤销**插件的卡片/页面/图标与后端接口软链
  (`/usr/ikuai/www/plugins/...`、`/usr/ikuai/function/...`)，插件管理页只显示"同意入口"占位卡片(`terms`)。
* 同意后 `ikguard eula op=accept` 会立刻重跑 `scripts/03` 恢复。

> 命令行/SSH 侧验证插件时如果发现"接口不存在/页面 404"，先确认 `.eula` 里是不是 `accepted=1`。

## 安装(`plugin_install`)

```
ikplugin install <zip|目录>
```

1. 目录 → 直接校验后 `cp` 到 `/etc/mnt/plugins/<name>`。
2. zip → `unzip` 到临时目录；若包里**只有一层目录且该目录内有 `Release`**，自动下钻一层
   (兼容 `zip -r x.zip x/`)。
3. `plugin_verify`(见 package-format.md)。
4. **升级保护**：若 `dest/data` 已存在，先 `mv` 到同分区的 `.backup-<name>/data`，
   覆盖文件后再 `mv` 回来 → **`data/` 跨升级保留**，其余文件全部被覆盖。
5. `plugin_run <dir> install` → 执行 `install.sh`。
6. `plugin_link`(`bin/`→`/usr/sbin/`、`etc/`→`/usr/local/etc/`)
   与 `plugin_web_link`(`www/`、`function/` → 根分区)。
7. 写状态到 `/etc/mnt/plugins/.state/<name>`。

## 开机(`scripts/03_enable_plugins.sh`)

顺序**不可颠倒**：

```
plugin_ensure_dirs
plugin_scan_zips        # 自动安装 /etc/mnt/plugins/*.zip(装完归档 .installed/)
plugin_web_sync         # 清空并重铺 /usr/ikuai/www/plugins(未同意条款只铺 terms 占位卡片)
plugin_boot             # 逐个已装插件: verify -> plugin_run boot -> plugin_link -> plugin_web_link
plugin_function_link    # 框架自带后端接口 -> /usr/ikuai/function/
plugin_web_patch        # 前端 gz 分包补丁(去云绑定拦截 / 目录改名 / 卡片显示 title)
plugin_link_cli         # 暴露 /usr/sbin/ikplugin
```

> 因为 `plugin_web_sync` 会 `rm -rf /usr/ikuai/www/plugins/*`，所以它必须在 `plugin_boot` **之前**，
> 否则会把插件刚建好的卡片/页面软链清掉。

`plugin_boot` 对每个插件：`plugin_verify` → `plugin_run <dir> boot` → `plugin_link` → `plugin_web_link`。

## 动作选择(`plugin_run`)

```sh
if action == boot && -x boot.sh      -> 执行 boot.sh
elif action != uninstall && -x install.sh -> 执行 install.sh
elif action == uninstall && -x uninstall.sh -> 执行 uninstall.sh
else                                  -> 只做链接(不执行脚本)
```

* `install.sh` 同时承担 **安装** 与 **(无 boot.sh 时的)开机** 两种时机 —— 所以必须幂等。
* 有 `boot.sh` 时，开机不再跑 `install.sh`。

## 卸载(`plugin_remove`)

```
ikplugin remove <name>
```

1. `plugin_run <dir> uninstall` → `uninstall.sh`
2. `plugin_unlink`：遍历 `/usr/sbin`、`/usr/local/etc`、`/usr/ikuai/function`、`/usr/ikuai/www/plugins`，
   删掉所有 `readlink` 指向该插件目录的软链，并 `rmdir` 因此变空的卡片目录。
3. `rm -rf /etc/mnt/plugins/<name>` 与 `.state/<name>`。

> 实测：卸载后可能残留一个空卡片目录(无软链)，下次开机 `plugin_web_sync` 会清掉，无害。

## 重启后的"自愈"

根分区每次重启还原，所以：`/usr/sbin` 软链、`/usr/ikuai/function/*`、`/usr/ikuai/www/plugins/*`
全部消失 —— 由 `scripts/03` 开机重建。**插件本体在持久盘，不会丢**。

因此插件必须回答的问题只有一个：**进程/定时任务怎么在开机后回来** → 见 `autostart.md`。

## 命令行速查

```
ikplugin list                     列出已安装(名称/版本/路径)
ikplugin install <zip|目录>        安装
ikplugin remove <名称>             卸载
ikplugin scan                     扫描 /etc/mnt/plugins/*.zip 并安装
ikplugin boot                     重跑一遍所有插件的开机动作(调试用)
ikplugin verify <zip|目录>         只校验
ikplugin pack <目录> <zip>         打包(自动生成 MANIFEST.MF, 有私钥则签名)
ikplugin keygen [目录]             生成签名密钥对
```

`ikplugin` 本体是 `/etc/mnt/.boot/bin/ikplugin`，开机软链到 `/usr/sbin/ikplugin`(`/usr/sbin` 在 PATH 里)。

## Web 上传安装(等价通道)

`ActionUpload` 用 multipart 的**字段名**当文件名(不是 `filename=`)，所以字段名必须写成文件名：

```bash
curl -s -b /tmp/ck -F "mytool.zip=@mytool.zip" http://<设备>/Action/upload     # -> Result 10000
curl -s -b /tmp/ck -X POST http://<设备>/Action/call -H 'Content-Type: application/json' \
     -d '{"func_name":"ikguard","action":"plugin","param":{"op":"install","name":"mytool.zip"}}'
```

上传落盘到 `/tmp/iktmp/import/<文件名>`(上传前会清空、单文件上限 50MB)，再由 `ikguard plugin op=install` 解压安装。
