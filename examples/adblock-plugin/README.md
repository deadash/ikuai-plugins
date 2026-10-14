# ikadblock —— iKuai 广告 / 跟踪域名拦截插件

把 LAN 全网的 DNS 查询纳管到路由器上的一个本地 sinkhole：命中黑名单的域名统一返回 `0.0.0.0`
（`AAAA` 返回 `::`），其余域名照常解析。黑名单来自**内置种子表 + 开源规则库**
（anti-AD、StevenBlack，可自行增删），一条 `*.父域` 通配即可覆盖全部子域。

* 插件包 **27,724 字节**、纯 shell，**不带任何二进制** —— sinkhole 用的是设备自带的
  `/usr/sbin/ikdnsx`（iKuai 自己的 DNS 缓存/转发器）。
* 客户端**自己指定 8.8.8.8 / 114.114.114.114 也绕不过去**（LAN 侧 DNS 被 REDIRECT 纳管）。
* 内置 235 条种子表离线即可拦；联网时页面一键从开源项目更新到 12 万条。
* 开机自动生效（`boot.sh` + 守护进程 + 每分钟定时守卫），实例起不来会
  **主动撤掉劫持规则（fail-open）**，绝不把 DNS 弄挂；卸载立即恢复原状。

---

## 1. 机制（下面每条都是 iKuai 3.7.16 x64 真机实测结论）

| 设备能力 | 实测结论 |
| --- | --- |
| `ikdnsx`（自带 DNS 缓存/转发器） | 配置 `[global]` 支持 `host` `port` `cache_max` `cache_ttl` `report_time` `report_file` `nameserver`；`-S <静态表>` 格式为 `ipv4 <域名> <IP>` / `ipv6 <域名> <IP>`；`-P <pidfile>`。可以多实例（我们自己跑一个在 5353）。 |
| 静态表通配 | **`ipv4 *.a.com 0.0.0.0` 命中 `a.com` / `x.a.com` / `x.y.a.com`，不命中 `a.com.evil.net`**（后缀语义正确）。所以每个域名只写一条就能覆盖整棵子树。 |
| 静态表热加载 | **不支持**：`kill -HUP` 后进程存活但新条目不生效，改表必须重启进程（本插件重建后重启实例，约 1 秒）。 |
| 规模 | 22 万条静态条目：启动约 1 秒、常驻内存 33 MB、单次查询约 30 ms（本机 3.9 GB 内存）。 |
| iptables | 1.8.3（legacy），有 `-m string` / `-m conntrack` / `REDIRECT`；iKuai 自己的 DNS 代理就是 `-t nat -A DNSPROXY -p udp --dport 53 -j REDIRECT --to-port 53`。 |
| `-m ifaces` | iKuai 自己的规则用 `-m ifaces --ifaces lan,vlan,ppp,... --dir in` 匹配 LAN 接口；**我们自己插的规则用它计数器恒为 0（不生效）**，改用真实网卡名 `-i lan1`（实测命中）。 |
| 自己发起的 DNS 查询 | **设备不接受本地自查询**：`127.0.0.1:5353`(本插件)、`127.0.0.1:54`(iKuai 自带实例)、`192.168.9.1:5353` 三种发法都收不到应答；而设备自己解析外网域名正常。所以自检不能靠本地查询（见 §4）。 |
| 没得用的东西 | `nc` 不支持 `-u`、没有 `dig`、没有 `timeout` / `setsid` / `nohup` / `python`。 |

数据面：

```
LAN 客户端 (无论自己指定哪个 DNS 服务器)
        │  UDP/53
        ▼
iptables nat PREROUTING ── 链 IKADB（-i lan1 …，插在 iKuai 自己的 DNSPROXY 之前）
        │  REDIRECT --to-ports 5353
        ▼
插件自带的 ikdnsx 实例 ── 静态表 *.域名 → 0.0.0.0 / ::
        │  未命中
        └──────────► 上游 DNS（默认取设备 /etc/resolv.conf 的 nameserver）
```

> 只劫持 UDP/53（与官方 DNS 代理一致）：`ikdnsx` 只监听 UDP，劫持 TCP/53 会让大响应场景直接失败。

## 2. 安装

```bash
# 设备侧
ikplugin install /root/ikadblock-v1.0.0-plugin.zip
ikplugin list
/usr/sbin/ikadblock status      # JSON 状态
/usr/sbin/ikadblock verify      # 自检

# 宿主机侧(仓库自带工具)
export IK_PASS='<控制台密码>'
python ikctl.py push examples/adblock-plugin/dist/ikadblock-v1.0.0-plugin.zip /root/ikadblock.zip
python ikctl.py sh 'ikplugin install /root/ikadblock.zip; /usr/sbin/ikadblock status'
```

安装后默认**开启**（`data/state` 里 `enabled=1`），升级时保留用户的开关与列表。

## 3. 使用（CLI）

