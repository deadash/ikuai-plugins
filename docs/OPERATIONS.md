# 操作手册 (打包 / 签名 / SSH 升级 / 重启验证 / 审计与 Web 插件)

本文档记录本框架在 **iKuai x64 (3.7.x)** 上的完整落地流程，全部操作均可通过 SSH 命令行完成。
实测环境: iKuai 3.7.15 x64 跑在 QEMU/KVM 上，客户机 LAN `192.168.9.1`，宿主机侧通过
QEMU user-net 端口转发 `127.0.0.1:10022 -> 192.168.9.1:22` 访问。

---

## 0. 连接信息

| 项目 | 值 |
| --- | --- |
| SSH | `ssh sshd@127.0.0.1 -p 10022`（dropbear；宿主机 user-net 只能从 127.0.0.1 转发进客户机） |
| 账号 | `sshd` / 与 Web 控制台相同的密码（首次改密后即生效；`scripts/01_enable_ssh.sh` 把该账号 shell 换成 `/bin/bash`） |
| Web | `http://<宿主IP>:8081/` （socat 转发 0.0.0.0:8081 → 127.0.0.1:18080 → 客户机 :80） |
| 控制台 | VNC 127.0.0.1:5901；QEMU monitor `/tmp/ikuai-mon.sock` |
| 客户机文件系统 | `/` 根分区(111M, 每次重启还原) · `/etc/mnt`(sda3, 50M, 持久) · `/etc/log`(sda5, 15.5G, 持久) |

> 注意: QEMU user-net 的 `hostfwd` 只绑在 `127.0.0.1`，所以 SSH/Web 都必须从宿主机本机发起；
> 若要通过局域网访问，需要像 `vm/run.sh` 里那样用 socat 再转发一层。

---

## 1. 分区与空间(是否需要"盘符")

设备上**不需要新建分区**，固件已自带一个 15.5G 的持久日志分区，直接用它落日志即可。

实测(SSH):

```
$ df -h
Filesystem                Size      Used Available Use% Mounted on
/dev/root               111.0M    107.8M    810.0K  99% /          <- 根分区, 每次重启还原, 只剩 ~800K
tmpfs                     1.9G      4.3M      1.9G   0% /tmp
/dev/sda3                43.4M      1.2M     38.7M   3% /etc/mnt    <- 持久盘, 放框架/插件
/dev/sda5                15.5G      3.0M     14.7G   0% /etc/log    <- 持久日志分区(16G 磁盘的剩余空间)
```

结论与约定:

| 用途 | 位置 | 说明 |
| --- | --- | --- |
| 框架本体 / 插件包 | `/etc/mnt/.boot`、`/etc/mnt/plugins` | 38.7M 可用，持久，重启不丢 |
| 审计日志 / DNS 抓包 / 体检报告 | `/etc/log/ikguard/` | 15.5G 可用，持久，重启不丢 |
| 运行时软链(Web 资源、后端接口、/usr/sbin) | `/` 根分区 | 每次重启由 `scripts/03_enable_plugins.sh` 重建，**只放软链和几 KB 的页面** |

根分区只剩 800K，务必不要把大文件写进 `/`（框架只往根分区放软链和 `www` 插件页面）。

### 1.1 创建日志目录(已由框架自动完成，手工操作如下)

```
ssh sshd@127.0.0.1 -p 10022
mkdir -p /etc/log/ikguard
chmod 755 /etc/log/ikguard
df -h /etc/log
```

### 1.2 如果真的需要新分区/扩容

设备使用 ext4 标准分区表(mbr)，磁盘为 `/dev/sda`：

```
sda1  50M   /        (根, 只读镜像展开, 重启还原)
sda2   5M   (预留)
sda3  50M   /etc/mnt (持久)
sda4   1个扇区 (扩展分区标记)
sda5  15.5G /etc/log (持久)
```

扩容步骤(仅在必要时，需谨慎)：

```bash
fdisk -l /dev/sda                    # 查看现有分区
fdisk /dev/sda                       # 删除并重建 sda5(起始扇区保持一致, 结束扇区扩大)
resize2fs /dev/sda5                  # 在线扩容 ext4
df -h /etc/log                       # 确认
```

> 更简单稳妥的做法是在 sda2 预留分区上 `mkfs.ext4` 后 `mount`，或者直接用 `/etc/log` —— 本框架
> 默认就用 `/etc/log`，无需任何分区操作。

