# 操作手册 (打包 / 签名 / SSH 升级 / 重启验证 / 审计与 Web 插件)

本文档记录本框架在 **iKuai x64 (3.7.x)** 上的完整落地流程，全部操作均可通过 SSH 命令行完成。
实测环境: iKuai 3.7.15 x64 跑在 QEMU/KVM 上，客户机 LAN `192.168.9.1`；WAN 用 QEMU user-net
(`eth1`, DHCP 到 `10.0.2.15`)，LAN 已换成 tap+bridge 的真实二层网络，可通过
`127.0.0.1:10022 -> 10.0.2.15:22`(WAN 侧转发)或直接 `ssh sshd@192.168.9.1` 访问。
需要"真实 LAN 客户端"做实际联网/封锁验证时见 [§9](#9-让虚拟机真的连上外网--真实-lan-客户端模拟)。

---

## 0. 连接信息

| 项目 | 值 |
| --- | --- |
| SSH | `ssh sshd@127.0.0.1 -p 10022`（dropbear；WAN 侧 user-net 转发到 `10.0.2.15:22`）。切到 §9.2 的 tap LAN 后也可直接 `ssh sshd@192.168.9.1` |
| 账号 | `sshd` / 与 Web 控制台相同的密码（首次改密后即生效；`scripts/01_enable_ssh.sh` 把该账号 shell 换成 `/bin/bash`） |
| Web | `http://<宿主IP>:8081/` （socat 转发 0.0.0.0:8081 → 127.0.0.1:18080 → 客户机 :80）。tap LAN 下也可直接 `http://192.168.9.1/` |
| 控制台 | VNC 127.0.0.1:5901；QEMU monitor `/tmp/ikuai-mon.sock` |
| 客户机文件系统 | `/` 根分区(111M, 每次重启还原) · `/etc/mnt`(sda3, 50M, 持久) · `/etc/log`(sda5, 15.5G, 持久) |

> 注意: QEMU user-net 的 `hostfwd` 只绑在 `127.0.0.1`，所以走 user-net 时 SSH/Web 必须从宿主机本机发起；
> 若要通过局域网访问，需要像 `vm/run.sh` 里那样用 socat 再转发一层(或直接用 §9.2 的 tap LAN)。

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

> **签名范围要说清楚**:
> * **框架本体(`/etc/mnt/.boot`)必须签名** —— 固件 `plugins.sh` 会用内置公钥校验
>   `MANIFEST.MF` + `SIGNATURE.RSA`，再逐文件比对 SHA-256；任何一项不通过，整个框架
>   都不会运行。所以改动框架里任何一个被清单列出的文件后都必须重新 `sign.sh + build.sh`。
> * **第三方插件包不需要签名** —— 插件 zip 直接上传即可安装(参见 6.5.1)。可选地支持
>   `MANIFEST.MF`(校验摘要) 与 `SIGNATURE.RSA`+`plugin.pub`(额外验签)，但不强制。

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

### 2.4 打包的"红线": 清单必须与实际铺开的文件完全一致

设备端挂载由固件自带的 `/usr/ikuai/script/plugins.sh:boot()` 负责，它做三件事，**缺一即整包不挂载**：

```bash
local BOOT_PATH="/etc/mnt/.boot"
openssl dgst -sha256 -verify <内置公钥> -signature $BOOT_PATH/SIGNATURE.RSA $BOOT_PATH/MANIFEST.MF && \
while read -r line; do          # 逐行读清单
    Name: <文件>                #   → 与 .boot 下真实文件比对
    SHA-256-Digest: <摘要>      #   → sha256sum 必须一致, 否则直接 return
done < $BOOT_PATH/MANIFEST.MF && \
test -x "$BOOT_PATH/install.sh" && "$BOOT_PATH/install.sh"   # 最后才执行
echo 1 > /etc/plugins_ok
```

> 踩过的坑(整包不挂载 = 框架、Web 插件、**连 SSH 的 shell 修改一起全丢**)：
> * `sign.sh` 扫的是**工作区**(当时含 `examples/rust-plugin/target/` 的 35MB cargo 缓存)，
>   而 `build.sh` 打 tar 时用 `--exclude` 排掉了它们 → 清单 103 项里 64 项在包里不存在 →
>   设备校验 sha256 失败 → 直接 return；
> * 另一个方向：`sign.sh` 用 `! -name "install.sh"` 把**所有**同名文件都排除了，
>   而 tar 里带着 `examples/rust-plugin/pkg/install.sh` → 反向漏项。
>
> 修法：`sign.sh` 与 `build.sh` 共用 `.tools/package.exclude`(一套规则)，
> 并且新增 `.tools/verify_package.sh` —— **本地复刻设备端那三步校验**，打包后必跑：

```bash
bash .tools/sign.sh && bash .tools/build.sh
bash .tools/verify_package.sh            # >>> 通过: 该包在设备上可正常挂载
# 失败会逐条列出"缺失/摘要不一致/未列入清单"的文件, 修好再发版
```

**基础包与插件是两个独立发布物**：基础包只含框架本体，`package.exclude` 里排除了
`examples/`(插件示例与构建产物)、`tools/`(历史签名脚本)、`docs/images/`(README 截图)；
插件(docker/rustdemo 等 zip)在「系统设置 → 插件管理」里单独上传安装，不需要签名、不参与这份清单。

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
| Web 页面 | 系统设置 → 插件管理(`#/system-setting/plugin-management`)：**无"需要绑定爱快云平台"提示**，点开插件后标题显示"插件"而不是"Docker" |
| 前端补丁 | 分包里 `plugins/docker/` 已变成 `plugins/app/`、`yunbindstatus=2` |
| 使用条款 | 首次进入只有灰色按钮，同意后出现插件卡片；`/etc/mnt/plugins/.eula` 有 `accepted=1` |

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

配置完 WAN 的 iKuai 正规做法是「网络设置 → 内外网设置 → wan1 → 绑定网卡 eth1 → 动态 IP(DHCP)」，
用官方接口一次配好并持久化的做法见 [§9](#9-让虚拟机真的连上外网--真实-lan-客户端模拟)。

### 5.3 采集踩坑与修复(3 个真 bug)

| 现象 | 原因 | 修法 |
| --- | --- | --- |
| 审计日志只有开机那一次的数据，`proc/conn/dns` 不再更新 | 任务只写进了 `/etc/crontabs/cron.d/`，而 iKuai 的 `crond` 只读 `/etc/crontabs/root`(它的 `crond_commit` 是 `cat cron.d/* > root`，时机不对就会被整体重写) | `au_install_cron()` / `bd_install_guard()` 把任务**直接追加进 `/etc/crontabs/root`** |
| `dns.cloud` 事件每分钟把一整天的域名重刷一遍，体检计数失真 | 每次 tick 都全文 `grep` 当天 DNS 日志 | 用偏移量状态文件 `$AU_STATE/dns.scan.<日期>` **只扫新增内容**(日志被轮转/清空时自动归零重扫) |
| 体检报告"云端域名解析"恒为 0 | 统计写成了 `grep -c "cloud\."`：事件名里点号在 **cloud 前面**(`dns.cloud          解析...` 后面是空格)，这个表达式永远匹配不到 | 改成 `grep -cE 'dns\.cloud|cloud\.(ip\|port)\|probe\.cloud'` |

修复后在真实外网环境实测：

```
$ grep -nE 'ikaudit|backdoor_guard' /etc/crontabs/root
11:* * * * * /etc/mnt/.boot/bin/backdoor_guard
12:* * * * * /etc/mnt/.boot/bin/ikaudit watch
13:*/10 * * * * /etc/mnt/.boot/bin/ikaudit report

$ grep -E '云端域名解析|结论' /etc/log/ikguard/report.txt
DNS:    云端域名解析  : 292 次(今日审计日志)
结论: 正常(无后门进程, 无云端连接)

$ iptables -nvx -L FORWARD | grep ikuai_blk
       6      360  DROP  all  --  *  *  0.0.0.0/0  0.0.0.0/0  match-set ikuai_blk dst
```

> DNS 日志是多个 `tcpdump`(逐网卡)并发追加同一个文件，高并发时行可能交错；
> **事件级的 `audit-*.log` 才是可靠证据来源**，`dns-*.log` 只当原始抓包存档看。

---

## 6. Web 插件系统(iKuai 官方插件机制)

iKuai 的"系统设置 → 插件管理"页面(`func_name=plugins`)是**数据驱动**的：

```
/usr/ikuai/function/plugins          <- 后端入口(实为 ../script/plugins.sh 的软链)
  boot()   开机: 校验 .boot 签名并执行 install.sh
  show()   TYPE=data -> __show_data(): 遍历 /usr/ikuai/www/plugins/*/*.json 聚合为 data:json
前端分包(路由 system-setting/plugin-management)
  dockerList = Data.data
  卡片图标  = /plugins/<目录>/<json 里的 name>.png
  卡片页面  = /plugins/<目录>/<json 里的 name>.html   (iframe 加载)
```

`<目录>` 官方写死为 `docker`(容易被误认为 Docker 功能)，本框架用 `plugin_web_patch()` 改成 `app`。

所以新增一个"网页插件"只需要三样东西：

```
www/plugins/<name>/<name>.json     插件元数据(name 必须等于文件名, 决定卡片与 iframe 地址)
www/plugins/app/<name>.html        插件页面(自包含 HTML, 直接 fetch /Action/call)
www/plugins/app/<name>.png         卡片图标
usr/ikuai/function/<func_name>     后端接口(shebang 为 #!/bin/bash /etc/ikcommon)
```

`scripts/03_enable_plugins.sh` 每次开机会把它们同步到根分区：

```
/etc/mnt/.boot/www/plugins/<name>/<name>.json -> /usr/ikuai/www/plugins/<name>/<name>.json
/etc/mnt/.boot/www/plugins/app/*              -> /usr/ikuai/www/plugins/app/
/etc/mnt/.boot/usr/ikuai/function/<func_name> -> /usr/ikuai/function/<func_name>
```

> 同步前会清空 `/usr/ikuai/www/plugins/*`，并且**未同意《使用条款》时只铺占位卡片 `terms`**
> (见 6.4)，同意后再换成正式插件卡片。

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

### 6.2 去掉"使用插件功能需要绑定爱快云平台"拦截

iKuai 的「插件管理」页(`system-setting/plugin-management`)在未绑定爱快云平台时只显示一句
`common.Plugin_management.tip` = "使用插件功能需要绑定爱快云平台！"，**插件列表被整块隐藏**。
判定逻辑在前端分包里:

```js
// /usr/ikuai/www/static/js/152.<hash>.js.gz   (未压缩后约 6.9K)
showData: function(){
    this.$http.post(apiUrl,{func_name:"register",action:"show",param:{TYPE:"data,gwid"}})
        .then(function(e){
            var i = e.data.Data.data[0];
            this.yunbindstatus = "" != i.code ? 2 : 1;   // code 为空 = 未绑定 -> 1(显示提示)
            this.yunbindstatus && this.dockerShow();     // 2 才去拉插件列表
        });
}
```

本框架的插件完全跑在本地(不读云平台)，所以开机时把这段改掉，直接进入插件列表分支:

```
yunbindstatus=""!=i.code?2:1   ->   yunbindstatus=2            # 1) 解除云平台绑定拦截
plugins/docker/                ->   plugins/app/                # 2) 页面目录不再叫 docker
t._v("Docker")                 ->   t._v("插件")                 # 3) 点开插件后的小标题
.tipCloudBind=!0               ->   .tipCloudBind=!1            # 4) 顶部"爱快e云APP"二维码弹框不再弹出
_s(e.name)                     ->   _s(e.title||e.name)         # 5) 卡片显示 title(中文名)而不是文件名
```

实现: `lib/plugin.sh:plugin_web_patch()`，由 `scripts/03_enable_plugins.sh` 每个开机调用
(根分区每次重启还原，必须每开机打)。因为前端分包是 **gzip 静态资源**，做法是
"zcat 解开 → sed 改写 → gzip 重新压缩 → 写回"，落盘前逐项复核(改写目标必须消失、
新写法必须出现)，找不到目标文件/改写失败时保持原样(不会打坏页面)。

```
$ bash /etc/mnt/.boot/scripts/03_enable_plugins.sh
[plugin]   已打补丁: 152.27c9514f5737f839b145.js.gz (云平台拦截=1 目录改名=1 标题=1)
[plugin] Web 前端补丁完成(修改 1 个分包)
```

验证:

```
$ cd /usr/ikuai/www/static/js && zcat 152.*.js.gz | grep -o 'yunbindstatus=[^,;)]*\|plugins/[a-z]*/\|t._v("插件")'
yunbindstatus=2
plugins/app/
t._v("插件")
$ curl -s -H 'Accept-Encoding: gzip' http://127.0.0.1:18080/static/js/152.*.js.gz | zcat | grep -c 'plugins/docker/'
0
```

实测(Chromium 打开 Web → 系统设置 → 插件管理): 绑定提示消失、插件卡片 `ikguard` 正常显示、
点开卡片 iframe 内的控制台可读状态、可切页签、可改开关(改完 `/etc/mnt/boot_args` 立即变化)。

> 注意: 分包文件名不变，浏览器可能仍用旧缓存 → 改完请 **Ctrl+F5 强刷**一次。
> 前端文案本身仍在 i18n 里(`common.Plugin_management.tip`)，只是不再显示。
> 同一份代码里的「云防火墙」页(`49.<hash>.js.gz`, 判定变量 `isBindCloud`)是另一个云功能，
> 本框架不动它。

### 6.3 内置插件 `ikguard`

* 页面: 系统设置 → 插件管理 → `ikguard` 卡片
  (等价直达: `http://<宿主IP>:8081/plugins/app/ikguard.html`)
* 后端: `func_name=ikguard`，动作
  `show`(TYPE=`data/flags/plugins/pending/eula/logs/probe`) / `seting` / `eula` /
  `apply` / `plugin` / `dns` / `probe` / `logclear`
* 页面功能:
  * **概览**: 框架版本、签名校验、后门进程、ipset 条目、封锁规则/命中数、DNS 采集状态、日志占用
  * **开关配置**: `backdoor` `backdoor_hosts` `audit` `sshd` `plugins` `cron` `shell`
    修改即写入 `/etc/mnt/boot_args` 并立刻重跑对应脚本
  * **插件管理**: **上传 zip 安装**、扫描 `/etc/mnt/plugins/*.zip`、列出/卸载插件
  * **审计日志**: 实时查看 report/audit/dns/proc/conn/boot 日志
  * **工具**: 云端连通性自检(带结果回读)、DNS 记录开关 —— 每一项都有用途说明

前端图标与页面都在 `www/plugins/app/`(`ikguard.{html,png}`、`terms.{html,png}`)，
图标是 64×64 的圆角盾牌(盾牌=安全防护，文档图标=使用条款)。

### 6.4 首次启用需要同意《使用条款》

插件功能属于对官方固件的第三方改造，首次启用前需要用户明确同意条款:

* 条款正文: `www/eula.txt`(部署后 `/etc/mnt/.boot/www/eula.txt`)，版本 `v1.0`，
  内容包含: 许可与用途、禁止行为(不得用于破解商业/未授权功能、不得改 Logo 与标识、
  与官方商业功能冲突时不得复用官方实现、不得违法使用)、风险与免责(AS IS、责任限制、
  第三方索赔自负、保留修改与停止维护的权利)、其他(同意记录仅存本地等)。
* **未同意时**: 插件管理页不显示任何插件，只有一个灰色按钮
  "查看并同意《使用条款》"(占位卡片 `terms`，页面 `www/plugins/app/terms.html`)。
  点击弹出条款弹框，点"同意并启用"后: 后端 `ikguard eula op=accept` 写入
  `/etc/mnt/plugins/.eula`，立刻重跑 `scripts/03` 把卡片换成正式插件，页面自动刷新。
* **未同意时整机都不可见**: 不只是不显示卡片 —— `plugin_web_link()` 会跳过并撤销插件的
  卡片/页面/图标与后端接口链接(`/usr/ikuai/www/plugins/...`、`/usr/ikuai/function/...`)，
  只保留"同意入口"占位卡片；同意后 `eula op=accept` 会重跑 `scripts/03` 立即恢复。
  注意 `scripts/03` 里的顺序是 **先 `plugin_web_sync`(清空并重铺) 再 `plugin_boot`(建插件链接)**，
  否则会把插件刚建好的软链一起清掉。
* **同意后**: 记录持久保存在 `/etc/mnt/plugins/.eula`，不再询问；
  后端 `plugin` 动作也会校验该文件(未同意直接拒绝，避免绕过前端)。
* 审计日志里会留痕: `eula.accept` / `eula.reject` 事件。

```
$ cat /etc/mnt/plugins/.eula
accepted=1
version=v1.0
time=2026-10-13 21:40:12
```

### 6.5 通过 Web 接口直接调用(不打开浏览器也能验证)

> `passwd` 要传 **md5(密码)**，登录成功后 cookie 里带 `sess_key`。
> 插件管理页的路由是 `#/system-setting/plugin-management`(注意不是 `linkTo` 里那个名字)。

```bash
PW=$(printf '%s' '你的密码' | md5sum | cut -d' ' -f1)
curl -s -c /tmp/ck -X POST http://127.0.0.1:18080/Action/login \
     -H 'Content-Type: application/json' \
     -d "{\"username\":\"admin\",\"passwd\":\"$PW\",\"remember_password\":0}" >/dev/null
curl -s -b /tmp/ck -X POST http://127.0.0.1:18080/Action/call \
     -H 'Content-Type: application/json' \
     -d '{"func_name":"plugins","action":"show","param":{"TYPE":"data"}}'   # 插件卡片列表
curl -s -b /tmp/ck -X POST http://127.0.0.1:18080/Action/call \
     -H 'Content-Type: application/json' \
     -d '{"func_name":"ikguard","action":"show","param":{"TYPE":"data,flags,plugins,eula"}}'
```

#### 6.5.1 用 HTTP 上传安装插件包(zip)

上传与安装是两步(和官方"上传固件"一样的套路): 先 POST 文件到 `/Action/upload`
(落盘到 `/tmp/iktmp/import/<文件名>`，注意上传前会清空该目录、单文件上限 50MB)，
再调用 `ikguard plugin op=install name=<文件名>` 解压安装。

> **坑**: iKuai 的 `ActionUpload` 存盘用的是 multipart 的**字段名**(`getUploadHead(...).name`)，
> 不是 `filename=`。所以表单字段名必须写成原始文件名，否则文件会存成 `file`
> 导致下一步 `install name=xxx.zip` 找不到文件。

```bash
# 1) 上传(字段名 = 文件名!)
curl -s -b /tmp/ck -F "mytool.zip=@mytool.zip" http://127.0.0.1:18080/Action/upload
#    -> {"Result":10000,"ErrMsg":"Success"}

# 2) 安装(会先归档到 /etc/mnt/plugins/.installed/ 再解压到 /etc/mnt/plugins/<名称>/)
curl -s -b /tmp/ck -X POST http://127.0.0.1:18080/Action/call \
     -H 'Content-Type: application/json' \
     -d '{"func_name":"ikguard","action":"plugin","param":{"op":"install","name":"mytool.zip"}}'
```

插件包格式(完整版, 见 `examples/rust-plugin/` 的可运行示例):

```
Release                    必需  plugin=<名称>  version=<版本>(名称决定安装目录与卡片名)
install.sh                 必需  安装时执行(需幂等)
boot.sh                    可选  仅开机执行(存在时优先于 install.sh)
uninstall.sh               可选  卸载
bin/*                      可选  自动软链到 /usr/sbin(去掉 .sh 后缀)
etc/*                      可选  自动软链到 /usr/local/etc
www/plugins/<n>/<n>.json   可选  插件卡片(名字必须与目录名一致)
www/plugins/app/<n>.html   可选  插件页面(iframe 打开)
www/plugins/app/<n>.png    可选  卡片图标(建议 64x64)
function/<func_name>       可选  后端接口(shebang: #!/bin/bash /etc/ikcommon)
MANIFEST.MF / SIGNATURE.RSA 可选  不强制签名(带清单才校验摘要)
```

`www/` 与 `function/` 由 `lib/plugin.sh:plugin_web_link()` 在**安装和每次开机**时软链到根分区，
卸载时由 `plugin_unlink()` 精确清理 —— 插件脚本不用自己维护这些链接。

打包: zip 里可以直接放这些文件, 也可以是"单层目录"(如 `zip -r mytool.zip mytool/`),
安装时会自动下钻一层; 名字取自 `Release` 的 `plugin=`, 没有 `Release` 时用目录名。

命令行等价做法(不经过 Web):

```bash
ssh sshd@<设备> "ikplugin install /tmp/iktmp/import/mytool.zip"     # 直接安装
ssh sshd@<设备> "cp mytool.zip /etc/mnt/plugins/ && ikplugin scan"  # 或丢进目录后扫描
```

### 6.6 插件示例: Rust 版 `rustdemo`

仓库里带了一个可直接编译安装的示例插件 `examples/rust-plugin/`(Rust + redb 嵌入式数据库 +
Web 配置页)，用来演示"独立插件"的完整写法，也可以当模板：

```
examples/rust-plugin/
├── src/main.rs         采集守护进程 + 嵌入式数据库 + Unix socket 查询接口
├── build.sh            编译 musl 静态二进制 + 打成 dist/rustdemo.zip
└── pkg/                Release / install.sh / boot.sh / uninstall.sh /
                        bin/rustdemo / function/rustdemo / www/plugins/...
```

它演示的关键点(详细说明见 `examples/rust-plugin/README.md`):

1. **安装/卸载/开机自启**: 三个脚本分别对应 install / uninstall / boot 动作；数据与数据库放在
   持久分区 `/etc/mnt/plugins/rustdemo/data/`，重启不丢；开机由 `boot.sh` 重新拉起守护进程。
2. **前端设置**: 页面 `www/plugins/app/rustdemo.html`(卡片 `www/plugins/rustdemo/rustdemo.json`)
   提供"采集间隔/保留条数/备注"配置表单与采样数据查看，后端 `function/rustdemo` 提供
   `show/seting/clear/sample` 动作，配置真正写进数据库的 `config` 表。
3. **redb 独占锁的处理**: 数据库同时只能被一个进程打开，所以守护进程是唯一写入者，
   并在 `data/rustdemo.sock` 上提供一行命令/一行 JSON 的 Unix socket 接口；
   命令行与后端接口优先走 socket，守护不在时才直接开库 —— 两边共用同一套实现函数。
4. **链接方式二选一**: 设备是 uClibc-ng 1.0.40(`/lib/ld64-uClibc.so.0`)。
   方式 A = `x86_64-unknown-linux-musl` 静态(仓库默认，实测 967,328 字节 / 整包 464,506 字节)；
   方式 B = 用 [iKuai SDK](https://github.com/deadash/ikuai-sdk) 的 uClibc 交叉工具链动态链接设备自带 libc
   (体积更小，但 Rust 没有 `x86_64-unknown-linux-uclibc` 内置目标，需要自定义 target + nightly `-Zbuild-std`)。
   两种方式的完整步骤、SDK 下载/relocate/environment-setup、体积对比见
   [`examples/rust-plugin/README.md`](../examples/rust-plugin/README.md)。

实测(在设备上安装后):

```
$ ikplugin list
NAME                     VERSION      LOCATION
rustdemo                 1.0.0        /etc/mnt/plugins/rustdemo

$ /usr/sbin/rustdemo stats
{"samples":12,"db_size":3702784,"interval":"15","retention":"500","daemon_running":true,...}

$ /usr/ikuai/function/rustdemo show TYPE=data
{"data":{"stats":{...},"config":{...},"samples":[...]}}
```

---

## 7. 开关(`/etc/mnt/boot_args`)

| 键 | 默认 | 作用 |
| --- | --- | --- |
| `sshd` | 1 | 控制台账号 shell 换成 bash，可 SSH 登录 |
| `backdoor` | 1 | 后门/更新通道阻断(进程+文件+网络三层) |
| `backdoor_hosts` | 0 | 额外把云端域名写入 `/etc/hosts` 指向 0.0.0.0 |
| `plugins` | 1 | 插件系统(含 Web 插件资源同步；首次使用需同意《使用条款》) |
| `cron` | 1 | 铺开 `/etc/mnt/cron.d` |
| `shell` | 1 | 链接 `/etc/mnt/shells` 下的程序/配置 |
| `audit` | 1 | 审计取证(进程/DNS/网络/封锁命中) |

**已废弃并会自动清理的两个键**(升级时 install.sh 会 `sed -i` 删除):

| 键 | 原意 | 现状 |
| --- | --- | --- |
| `remote` | iKuai 云"远程控制/远程维护"开关 | 历史遗留的空开关：**没有任何脚本读取它**。真正的云端远程控制已由后门阻断层覆盖 —— `ik_rc_client`/`cre`/`pmd` 被换成空壳、`monitor_process.sh` 不再守护、云端域名/IP/端口被 DROP。所以"默认关闭"= 该通道本来就不可用 |
| `plugins_verify` | 插件包强制签名校验 | 已去掉：插件包不再要求签名(带 `MANIFEST.MF` 只校验摘要，带签名+公钥才额外验签) |

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

## 9. 让虚拟机真的连上外网 + 真实 LAN 客户端模拟

前面几节验证封锁时设备常常"没有外网"，只能临时 `ifconfig` 造一个地址，说服力不足。
这一节给出**持久化**做法：用官方接口把 WAN 配起来(等价于 Web 操作)，再把 LAN 换成真实二层网络，
让宿主机上的一台"客户端"真正经过 iKuai 转发+拨号+NAT 上网，从而模拟实际应用。

### 9.1 用官方接口配置 WAN(持久, 重启自动恢复)

`vm/run.sh` 给虚拟机两块网卡：`eth0`=LAN(user-net 192.168.9.0/24)、
`eth1`=WAN(user-net 10.0.2.0/24，网关 10.0.2.2 / DNS 10.0.2.3，QEMU 自带 DHCP)。
设备侧只需把 `eth1` 绑到 `wan1` 并选 DHCP：

```bash
# 在设备上(或 ikctl sh)执行, 等价于 Web「网络设置→内外网设置→wan1→绑定网卡→动态IP」
/usr/ikuai/function/wan save id=1 name=wan1 bandif=52:54:00:00:01:02 bandmode=0 \
    internet=1 default_route=1 disc_auto_switch=1 link_time=00:00-23:59 \
    check_link_mode=3 check_link_host=www.baidu.com clientid= mac= speed=0 duplex=0 comment=
```

字段来历(前端 `saveWan()` 的真实 payload)：`internet` 0=静态 / 1=DHCP / 2=PPPoE / 3=多拨；
`bandif`＝绑定的网卡 MAC(`bandmode=0` 时是单个 MAC，多个用逗号)；`link_time`＝`开始-结束`；
`check_link_mode=3` 表示用 `check_link_host` 做线路检测。设备侧校验函数是 `wan.sh:__check_param_save()`。

结果(重启后不变，因为写进了 iKuai 配置)：

```
wan1  UP  10.0.2.15/24        default via 10.0.2.2 dev wan1
# curl -s -o /dev/null -w '%{http_code}\n' http://www.baidu.com      -> 200
```

> **QEMU user-net(slirp) 的坑**：slirp 只转发"设备自己地址(10.0.2.15)"的包，ICMP 还需要宿主
> 建 raw socket(非特权跑不了)，所以**设备上 ping 外网 IP 一定 100% 丢包**，但 TCP 完全正常。
> 判断能否出网请用 `curl` / `nc` / `/dev/tcp`，不要用 `ping`。

### 9.2 LAN 换成真实二层网络(tap + bridge)

只用 user-net 时宿主机只能通过 `hostfwd` 摸到 192.168.9.1，没法扮演"LAN 里的另一台机器"。
换成 tap+bridge 后宿主机就在同一个二层网络里，还能再开一个网络命名空间当客户端：

```
tap0 ── br0(192.168.9.100/24) ── veth-h ‖ clientns(192.168.9.50/24, 默认网关 192.168.9.1)
          │
    虚拟机 eth0 = iKuai LAN 192.168.9.1                  eth1 = WAN(10.0.2.15)
```

```bash
sudo bash vm/net-setup.sh      # 建 tap0/br0/veth/clientns(幂等; tap 属主自动设为调用者)
bash vm/run.sh                 # 启动虚拟机(LAN 用 tap, WAN 仍走 user-net 并保留 hostfwd)
```

`run.sh` 在 WAN 侧仍保留 `127.0.0.1:10022→10.0.2.15:22` 与 `127.0.0.1:18080→10.0.2.15:80`，
所以即使 LAN 改坏了 SSH/Web 也进得去；LAN 正常时可直连 `ssh sshd@192.168.9.1`、
`http://192.168.9.1/`(ikctl 用 `IK_HOST=192.168.9.1 IK_PORT=22`)。

> 踩坑：`net-setup.sh` 是用 `sudo` 跑的，tap 属主必须写 `${SUDO_USER:-$(id -un)}`；
> 若用 `id -un`(sudo 下是 root)，非 root 的 qemu 会报
> `could not configure /dev/net/tun (tap0): Operation not permitted`。

### 9.3 客户端实测(真实流量 + 封锁对照)

```bash
sudo bash vm/client-test.sh
```

实测输出(设备 kvm 全虚拟化，宿主 1Gbps 出口)：

```
== 1) DNS 解析 ==       www.baidu.com / github.com 正常(用 iKuai DHCP 下发的 114.114.114.114)
== 2) HTTP / HTTPS ==   baidu http=200 36.152.44.93 连接 54ms ; baidu https=200 ; github https=200
== 3) 下载测速 ==       mirrors.aliyun.com 254968 字节, 平均 1.47 MB/s
== 4) 页面内容 ==       百度首页 HTML 正常返回
== 5) TCP 时延 ==       36.152.44.132 连接 25ms / github 58ms
== 6) 云端域名 ==       302/pkgmanager/download.ikuai8.com 解析到 58.221.58.100 / 59.110.6.135, 全部连不上
== 7) 对照 ==           36.152.44.132:443 可连通 ✓ | 58.221.58.100:443 被 DROP ✓
```

路由器侧同时留痕 —— 这就是"确认没有后门进程/连接"的证据链：

```
$ grep -c '192.168.9.50' /etc/log/ikguard/dns-<日期>.log        # 194  客户端 DNS 查询条数
$ grep '192.168.9.50' ... | grep -ci ikuai8                     # 14   其中云端域名
$ iptables -nvx -L FORWARD | grep ikuai_blk                     # 6 包 被 DROP
$ grep -cE 'dns\.cloud' /etc/log/ikguard/audit-<日期>.log       # 292  dns.cloud 事件
$ ps | grep -E 'cre|pmd|ik_rc_client'                           # (无)
```

> 客户端 resolver 用的是 iKuai DHCP 下发的公网 DNS(`dhcp_server` 的 `dns1/dns2` = 114.114.114.114 /
> 223.5.5.5)，不是路由器自身 —— iKuai 的本地 DNS 在 54 端口，LAN 侧 53 没有监听，别按"网关即 DNS"去配。

### 9.4 还原成原来的 user-net(可选)

```bash
sudo bash vm/net-teardown.sh                 # 删 clientns/br0/tap0/veth
pkill -f "qemu-system-x86_64 -name ikuai"
bash vm/run.sh.bak-<时间戳>                  # 旧的 user-net 版启动脚本(启动前自动备份)
```

WAN 配置(wan1 绑定 eth1)是设备侧配置，与宿主机网络无关，还原后依然有效。

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
`通过 N/24` 汇总。实测重启后为 24/24 通过。

## 附录 C. 一条命令更新+重启(ikupd.py)

只要 **地址 / 账号 / 密码** 就能升级插件包并重启(全程走设备自带接口, 不依赖 ssh 里的文件操作):

```bash
# 更新基础包并自动重启、等它回来
python3 ikupd.py -a 192.168.9.1 -u admin -p '<控制台密码>' \
        update ikuai-plugins-v0.0.3-base.bin --reboot --wait

python3 ikupd.py -a 192.168.9.1 -u admin -p '<控制台密码>' update <包>   # 只更新
python3 ikupd.py -a 192.168.9.1 -u admin -p '<控制台密码>' reboot --wait  # 只重启
python3 ikupd.py -a 192.168.9.1 -u admin -p '<控制台密码>' status        # 看挂载状态
```

动作链: `POST /Action/login` → `POST /Action/upload`(字段名=文件名) →
`/Action/call {func_name:upgrade, action:parse_file}` → `{action:update_file}` → SSH `reboot`。
`status` 会打印 `/etc/plugins_ok`、`/etc/mnt/.boot/Release` 里的版本、`boot_args`、
`sshd` 账号 shell 以及 `ikguard` 是否挂载。