| 命令 | 说明 |
| --- | --- |
| `ikadblock status` | 状态 JSON（开关、实例、规则数、域名数、统计、拦截接口） |
| `ikadblock apply` / `revert` | 启用 / 停用（撤规则、停实例、停守护） |
| `ikadblock update [源名]` | 从 `data/sources.conf` 里的开源规则库下载、合并去重、重载 |
| `ikadblock rebuild` | 用当前列表重建域名表并重载 |
| `ikadblock add <域名>` / `del <域名>` | 自定义拦截 |
| `ikadblock whiteadd <域名>` / `whitedel <域名>` | 白名单 |
| `ikadblock verify` | 自检（实例 / canary 通配拦截 / 劫持规则） |
| `ikadblock sync` | 一次幂等校准（守护进程与每分钟定时守卫调用） |
| `ikadblock config <key> <value>` | `enabled` / `auto_update` / `block_ipv6` / `upstream` |
| `ikadblock log [n]` | 日志（`/etc/log/ikadblock/ikadblock.log`） |

### 数据文件（`/etc/mnt/plugins/ikadblock/data/`，升级保留）

| 文件 | 说明 |
| --- | --- |
| `state` | `enabled` / `auto_update` / `block_ipv6` / `last_update` / `upstream`(可选) |
| `domains.txt` | 合并去重后的拦截域名（种子 + 自定义 + 下载 − 白名单） |
| `sinkhole.hosts` | 交给 ikdnsx 的静态表（`ipv4 *.域名 0.0.0.0` + `ipv6 *.域名 ::`） |
| `downloaded.txt` / `auto-white.txt` | 规则库下载结果（域名 / `@@` 白名单） |
| `custom.txt` / `whitelist.txt` | 自定义拦截 / 白名单 |
| `sources.conf` | 规则源（`名称|URL|格式`，格式自动识别） |
| `report.txt` / `stats` | ikdnsx 报表快照 / 累计统计 |

## 4. 使用（Web）

「高级应用 → 插件管理 → 广告拦截」卡片，页面提供：开关、运行状态与统计、一键更新规则库、
重新建表、立即自检、自定义拦截/白名单增删、最近日志，以及机制与局限说明。

后端接口 `func_name=ikadblock`（`/usr/ikuai/function/ikadblock`）：

| action | 参数 | 说明 |
| --- | --- | --- |
| `show` | `TYPE=data` | `{status, custom[], whitelist[], logs[]}` |
| `seting` | `key=enabled|auto_update|block_ipv6` `value=0|1` | 开关 |
| `update` | `name=<源名>`(可选) | 更新规则库 |
| `rebuild` / `verify` | — | 重建 / 自检 |
| `add` / `del` / `whiteadd` / `whitedel` | `domain=<域名>` | 列表增删 |
| `log` | `lines=N` | 日志 |

### 自检是怎么做的（重要）

设备**不接受自己发起的本地 DNS 查询**（`127.0.0.1:5353`、`127.0.0.1:54`、`192.168.9.1:5353`
都收不到应答，iKuai 自带的 `:54` 实例也一样），而设备上又没有 `nc -u` / `dig`，
busybox `nslookup` 也不支持指定端口。所以 `verify` 走的是**真实数据路径**：

1. 临时在 `nat OUTPUT` 插一条规则：只匹配 canary 域名（`ikadblock-canary.test`，永远写在静态表里）、
   只把**路由器自己**发往 `:53` 的查询 `REDIRECT` 到 sinkhole；
2. `nslookup ikadblock-canary.test` → 得到 `0.0.0.0` 即证明 sinkhole 在按通配拦截；
3. 立刻删掉那条临时规则（守护进程每轮还会兜底清理残留）。

> 不能拿"需要转发的域名"做这个自检 —— sinkhole 自己的上游查询也会被这条规则劫持回来，
> 形成自环（实测会一直问到超时）。转发是否正常请在 LAN 客户端上解析一个普通域名确认。

## 5. 规则源与容量

`share/sources.conf` 默认两个（GitHub 直连在境内不通，已走 `ghproxy.net` 镜像，可在
`data/sources.conf` 里自行增删/调序，**顺序即优先级**）：

```
anti-ad|https://anti-ad.net/domains.txt|auto
stevenblack|https://ghproxy.net/https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts|auto
#1hosts-lite|https://ghproxy.net/https://raw.githubusercontent.com/badmojr/1Hosts/master/Lite/hosts.txt|auto
```

解析器自动识别四种格式：纯域名表、hosts 表（`0.0.0.0 域名`）、dnsmasq（`address=/域名/`）、
adblock（`||域名^`，`@@||域名^` 收进自动白名单）。合并去重后按 `MAX_DOMAINS`（默认 **120000**）
截断 —— 超出时先砍排在后面的源。关掉 IPv6 条目（`ikadblock config block_ipv6 0`）可以把
静态表体积减半。

## 6. 局限与风险

1. **只管 DNS**。客户端用 DoH/DoT（浏览器内置加密 DNS）、或广告与业务同域时拦不住；
   插件不做 HTTPS 证书级拦截，也不动任何二进制。
2. **白名单是父域通配语义**：加入 `good.example.com` 后它和它的子域都不再拦截，
   规则库里单独列出的子域条目也一并让开；同时 `example.com` 这种父域条目也会整条让开
   （不让开的话白名单根本无从生效）。