---

## 2. 打包与签名

### 2.1 目录约定

```
repo/
├── .tools/              # 签名私钥与构建脚本(已 gitignore, 不随包分发)
│   ├── private.pem      # 私钥(与固件内置公钥配对, 切勿泄露/上传)
│   ├── public.pem       # 公钥(仅用于本地校验)
│   ├── sign.sh          # 生成 MANIFEST.MF + SIGNATURE.RSA
│   ├── verify.sh        # 本地校验清单与签名
│   ├── build.sh         # 签名 + 打成 custom.bin
│   └── test_firmware.sh # 解析并检查 custom.bin
├── boot.sh              # 开机引导(部署到设备后被改名为 .boot/install.sh)
├── install.sh           # 部署脚本: 把本仓库铺到 /etc/mnt/.boot
├── lib/                 # common.sh / backdoor.sh / plugin.sh / audit.sh
├── scripts/             # 开机按序号执行 01..06
├── bin/                 # ikplugin / ikaudit / backdoor_guard
├── usr/ikuai/function/  # Web 后端接口(挂到 /usr/ikuai/function)
├── www/plugins/         # Web 插件(元数据 + 页面 + 图标)
└── Release              # 包描述(filename/firmwareid/version)
```

### 2.2 关键约束(踩坑记录)

1. **换行符必须是 LF**。仓库在 Windows 上打包容易带 CRLF，会导致设备上 `install.sh`、`*.sh`
   全部语法报错、框架静默不生效。构建前先统一：

   ```bash
   find . -path ./.git -prune -o -path ./.tools -prune -o -type f -print0 | \
     xargs -0 -I{} sh -c 'case "{}" in *.png|*.zip|*.bin) ;; *) sed -i "s/\r$//" "{}";; esac'
   ```

2. **签名覆盖的是 MANIFEST.MF 列出的每个文件的 SHA-256**。`sign.sh` 会把 `boot.sh` 在清单里写成
   `install.sh`(设备上 boot.sh 会被改名为 install.sh)，并跳过 `install.sh`、`MANIFEST.MF`、
   `SIGNATURE.RSA` 与所有 `.` 开头的文件。**改动任何被清单列出的文件后必须重新签名**，
   否则开机时固件校验失败，整个框架不会运行。

3. 私钥必须与固件内置公钥配对(公钥硬编码在 `/usr/ikuai/script/plugins.sh` 里)，
   否则设备侧 `openssl dgst -verify` 不通过。

### 2.3 一键打包

```bash
cd repo
bash .tools/sign.sh        # 生成 MANIFEST.MF + SIGNATURE.RSA (使用 .tools/private.pem)
bash .tools/verify.sh      # 本地自检(签名 + 每个文件摘要)
bash .tools/build.sh       # 产出 .dist/custom.bin
bash .tools/test_firmware.sh .dist/custom.bin   # 查看包头与固件信息
```

`custom.bin` 结构(供排查用):

```
[4 字节大端: 头部长度][gzip(JSON 头)][tar.gz(仓库内容, 不含 . 开头文件)]
JSON 头: {filename,firmwareid,version,md5,sha256,length,timestamp}
```

---

## 3. 通过 SSH 命令行升级(官方 90001 插件通道)

iKuai 的"系统升级"对 `firmwareid=90001` 的包走 `__upgrade_plugins()`：
解包 `firmware.bin` → 执行包内 `install.sh`(即部署脚本) → 铺开 `/etc/mnt/.boot`。
命令行等价操作如下(无需点 Web 界面)：

```bash
# 0) 宿主机: 把包推送到设备(设备没有 sftp 子系统, 用 base64 流传输)
B64=$(base64 -w0 .dist/custom.bin)
ssh sshd@127.0.0.1 -p 10022 "mkdir -p /tmp/iktmp/import && echo '$B64' | base64 -d > /tmp/iktmp/import/custom.bin"

# 1) 设备: 校验包头并登记升级文件(解析 md5/sha256/length)
ssh sshd@127.0.0.1 -p 10022 "/usr/ikuai/function/upgrade parse_file filename=custom.bin"

# 2) 设备: 执行升级(解包 + 跑 install.sh + 铺开 /etc/mnt/.boot)
ssh sshd@127.0.0.1 -p 10022 "/usr/ikuai/function/upgrade update_file"

# 3) 检查结果
ssh sshd@127.0.0.1 -p 10022 "ls -la /etc/mnt/.boot; cat /etc/mnt/boot_args"
```

