# 真机环境与测试流程

以下都是**实测**结论(iKuai 3.7.16 x64 + 本框架 v0.0.4，2026-10-14)。

## 1. 系统环境

```
$ uname -a
Linux iKuai 5.10.194 #0 SMP ... x86_64 GNU/Linux        (BusyBox 1.23.2)
GNU bash, version 4.4.23(1)-release (x86_64-openwrt-linux-gnu)
OpenSSL 1.0.2u  20 Dec 2019
libc: uClibc-ng 1.0.40  ( /lib/ld64-uClibc.so.0 -> libuClibc-1.0.40.so )
```

登录后就是 **`uid=0(root)`**，`PATH=/usr/sbin:/usr/bin:/sbin:/bin`。

### 自带工具(✅)/ 缺失(❌)

| ✅ 可用 | 版本/说明 |
| --- | --- |
| `sqlite3` | **3.8.11.1 (2015)** —— 见 `sqlite3.md` |
| `lua` / `luajit` | LuaJIT 2.1.0-beta3(`lua` 是 `luajit` 的软链)，带 `cjson`、`lsqlite3` |
| `jq` `curl` `wget` `nc` `openssl` `zip` `unzip` `tar` `crontab` | — |
| `pkill` `pgrep` `pidof` `flock` `watch` `logger` `strace` `conntrack` | — |
| `ipset` `iptables`(含 `-j LOG`) | 设备自带扩展 |

| ❌ 缺失 | 影响 |
| --- | --- |
| `python` / `python3` | 别指望脚本里用 python —— 用 shell 或 lua |
| `gcc` `cc` `make` | 设备上不能编译，必须交叉编译好后放进去 |
| `node` `perl` | — |
| `timeout` `setsid` `nohup` | 后台常驻/超时要自己实现(见 `autostart.md`) |
| `ps aux` | busybox `ps` 没有 `-a`，用 `ps \| grep <名>` 或 `kill -0 $(cat pidfile)` |

### 分区

```
/dev/root   111.0M   ~107.5M    ~1.0M  99%  /            ← 每次重启还原, 几乎没空间
tmpfs       512.0K                     /dev
tmpfs         1.9G                      /tmp            ← 重启清空
/dev/sda3    43.4M     2.0M    37.9M   5%  /etc/mnt      ← 持久(插件/框架)
/dev/sda5    15.5G     6.8M    14.7G   0%  /etc/log      ← 持久(日志)
```

**结论**：插件本体放 `/etc/mnt/plugins/`，数据放插件自己的 `data/`，日志放 `/etc/log/`。
往 `/`(含 `/usr/ikuai/...`)写**新文件**随时可能 ENOSPC；只能靠框架的软链。

### 开关(`/etc/mnt/boot_args`)

```
sshd=1 plugins=1 cron=1 shell=1 backdoor=1 backdoor_hosts=0 audit=0 probe=0
```

`plugins=0` 时插件系统整体跳过；首次启用还需在 Web 页同意《使用条款》(`/etc/mnt/plugins/.eula`)。

## 2. 怎么连上设备

| 通道 | 地址 | 说明 |
| --- | --- | --- |
| SSH(WAN 转发) | `127.0.0.1:10022` | QEMU user-net hostfwd，**推荐**(LAN 改坏了也能进) |
| SSH(LAN) | `192.168.9.1:22` | tap 真实二层，LAN 正常时可用 |
| 账号 | `sshd` / 与控制台相同的密码 | 登录即 `uid=0(root)` bash |
| Web | `http://192.168.9.1/` 或 `http://192.168.217.100:8081/` | 控制台 admin |

仓库自带工具 `ikctl.py`(依赖 venv 里的 paramiko)：

```bash
export IK_PASS='Ikuai@2026'                       # 设备控制台密码
PY=/home/deadash/ikuai/.venv/bin/python
$PY ikctl.py sh '<命令>'                          # 执行命令
$PY ikctl.py push <本地文件> <远端路径>            # 上传(dropbear 无 sftp，走 stdin 流)
$PY ikctl.py pull <远端文件> <本地文件>
$PY ikctl.py reboot --wait                        # 重启并等 SSH 回来(~25s)
# 环境变量可覆盖: IK_HOST=127.0.0.1 IK_PORT=10022 IK_USER=sshd
```

> **限制**：dropbear 的 exec 命令长度上限约 9000 字节 —— 用 base64 推文件时每块 ≤4000 字符，
> 否则 `exec_command` 直接被拒(EOFError)。大文件用 `ikctl.py push`。

## 3. 标准验证流程(安装 → 观测 → 重启 → 卸载 → 重启)

技能自带封装：`scripts/deploy-plugin.sh`(读 `IK_PASS`)。下面是它内部做的事。

### 3.1 安装并观测

```bash
$PY ikctl.py push dist/mytool.zip /root/mytool.zip
$PY ikctl.py sh 'ikplugin install /root/mytool.zip; ikplugin list'
```

