# 自启动 / 常驻进程 / 定时任务

## 为什么必须写在 `boot.sh`

根分区 `/` **每次重启从固件镜像还原**：`/usr/sbin` 软链、Web 页面软链全部消失(框架会重建)，
**所有进程也都死了**。插件本体在持久盘 `/etc/mnt/plugins/<name>` 不会丢，
所以"自启动"就一件事：**在 `boot.sh` 里把该起的东西重新起来**。

`install.sh` 只保证"装完立刻能用"，`boot.sh` 才是重启后的唯一依靠。
有 `boot.sh` 时开机**不会**再执行 `install.sh`(见 `lib/plugin.sh:plugin_run`)。

```bash
# pkg/boot.sh
ROOT="${PLUGIN_DIR:-/etc/mnt/plugins/mytool}"
"$ROOT/bin/mytool" init >> /etc/log/mytool.log 2>&1     # 幂等初始化
"$ROOT/bin/mytool" daemon-start >> /etc/log/mytool.log 2>&1
exit 0
```

要点：
* `boot.sh` 串在开机流程里，**必须快、必须可失败**：单步失败打印日志后继续，绝不能卡住/阻塞读 stdin。
* 不要在里面 `sleep` 很久(安装/启动的探测 sleep 1 秒级别可以)。
* 时间基准用 `cut -d' ' -f1 /proc/uptime`，不要用 `date`(设备时钟刚开机瞬间会跳变)。

## 拉常驻进程：设备没有 nohup/setsid

设备实测缺失 `nohup`、`setsid`、`timeout`；`pkill`/`pgrep`/`pidof`/`flock`/`watch` 有。
后台常驻必须用"子 shell + 忽略 HUP"：

```bash
daemon_start() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
        echo "已在运行 pid=$(cat "$PIDFILE")"; return 0
    fi
    ( trap '' HUP; exec "$SELF" daemon >> "$LOG" 2>&1 ) &     # 关键: 忽略 HUP, exec 让 pid 就是子进程
    sleep 1
    kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
}
```

* **必须 `exec`**：否则 pid 文件里记的是中间 shell，子进程一 `exec` 换 pid 就对不上了。
* **必须 `trap '' HUP`**：父进程(安装脚本 / SSH 会话)退出时否则会给子进程发 HUP。

## 去重只认 pid 文件

不要扫 `/proc`、更不要用 cmdline **子串**匹配 —— 随便一个提到该字符串的 shell 都会被误判。
推荐：pid 文件 + `kill -0`。

```bash
PIDFILE="$ROOT/data/daemon.pid"
```

`daemon` 进程里第一件事：`echo $$ > "$PIDFILE"`，并 `trap 'rm -f "$PIDFILE"; exit 0' TERM INT HUP`。

> 经验：`$(...)` / `{ ...; }` 子 shell 会**继承父进程 cmdline**，`$$` 在子 shell 里仍是父 pid，
> 自己扫自己必然出错。少用进程扫描。

## 定时任务(可选)

框架把 `/etc/mnt/cron.d/*` 软链进 `/etc/crontabs/cron.d/`，然后调 `crond_commit`
汇总进 `/etc/crontabs/root`(`scripts/04_enable_cron.sh`)，重启自动重建。

所以在插件里加定时任务：`install.sh` 写 `/etc/mnt/cron.d/<name>`，`uninstall.sh` 删掉它。
**不要**直接改 `/etc/crontabs/root`(根分区，重启即还原)。

```
# /etc/mnt/cron.d/mytool
*/5 * * * * /etc/mnt/plugins/mytool/bin/mytool collect >/dev/null 2>&1
```

> 更简单/更稳的替代：不用 cron，直接一个常驻 `daemon` 自己 `sleep` 轮询 ——
> 少一个"cron 里也要记得清理"的状态。示例模板就是这么做的。

另一种"守护"套路(框架自己的 `backdoor_guard` 用法)：cron 每分钟跑一个幂等守卫，
进程掉了就补起来。适合"必须一直活着"的服务。

## 没有 `timeout` 怎么做超时

```bash
# 后台跑 + 探活 + 到点杀
"$CMD" & pid=$!
for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null
```

或读外部命令时限时，用 `read -t <秒>` / `nc -w <秒>` 等自带超时参数。

## 数据落地

| 用途 | 位置 | 说明 |
| --- | --- | --- |
| 插件库/状态/pid | `/etc/mnt/plugins/<name>/data/` | 持久；升级时框架会保留 `data/` |
| 日志 | `/etc/log/<name>.log`(或 `/etc/log/ikguard/<name>.log`) | 持久分区 15.5G |
| 临时文件 | `/tmp/...` | tmpfs, **重启清空** —— 别把状态放这里 |
| 根分区 | `/`、`/usr/...`、`/usr/ikuai/...` | 每次重启还原，且几乎没空间 |

> 根分区当前可用只有 **1MB 左右**，写任何"新增文件"都可能 ENOSPC。