> 注意: `parse_file` 会把上传文件从 `/tmp/iktmp/import` 移走(成功即消费掉)。
> 若只想快速铺文件，也可以跳过升级通道，直接把 tar 解到 `/etc/mnt/.boot`(见附录 A)。

### 3.1 开机流程(为什么重启才算"生效")

```
内核启动
  └─ /etc/setup/rc  (iKuai rc)
       └─ boot_load_sync plugins.sh            # /usr/ikuai/script/plugins.sh
            └─ boot(): 用内置公钥校验 /etc/mnt/.boot/{MANIFEST.MF,SIGNATURE.RSA}
                 └─ 逐文件比对 SHA-256
                      └─ /etc/mnt/.boot/install.sh     # 即包里的 boot.sh
                           └─ scripts/01..06 (按文件名排序)
                                ├─ 01_enable_ssh.sh        开 SSH 登录
                                ├─ 02_disable_backdoor.sh  后门/更新通道阻断(进程+文件+网络三层)
                                ├─ 03_enable_plugins.sh    插件铺开 + Web 插件资源/后端接口
                                ├─ 04_enable_cron.sh       cron 铺开并 crond_commit
                                ├─ 05_enable_shell.sh      自备程序链接
                                └─ 06_enable_audit.sh      审计/取证启动
       └─ echo 1 > /etc/plugins_ok             # 校验并执行成功标记
```

因此: **升级后必须重启**，验证点是 `/etc/plugins_ok`、`/etc/log/ikguard/boot.log` 与后门进程状态。

---

## 4. 重启与验证

```bash
# 重启(设备侧)
ssh sshd@127.0.0.1 -p 10022 "reboot"

# 等 40~60 秒后重连, 逐项验证:
ssh sshd@127.0.0.1 -p 10022 "
  cat /etc/plugins_ok;                       # 1 = 验签通过且框架已执行
  tail -40 /etc/log/ikguard/boot.log;         # 开机日志
  ps | grep -E 'cre|pmd|ik_rc_client|dtalk|catcher';  # 期望: 空
  ipset -L ikuai_blk | head;                  # 封锁集合条目
  iptables -S OUTPUT FORWARD | grep ikuai_blk;# 封锁规则
  cat /etc/log/ikguard/report.txt;            # 体检结论(正常/异常)
"
```

（宿主机侧可一键跑完上面全部检查，见附录 B。）

### 4.1 验证清单

| 检查项 | 期望 |
| --- | --- |
| `/etc/plugins_ok` | `1` |
| `boot.log` 末尾 | `[backdoor] 完成`、`[audit] dns.start`、`[plugin] Web 插件资源已同步` |
| 后门进程 | `cre/cre_client/pmd/ik_rc_client/dtalkd/dtalkc/catcherd` 均不存在 |
| 后门程序 | `/usr/sbin/ik_rc_client` 等被替换为空壳(含 `[ikblock] disabled`) |
| ipset | `ikuai_blk` 存在且有条目(云端 IP/网段 + 解析结果) |
| iptables | OUTPUT/FORWARD 有 `--match-set ikuai_blk dst -j DROP`，OUTPUT 有云端端口 DROP |
| 审计日志 | `/etc/log/ikguard/audit-<date>.log` 有 `boot.audit`、`block.hit`、`dns.cloud` 等事件 |
| Web 接口 | `POST /Action/call {"func_name":"ikguard","action":"show","param":{"TYPE":"data"}}` 返回 `Result:30000` |
| Web 页面 | 系统设置 → 插件管理 → ikguard 卡片可点开控制台 |

---

## 5. 审计日志(进程 / DNS / 网络 / 封锁命中)

日志目录 `/etc/log/ikguard/`（持久分区，保留 3 天，由 `ikaudit watch` 每分钟采集）：

