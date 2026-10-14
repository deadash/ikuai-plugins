# 插件模板 plugdemo

一个**已实机验证过**的最小完整插件，用来当写新插件的起点。
它同时演示了：shell 业务逻辑、sqlite3 持久化、LuaJIT 统计、Web 卡片/页面/后端接口、开机自启。

```
template/
├── build.sh                     组装 pkg/ + 打 dist/plugdemo.zip(零编译)
└── pkg/                         = 会被 zip 的内容
    ├── Release                  plugin=plugdemo / version / comment
    ├── install.sh               安装: 建库 + 拉起守护进程(幂等)
    ├── boot.sh                  每次开机: 重新拉起守护进程
    ├── uninstall.sh             卸载: 停守护进程
    ├── bin/plugdemo             CLI/守护进程(软链到 /usr/sbin/plugdemo)
    ├── function/plugdemo        Web 后端接口(show/seting/sample/clear/report)
    ├── share/report.lua         用设备自带 LuaJIT + lsqlite3 + cjson 出统计
    └── www/plugins/
        ├── plugdemo/plugdemo.json      卡片元数据
        └── app/plugdemo.html/.png      页面与图标
```

## 直接用

```bash
bash build.sh
export IK_PASS='<控制台密码>'
bash ../scripts/deploy-plugin.sh dist/plugdemo.zip --install
bash ../scripts/deploy-plugin.sh --status
bash ../scripts/deploy-plugin.sh --reboot          # 验证开机自启
bash ../scripts/deploy-plugin.sh --remove plugdemo --reboot
```

## 改成自己的插件

推荐用脚手架(自动改名，不用手工 sed)：

```bash
bash ../scripts/new-plugin.sh mytool ~/work/mytool
```

手工改的话记得：`Release` 的 `plugin=`、`bin/` 文件名、`function/` 文件名、
`www/plugins/<名>/<名>.json`、`www/plugins/app/<名>.html|.png`，以及各脚本里的
`/etc/mnt/plugins/plugdemo` 路径与日志名。

## 关键约定(踩坑点)

1. `install.sh` / `boot.sh` / `uninstall.sh` / `bin/*` / `function/*` **必须有执行位**，zip 才带得过去。
2. 文本文件必须是 **LF** 换行。
3. 后台进程用 `( trap '' HUP; exec ... ) &` —— 设备没有 `nohup`/`setsid`。
4. 去重只认 **pid 文件**，不要扫 `/proc`。
5. 数据只写 `/etc/mnt/plugins/<名>/data/`，日志只写 `/etc/log/`。
6. 后端接口的动作名必须是 `name()` 形式；参数值不能带空格/引号(空格用 `+` 传)。