3. **接管了 LAN 侧 DNS**：这是拦住"客户端自选 DNS"的前提。实例异常时插件会撤规则 fail-open
   （最坏回到"没装插件"的样子），守护进程/定时守卫会尝试补回。
4. **依赖设备自带的 `ikdnsx`**：固件可能换位置/换行为，`apply` 拉不起来时会直接放弃接管
   （不会写坏配置）。固件升级后建议跑一次 `ikadblock verify`。
5. **占用持久盘**：12 万条域名时 `domains.txt` 2.3 MB + `downloaded.txt` 2.3 MB +
   `sinkhole.hosts` 7.7 MB，`/etc/mnt` 从 2.1M 涨到 13.9M（共 43.4M）。空间紧张就把
   `MAX_DOMAINS` 调小或关掉 IPv6 条目。
6. **统计口径**：数字取自 `ikdnsx` 每 60 秒写的 `report.txt`（实例重启会归零，插件按增量累加）。
   可靠的是"查询总数"和"上游转发数"；"本地应答 = 查询 − 上游转发"里既含拦截命中又含缓存命中
   （`count_cache` 的语义官方没说明，实测既不是纯命中也不是纯解析数，只当参考值展示），
   所以页面上**不宣称精确的"拦截次数"**。

## 7. 实测记录（iKuai 3.7.16 x64；LAN 客户端 192.168.9.50）

```
$ ikplugin install /root/ikadblock.zip
[plugin] 已暂存持久数据: /etc/mnt/plugins/ikadblock/data      # 升级时 data/ 保留
[plugin] 安装插件: ikadblock (版本 1.0.0)
$ ikadblock status
{"enabled":"1","running":true,"port":"5353","domains":235,"rules":1,"ifaces":"lan1",...}
$ ikadblock verify
{"sinkhole":true,"port":"5353","canary":"0.0.0.0","rules":1,"ifaces":"lan1","domains":235,"pass":true}

# LAN 客户端(自己指定 8.8.8.8 也被纳管)
$ dig +short x.y.000dn.com  @8.8.8.8   -> 0.0.0.0        # 通配命中多级子域
$ dig +short AAAA 000dn.com @8.8.8.8   -> ::             # AAAA 也拦
$ dig +short www.baidu.com  @8.8.8.8   -> 36.152.44.93   # 非黑名单照常解析
$ dig +short 000dn.com @192.168.9.1    -> 0.0.0.0        # 走路由器 DNS 同样拦

# 开源规则库
$ ikadblock update
  拉取规则库: anti-ad -> https://anti-ad.net/domains.txt            ok (2121850 字节)
  拉取规则库: stevenblack -> https://ghproxy.net/.../hosts          ok (2229037 字节)
  规则库更新完成: 源 ok=2 fail=0, 下载条目 120000 条           (real 0m15.8s)
  已重建: 拦截域名 120000 条 / 静态条目 240002 条
$ df -h /etc/mnt | tail -1
/dev/sda3   43.4M   13.9M   26.0M   35% /etc/mnt

# 白名单 / 自定义
$ ikadblock whiteadd 000dn.com ; dig +short kwcdn.000dn.com @8.8.8.8 -> 183.215.57.92
$ ikadblock add myads.testdomain.com ; dig +short myads.testdomain.com @8.8.8.8 -> 0.0.0.0

# 重启(守护进程 5 秒节奏补齐开机时还加不上的劫持规则)
...[boot] 开机处理开始 uptime=13.18
...[boot] LAN 接口尚未就绪, 劫持规则由守护进程(前 2 分钟每 5 秒)补齐
...DNS 劫持已安装: 接口=[lan1 ] 规则数=1
$ ikadblock verify   -> {"canary":"0.0.0.0","rules":1,"pass":true}

# 停用 / 卸载
$ ikadblock revert   -> 规则 0 条、实例 0 个、客户端解析立刻恢复正常
$ ikplugin remove ikadblock ; reboot
$ ls -d /etc/mnt/plugins/ikadblock /usr/sbin/ikadblock ; iptables -t nat -S PREROUTING | grep -c IKADB
-> 目录/软链/规则/实例/cron 全部消失(0), 再重启依然干净
```

统计口径的受控验证（重启实例清零后，从客户端发 6 个各不相同的拦截域名 + 1 个普通域名）：

```
count_query=7  count_miss=1  count_static=240002(=静态表条目数)
stats: total_query=7  total_local=6  total_miss=1  -> hit=85.7%
```

## 8. 打包

```bash
bash examples/adblock-plugin/build.sh
# -> dist/ikadblock-v1.0.0-plugin.zip  (27,724 字节,
#    sha256 daecc40559dc7b0c74dd0b324df36ae5e71e75a2a8276934892f7abde0524459)
```

`build.sh` 会统一 LF、`chmod +x`，并校验 zip 里 `Release`/`install.sh`/`bin/*`/`function/*`
等条目齐全且带执行位（框架 `test -x install.sh` 不过会整包不装）。