| 文件 | 内容 |
| --- | --- |
| `boot.log` | 框架开机日志(所有脚本的 log 输出) |
| `audit-YYYYMMDD.log` | 结构化审计事件: `proc.start` `conn.out` `dns.cloud` `cloud.ip` `cloud.port` `block.hit` `backdoor.proc` `backdoor.alive` `probe.*` |
| `proc-YYYYMMDD.log` | 进程快照对比(新出现的进程，命中可疑名单会额外升级为 WARN) |
| `conn-YYYYMMDD.log` | 出向连接快照对比(新增的公网连接) |
| `dns-YYYYMMDD.log` | DNS 查询原始记录(tcpdump 逐网卡抓 `udp/tcp port 53`) |
| `report.txt` | 最近一次体检报告(结论: 正常/异常) |

常用命令:

```bash
/etc/mnt/.boot/bin/ikaudit status      # 日志目录/占用/DNS 采集/封锁规则
/etc/mnt/.boot/bin/ikaudit tail 80     # 看审计事件
/etc/mnt/.boot/bin/ikaudit report      # 立刻体检(异常返回码 1)
/etc/mnt/.boot/bin/ikaudit probe       # 云端连通性自检(解析 + TCP 443 尝试)
/etc/mnt/.boot/bin/ikaudit dns-start   # 手工启动 DNS 抓包
grep -E 'backdoor|cloud|block' /etc/log/ikguard/audit-$(date +%Y%m%d).log
```

> 说明: `probe` 会主动解析并尝试连接爱快云端域名，属于**受控自检**：
> 若封锁生效，表现为"能解析出 IP，但 TCP 连接失败"，并写入审计日志；
> 若出现 `probe.tcp ... 可连通云端` 即为异常，需要检查 ipset/iptables。

### 5.1 域名 → ipset 的补充解析

`lib/backdoor.sh:bd_resolve_domains()` 会把云端域名解析出来的 IP 追加进 `ikuai_blk`
(节流 10 分钟)，因此 `ipset` 条目数会随着解析成功而增长；实测:

```
$ /etc/mnt/.boot/bin/backdoor_guard
[backdoor] 按域名解析补充封锁地址: 23 个
$ ipset -L ikuai_blk | grep -c '^[0-9]'
28
```

> 只有在**确实解析成功**时才更新时间戳。否则开机时 WAN 尚未拨号成功(解析全失败)，
> 会白白占用 10 分钟节流窗口，导致域名封锁在这段时间内形同虚设。
> 另: busybox `nslookup` 不支持 `-type=`，且带 server 时输出形如
> `Name: xx` / `Address 1: ip`，解析 IP 必须取 `Name:` 之后的行
> (见 `lib/common.sh:dns_lookup_ip()`)，否则会把 DNS 服务器地址当成解析结果。

### 5.2 没有外网时怎么验证封锁

家里/测试环境常常 WAN 还没配置，此时"没有云端连接"并不能证明封锁有效。
可以在宿主机侧给 WAN 网卡临时配个地址（仅测试用，不改 iKuai 配置）:

```bash
# QEMU user-net: 网关 10.0.2.2 / DNS 10.0.2.3
ssh sshd@127.0.0.1 -p 10022 "ifconfig eth1 10.0.2.15 netmask 255.255.255.0 up; route add default gw 10.0.2.2"
ssh sshd@127.0.0.1 -p 10022 "/etc/mnt/.boot/bin/backdoor_guard"      # 解析并补封锁
ssh sshd@127.0.0.1 -p 10022 "/etc/mnt/.boot/bin/ikaudit probe"       # 期望 blocked=3
```

实测输出:

```
probe.dns  域名=302.ikuai8.com 解析到 58.221.58.100
probe.tcp  连接云端 58.221.58.100:443 失败(封锁生效/无外网)
probe.dns  域名=pkgmanager.ikuai8.com 解析到 123.57.179.21
probe.tcp  连接云端 123.57.179.21:443 失败(封锁生效/无外网)
resolved=3 blocked=3
```

再配合计数变化与 DNS 抓包记录，就能形成完整证据链:

```
$ iptables -nvx -L OUTPUT | grep ikuai_blk
    2  120  DROP  all  --  *  *  0.0.0.0/0  0.0.0.0/0  match-set ikuai_blk dst   # 命中包数增长
$ grep -i 'ikuai8.com' /etc/log/ikguard/dns-$(date +%Y%m%d).log | tail -3
... 10.0.2.15.46924 > 114.114.114.114.53: 4+ A? 302.ikuai8.com. (32)
$ grep cloud /etc/log/ikguard/audit-$(date +%Y%m%d).log | tail -3
2026-10-13 19:01:01 INFO  dns.cloud   解析查询命中云端域名: 302.ikuai8.com
```