实测输出：

```
[plugin] 安装插件: mytool (版本 1.0.0)
NAME       VERSION   LOCATION
mytool     1.0.0     /etc/mnt/plugins/mytool
```

逐项确认软链(框架自动建立)：

```bash
$PY ikctl.py sh 'ls -l /usr/sbin/mytool /usr/ikuai/function/mytool \
    /usr/ikuai/www/plugins/mytool/ /usr/ikuai/www/plugins/app/mytool.*'
```

```
/usr/sbin/mytool                  -> /etc/mnt/plugins/mytool/bin/mytool
/usr/ikuai/function/mytool        -> /etc/mnt/plugins/mytool/function/mytool
/usr/ikuai/www/plugins/mytool/mytool.json -> /etc/mnt/plugins/mytool/www/plugins/mytool/mytool.json
/usr/ikuai/www/plugins/app/mytool.html    -> ...
```

功能面观测：

```bash
$PY ikctl.py sh '
/usr/sbin/mytool status                       # 插件自己的 CLI
/usr/ikuai/function/mytool show TYPE=data     # 后端接口(不走 openresty 也能跑)
sqlite3 /etc/mnt/plugins/mytool/data/*.db ".tables"
cat /etc/log/mytool.log
'
```

Web 面观测(带登录 cookie，未登录会 302)：

```bash
PW=$(printf '%s' "$IK_PASS" | md5sum | cut -d' ' -f1)
curl -s -c /tmp/ck -X POST http://192.168.9.1/Action/login -H 'Content-Type: application/json' \
     -d "{\"username\":\"admin\",\"passwd\":\"$PW\",\"remember_password\":0}"
curl -s -b /tmp/ck -X POST http://192.168.9.1/Action/call -H 'Content-Type: application/json' \
     -d '{"func_name":"plugins","action":"show","param":{"TYPE":"data"}}'   # 卡片列表里应出现 mytool
curl -s -b /tmp/ck -o /dev/null -w '%{http_code}\n' http://192.168.9.1/plugins/app/mytool.html  # 200
```

### 3.2 重启验证自启动

```bash
$PY ikctl.py reboot --wait          # -> "SSH 已恢复(25 秒): up"
$PY ikctl.py sh '
cat /etc/plugins_ok                    # 1
ikplugin list
ls -l /usr/sbin/mytool                 # 软链被重建
cut -d" " -f1 /proc/uptime             # 确认是刚开机
/usr/sbin/mytool status                # 守护进程应已由 boot.sh 再次拉起
tail -5 /etc/log/mytool.log            # 应看到 [boot] 记录
'
```

实测(模板插件)：

```
2026-10-14 22:11:02 [boot] 开机处理开始 (uptime=12.61)
守护进程已启动 pid=5993
2026-10-14 22:11:03 [boot] 状态: {"samples":3,...,"daemon_running":true}
```

数据持久化：`samples` 从重启前的 2 涨到重启后的 4，`first_ts` 不变 → **`data/` 跨重启保留**。

### 3.3 卸载并验证彻底消失

```bash
$PY ikctl.py sh 'ikplugin remove mytool; ikplugin list'
$PY ikctl.py sh 'ls -d /etc/mnt/plugins/mytool /usr/sbin/mytool /usr/ikuai/function/mytool 2>&1; ps | grep -v grep | grep mytool'
$PY ikctl.py reboot --wait
$PY ikctl.py sh 'ikplugin list; ls -d /usr/ikuai/www/plugins/mytool 2>&1; ps | grep mytool || echo 无进程'
```

实测：卸载后目录/软链/进程立刻消失；**再重启后仍是干净**(根分区还原 + `plugin_web_sync` 重铺)。
可能残留一个**空**卡片目录，下次开机被清掉，无害。

## 4. 排错要点

* **插件没生效**：先看 `/etc/mnt/plugins/.eula` 是否 `accepted=1`(未同意时 Web 资源不会链接)，
  再看 `plugins` 开关、`/etc/plugins_ok`。
* **安装日志**：`/etc/log/ikguard/boot.log`(框架)与插件自己的 `/etc/log/<name>.log`。
* **`/tmp` 重启清空**：测试用的样本文件/证书每次重启后要重新推送，否则会把"没推送"误判成"已修复/已删除"。
* **时钟跳变**：设备刚开机瞬间时间会跳(UTC+8 ↔ 宿主时区)，用 `uptime` 判断开机，不要用 `date`。
* **回滚**：QEMU monitor 支持快照，风险操作前先存一个：

```bash
printf 'savevm pre-mytest\n' | socat - UNIX-CONNECT:/tmp/ikuai-mon.sock    # 存快照
printf 'loadvm pre-mytest\n' | socat - UNIX-CONNECT:/tmp/ikuai-mon.sock    # 回滚
```