配置完 WAN 的 iKuai 正规做法是「网络设置 → 内外网设置 → wan1 → 绑定网卡 eth1 → 动态 IP(DHCP)」。

---

## 6. Web 插件系统(iKuai 官方插件机制)

iKuai 的"系统设置 → 插件管理"页面(`func_name=plugins`)是**数据驱动**的：

```
/usr/ikuai/function/plugins          <- 后端入口(实为 ../script/plugins.sh 的软链)
  boot()   开机: 校验 .boot 签名并执行 install.sh
  show()   TYPE=data -> __show_data(): 遍历 /usr/ikuai/www/plugins/*/*.json 聚合为 data:json
前端 chunk 146 (app.js 路由 system-setting/plugin-management)
  dockerList = Data.data
  卡片图标  = /plugins/docker/<json 里的 name>.png
  卡片页面  = /plugins/docker/<json 里的 name>.html   (iframe 加载)
```

所以新增一个"网页插件"只需要三样东西：

```
www/plugins/<name>/<name>.json     插件元数据(name 必须等于文件名, 决定卡片与 iframe 地址)
www/plugins/docker/<name>.html     插件页面(自包含 HTML, 直接 fetch /Action/call)
usr/ikuai/function/<func_name>     后端接口(shebang 为 #!/bin/bash /etc/ikcommon)
```

`scripts/03_enable_plugins.sh` 每次开机会把它们同步到根分区：

```
/etc/mnt/.boot/www/plugins/<name>/<name>.json -> /usr/ikuai/www/plugins/<name>/<name>.json
/etc/mnt/.boot/www/plugins/docker/*           -> /usr/ikuai/www/plugins/docker/
/etc/mnt/.boot/usr/ikuai/function/<func_name> -> /usr/ikuai/function/<func_name>
```

### 6.1 后端接口写法

```bash
#!/bin/bash /etc/ikcommon
show()  { ...; json_append __json_result__ data:json; Show __json_result__; }
seting(){ ...; }        # 注意: 动作名不能以下划线开头, 且必须是 `name()` 形式
```

* 分发链: `openresty(ActionCall) → /usr/ikuai/function/func_api.sh <func_name> <action> k=v...`
* `show` 的 stdout 会被包成 `{"Result":30000,"ErrMsg":"Success","Data":<你的 JSON>}`
* 权限: 超级管理员(组 1)不受限; 其他组按 `perm_config`/`perm_default` 判定，新 func_name 走默认权限
* 请求参数值**不能包含空格/引号等字符**（lua 侧 `__rest_check_illegality_char` 会拒绝）
* 失败时向 stdout 打印错误信息并 `return 1`，前端会收到 `Result=30002`

### 6.2 内置插件 `ikguard`

* 页面: 系统设置 → 插件管理 → `ikguard` 卡片
  (等价直达: `http://<宿主IP>:8081/plugins/docker/ikguard.html`)
* 后端: `func_name=ikguard`，动作 `show/seting/apply/plugin/dns/probe/logclear`
* 页面功能:
  * **概览**: 框架版本、签名校验、后门进程、ipset 条目、封锁规则/命中数、DNS 采集状态、日志分区占用
  * **开关配置**: `backdoor` `backdoor_hosts` `audit` `sshd` `plugins` `plugins_verify` `cron` `shell` `remote`
    修改即写入 `/etc/mnt/boot_args` 并立刻重跑对应脚本
  * **插件管理**: 列出/卸载已安装插件，扫描并安装 `/etc/mnt/plugins/*.zip`
  * **审计日志**: 实时查看 report/audit/dns/proc/conn/boot 日志
  * **工具**: 云端连通性自检、DNS 记录开关、清空审计日志

### 6.3 通过 Web 接口直接调用(不打开浏览器也能验证)

```bash
curl -s -c /tmp/ck -X POST http://127.0.0.1:18080/Action/login \
     -H 'Content-Type: application/json' \
     -d '{"username":"admin","passwd":"<密码>","remember_password":0}' >/dev/null
curl -s -b /tmp/ck -X POST http://127.0.0.1:18080/Action/call \
     -H 'Content-Type: application/json' \
     -d '{"func_name":"ikguard","action":"show","param":{"TYPE":"data,flags"}}'
```

---

## 7. 开关(`/etc/mnt/boot_args`)

| 键 | 默认 | 作用 |
| --- | --- | --- |
| `sshd` | 1 | 控制台账号 shell 换成 bash，可 SSH 登录 |
| `remote` | 0 | iKuai 云端远程维护通道 |
| `backdoor` | 1 | 后门/更新通道阻断(进程+文件+网络三层) |
| `backdoor_hosts` | 0 | 额外把云端域名写入 `/etc/hosts` 指向 0.0.0.0 |
| `plugins` | 1 | 插件系统(含 Web 插件资源同步) |
| `plugins_verify` | 0 | 插件包强制签名校验 |
| `cron` | 1 | 铺开 `/etc/mnt/cron.d` |
| `shell` | 1 | 链接 `/etc/mnt/shells` 下的程序/配置 |
| `audit` | 1 | 审计取证(进程/DNS/网络/封锁命中) |

命令行修改(等价于 Web 页面开关)：

```bash
sed -i 's/^backdoor=.*/backdoor=0/' /etc/mnt/boot_args     # 关闭
/etc/mnt/.boot/scripts/02_disable_backdoor.sh              # 立即生效
```

---

## 8. 回滚与排障

* **框架没生效**: 先看 `/etc/plugins_ok`(不存在 = 验签或执行失败)，再手工确认签名：
  `openssl dgst -sha256 -verify <公钥> -signature /etc/mnt/.boot/SIGNATURE.RSA /etc/mnt/.boot/MANIFEST.MF`
* **签名不匹配**: 说明改动过的文件没有重新签名 → 回滚该文件或重新 `sign.sh` + `build.sh` 再升级。
* **回滚到上一版**: 升级前的 `.boot` 会被整目录覆盖，可提前 `tar czf /etc/log/ikguard/boot-$(date +%F).tgz -C /etc/mnt .boot` 备份，回滚即解回该目录并重启。
* **需要紧急停用**: `sed -i 's/^backdoor=.*/backdoor=0/' /etc/mnt/boot_args` 后执行
  `iptables -D OUTPUT -m set --match-set ikuai_blk dst -j DROP` 等手工清理，或删除 `/etc/mnt/.boot` 目录后重启(框架即停止)。

---

## 附录 A. 不走升级通道的快速铺开(仅调试用)

```bash
# 宿主机: 把 tar.gz 推给设备
python3 - <<'PY' > /tmp/payload.b64
import base64,struct,gzip,io
raw=open('.dist/custom.bin','rb').read()
h=struct.unpack('>I',raw[:4])[0]
print(base64.b64encode(raw[4+h:]).decode())
PY
ssh sshd@127.0.0.1 -p 10022 "base64 -d > /tmp/fw.tgz" < /tmp/payload.b64
ssh sshd@127.0.0.1 -p 10022 "mkdir -p /tmp/fw && tar xzf /tmp/fw.tgz -C /tmp/fw && rm -rf /etc/mnt/.boot && cp -r /tmp/fw /etc/mnt/.boot && mv /etc/mnt/.boot/boot.sh /etc/mnt/.boot/install.sh && chmod +x /etc/mnt/.boot/install.sh && ls /etc/mnt/.boot"
```

## 附录 B. 宿主机一键验证工具 ikctl

宿主机上提供 `ikctl.py`(需要 paramiko)，把上面所有步骤串起来:

```bash
export IK_PASS='<控制台密码>'
python3 ikctl.py sh "<命令>"                        # 远程执行
python3 ikctl.py deploy repo/.dist/custom.bin       # 上传 + parse_file + update_file
python3 ikctl.py reboot --wait                      # 重启并等 SSH 回来
python3 ikctl.py verify                             # 一键体检(19 项)
python3 ikctl.py audit --tail 60                    # 看报告/审计/DNS/连接日志
```

`verify` 依次检查: 签名校验 → `plugins_ok` → `boot.log` 各阶段 → 后门进程/程序 →
ipset/iptables → 审计日志与体检结论 → DNS 抓包 → Web 插件资源/接口，最后给出
`通过 N/19` 汇总。实测重启后为 19/19 通过。
