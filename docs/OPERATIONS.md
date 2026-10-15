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

实测(SSH; `/etc/mnt` 已按 §1.2 从 50M 扩到 1G):

```
$ df -h
Filesystem                Size      Used Available Use% Mounted on
/dev/root               111.0M    107.8M    810.0K  99% /          <- 根分区, 每次重启还原, 只剩 ~800K
tmpfs                     1.9G      4.3M      1.9G   0% /tmp
/dev/sda3               988.4M      1.5M    931.7M   0% /etc/mnt    <- 持久盘, 放框架/插件
/dev/sda5                14.6G     20.4M     13.8G   0% /etc/log    <- 持久日志分区
```

结论与约定:

| 用途 | 位置 | 说明 |
| --- | --- | --- |
| 框架本体 / 插件包 | `/etc/mnt/.boot`、`/etc/mnt/plugins` | 931M 可用，持久，重启不丢 |
| 审计日志 / DNS 抓包 / 体检报告 | `/etc/log/ikguard/` | 14.6G 可用，持久，重启不丢 |
| 运行时软链(Web 资源、后端接口、/usr/sbin) | `/` 根分区 | 每次重启由 `scripts/03_enable_plugins.sh` 重建，**只放软链和几 KB 的页面** |

根分区只剩 800K，务必不要把大文件写进 `/`（框架只往根分区放软链和 `www` 插件页面）。

### 1.2 宿主机侧手工扩容(离线; 50M -> 1G 实测)

> 日常在设备上执行 `ikexpand set` 重启即可(**见 §1.3**)。这一节是没有设备、需要离线
> 动盘、或者要改布局数值时的等价手工步骤。

出厂分区表里 sda3(`/etc/mnt`) 只有 50M，装不下带二进制的插件；而磁盘另外 15.9G 全给了
`/etc/log`(sda5，位于扩展分区 sda4 内)且基本空闲。所以**直接从 sda5 挪 1G 给 sda3**：

```
                Start            End         Size           用途
sda1             2048         104447          50M          根(只读镜像展开, 不动)
sda2           104448         114687           5M          预留(不动)
sda3           114688    217087 -> 2211839    50M -> 1G     /etc/mnt   ← 变大
sda4         217088 -> 2211840   33554431     扩展分区        ← 整体后移
sda5       219136 -> 2213888     33554431     15.9G -> 14.9G /etc/log   ← 后移并缩小
```

**必须离线做**(设备关机，在宿主机上用 `qemu-nbd` 直接操作 qcow2)；在线改分区表会失败或丢数据。
要点：sda3 **只扩分区尾 + `resize2fs`，数据原地不动**；sda5 要给 sda3 让位只能整体后移，
先把它的文件系统缩到最小再 dd 搬走；**两个分区的文件系统 UUID 必须保持不变**(固件/框架按 UUID 挂载)。

```bash
# 0) 宿主机: 整盘备份, 再优雅关机
cp --sparse=always ikuai.qcow2 ikuai.qcow2.bak
printf 'system_powerdown\n' | socat - UNIX-CONNECT:/tmp/ikuai-mon.sock   # 等 qemu 退出

# 1) 离线挂上磁盘
sudo modprobe nbd max_part=16
sudo qemu-nbd -c /dev/nbd0 -f qcow2 ikuai.qcow2 && sudo partprobe /dev/nbd0

# 2) 文件系统必须干净才能 resize; 并记录 UUID(保持挂载用)
sudo e2fsck -f -y /dev/nbd0p3 ; sudo e2fsck -f -y /dev/nbd0p5
sudo blkid /dev/nbd0p3 /dev/nbd0p5

# 3) 文件级兜底备份
sudo mkdir -p /mnt/ik3 /mnt/ik5
sudo mount -o ro /dev/nbd0p3 /mnt/ik3 ; sudo mount -o ro /dev/nbd0p5 /mnt/ik5
sudo tar -C /mnt/ik3 -czpf backup-mnt.tar.gz . ; sudo tar -C /mnt/ik5 -czpf backup-log.tar.gz .
sudo umount /mnt/ik3 /mnt/ik5

# 4) sda5 缩到最小并拷出来(实测 ~194M)
sudo resize2fs -M /dev/nbd0p5
B=$(sudo dumpe2fs -h /dev/nbd0p5 | awk '/^Block count:/{print $3}')
sudo dd if=/dev/nbd0p5 of=sda5-fs.img bs=1M count=$(( B*4/1024 + 1 ))

# 5) 改分区表: sda3 50M -> 1G
sudo sfdisk --force --no-reread /dev/nbd0 <<'PT'
label: dos
label-id: 0xea97440f
unit: sectors
/dev/nbd0p1 : start=   2048, size= 102400, type=83
/dev/nbd0p2 : start= 104448, size=  10240, type=83
/dev/nbd0p3 : start= 114688, size=2097152, type=83
/dev/nbd0p4 : start=2211840, size=31342592, type=5
/dev/nbd0p5 : start=2213888, size=31340544, type=83
PT
sudo partprobe /dev/nbd0

# 6) sda5 文件系统写回新偏移, 两个文件系统都长到分区大小
sudo dd if=sda5-fs.img of=/dev/nbd0p5 bs=1M conv=notrunc
sudo e2fsck -f -y /dev/nbd0p5 && sudo resize2fs /dev/nbd0p5
sudo e2fsck -f -y /dev/nbd0p3 && sudo resize2fs /dev/nbd0p3
sudo qemu-nbd -d /dev/nbd0
# 起虚拟机: bash vm/run.sh
```

> 实测结果：`/etc/mnt` 988.4M、`/etc/log` 14.6G，插件与 `ikuai` 配置全部完好，重启后一切正常。
> 以后还要扩就重复上面步骤（改 sda3/sda4/sda5 的 start/size）。

### 1.1 创建日志目录(已由框架自动完成，手工操作如下)

```
ssh sshd@127.0.0.1 -p 10022
mkdir -p /etc/log/ikguard
chmod 755 /etc/log/ikguard
df -h /etc/log
```

### 1.3 设备端自动扩容(ikexpand, 推荐)

设备上写一条"扩容请求", 重启后由开机脚本完成 —— 全程用**设备自带工具**
(`fdisk` 改分区表 / `mke2fs` 重建文件系统 / `dd` 写盘), 不依赖宿主机、不引入自研二进制:

```bash
ikexpand status      # 看当前大小 / 待执行请求 / 上次结果
ikexpand set 1024    # 目标 /etc/mnt = 1024 MiB(只扩不缩), 写入请求(不改盘)
reboot               # 重启; 开机流程里执行扩容(会自动再重启一次)
ikexpand status      # 结果; 过程日志 /etc/log/ikguard/expand.log
```

组成: `bin/ikexpand`(写/查/撤请求) + `scripts/09_expand_mnt.sh`(开机执行器)。

**也可以完全在网页上做**(推荐, 不用 SSH):

1. 「系统设置 → 插件管理 → 安全防护控制台」→ **插件管理** 页顶部就是两块盘:
   `系统盘 /etc/mnt` 与 `日志盘 /etc/log` 的容量/已用; **系统盘小于 1G 时会标红**,
   旁边有「扩容…」按钮跳到「工具」页。
2. **工具** 页的「系统盘(/etc/mnt)扩容」里填目标大小(**单位 G**) → 「提交扩容并重启」。
   上限是算出来的: 磁盘总量 − 日志盘已用内容 − 256M 余量 − **保留分区**(有业务绑定的数据盘),
   超过会被拒绝并提示, 当前值同样不允许(只扩不缩)。旁边「撤销待执行请求」可撤回。
3. 点提交会先二次确认「**即将重启**」; 提交成功后设备自动重启, 在启动过程中改盘
   (会再自动重启一次), 约 1~2 分钟恢复。成功与失败都会写日志:
   `/etc/log/ikguard/expand.log`(引擎日志) 与 `/etc/log/ikguard/audit-*.log` 的 `disk.expand` 事件
   (提交/拒绝/撤销/失败原因都记)。

接口: `show TYPE=disk`(容量与待执行请求)、`expand op=set size=<MiB> | op=cancel | op=pending | op=log`。

执行器第 1 次启动时做这些事:
1. 算新布局: `/etc/mnt` = `[114688, 114688 + 目标MiB×2048)`, 扩展分区与 `/etc/log` 整体顺延;
2. 把两个分区内容暂存到内存(`/tmp`), 请走正在用它们的进程, **真正卸载**它们
   (不卸载的话内核回写会把刚写进去的新内容盖掉 —— 这条踩过坑);
3. `mke2fs -d`(灌内容)`-U`(保持文件系统 UUID 不变)按新大小重建到镜像;
   先 `e2fsck -fn` 自检 + 核对 UUID, 不过就放弃;
4. `dd` 各自写到新偏移, 再**回读校验**;
5. `fdisk` 写新分区表并复核 → 重启。

只动属于框架自己的三处: `sda3`(/etc/mnt)、扩展区 `sda4`、扩展区里第一个逻辑分区 `sda5`(/etc/log)。
**其它逻辑分区(`sda6` 及以后, 比如绑了业务的数据盘)只在扩展区里按原起止重建, 一个字节都不挪** ——
它们会压缩 /etc/log 能用的上限, 所以界面上的"上限"要把它们算进去(见 §1.3 第 2 条)。

顺序上**先写分区表、再写文件系统镜像**: 表写不对就把事前备份的 MBR/EBR 扇区 `dd` 回去再重启,
此时盘上文件系统一个字节都没改, 回滚是干净的; 反过来先写镜像就没法回头。

安全线: 动盘之前任何一步失败都直接放弃(分区表还是旧的, 系统照常能起, 下次开机重试);
连续失败 3 次放弃并留日志。第 2 次启动只做收尾(清请求)并把日志并入 `expand.log`。

> **为什么框架开机先把自己拷到 `/tmp/.boot` 再执行**(见 `boot.sh`): bash 是边读边执行脚本的,
> 扩容要卸载 `/etc/mnt` —— 自己占着它既卸不掉(EBUSY)也读不下去。
>
> **代价**: 第 1 次启动要写 1G(mnt 镜像)+15G(log 镜像) ≈ 16G, VM 上约 100 秒。
> 之所以不"只写非零块": busybox 的 `dd`/`cp` 没有 `conv=sparse`/`--sparse`。

> 布局想改尺寸/顺序时, 直接改 `09_expand_mnt.sh` 里算 `ext_start/p5_start` 的那几行即可;
> 没有设备时用 §1.2 的离线步骤做等价操作。

### 1.4 把数据盘绑成"插件存储"(框架自加的绑定业务)

「系统设置 → 磁盘分区」的**绑定业务**下拉里, 框架额外加了第 6 项 **插件存储**
(固件原本只有 0不使用 / 1普通存储 / 2有余繁星 / 3缓存加速 / 4行为记录 / 5钉钉闪传)。
选中它保存后, 该分区会被格式化(ext4)并挂到固定路径:

```
/etc/disk/<UUID>        <- 分区实际挂载点(disk_mgmt 自己维护)
/etc/disk_sys/plugin    <- 业务 6 的落点(软链到上面)
```

于是插件/框架可以直接把大件数据放这块数据盘上, 不再受 43.4M 系统盘(/etc/mnt)限制。
绑定记录在 sqlite `disk_mount` 表(`mt_purpose=6`), 分区第 2 个扇区还写了 `6` 做标记。
**注意**: 绑了业务的分区会被扩容脚本当"保留分区"绕开(见上), 不会再被吃进 /etc/log。

**这个业务怎么用(谁在消费它)**: 框架自己的**插件存储**。开机时
`lib/plugin.sh:plugin_store_setup()`(在 `03_enable_plugins.sh` 里、`plugin_fw_patch` **之后**调用,
因为数据盘是那一步才挂起来的)会:

```
绑了数据盘  -> 把 <数据盘>/plugins bind 挂到 /etc/mnt/plugins
              插件本体落在数据盘上, 装多大都行; 所有既有路径(/etc/mnt/plugins/**)完全不变
没绑数据盘  -> 什么都不做, 插件照旧放系统盘 /etc/mnt
```

首次切换会把系统盘上已有的插件**拷**过去(不删源, 挂载失败也不丢), 幂等、失败安全。
「安全防护控制台 → 插件管理」页会显示当前落点: *插件存储: 数据盘(可用 x G)* 或 *系统盘*。
实测: sda6(6.9G) 绑成插件存储后 `/etc/mnt/plugins` 即 sda6, 四个插件迁过去, `ikplugin` 用法不变。

实现见 `lib/plugin.sh:plugin_fw_patch()` —— 业务枚举写死在固件三处, 而 `/usr/ikuai`
每次开机还原, 所以框架每次开机重打一遍:

1. `/usr/ikuai/script/disk_mgmt.sh`(`/usr/ikuai/function/disk_mgmt` 是它的软链):
   `__link_setting()` 加 `6)` 分支 → `/etc/disk_sys/plugin`; `partition_set()` 的
   "不需要起名"列表加 6(`2|3|4|5|6)`)
2. 磁盘分区页分包: 下拉加 `<option value="6">`、表格里的业务名数组加第 7 项
3. `/usr/ikuai/www/static/i18n/*.json`: 加 `binding_business_name6`

补丁后若已存在 `mt_purpose=6` 的绑定, 框架会再跑一次 `disk_mgmt.sh init` 把挂载和软链补上。
(实测: 绑定 sda6 = 6.9G 后, `/etc/disk_sys/plugin` 指向它, 重启后自动恢复。)

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
  grep -c '0.0.0.0' /etc/hosts;               # hosts 域名封锁条目(>0)
  cat /etc/log/ikguard/stub.log 2>/dev/null;  # 启动尝试监控(期望: 空/不存在)
  cat /etc/log/ikguard/report.txt;            # 体检结论(正常/异常)
"
```

（宿主机侧可一键跑完上面全部检查，见附录 B。）

### 4.1 验证清单

| 检查项 | 期望 |
| --- | --- |
| `/etc/plugins_ok` | `1` |
| `boot.log` 末尾 | `[backdoor] 完成`、`[plugin] Web 插件资源已同步` |
| 后门进程 | `cre/pmd/ik_rc_client/dtalkd/dtalkc` 均不存在 |
| 后门程序 | `/usr/sbin/ik_rc_client` 等被替换为空壳(含 `[ikblock] disabled` + stub.log 监控) |
| hosts 封锁 | `/etc/hosts` 有 `# [ikblock] begin` 段，云端域名指向 `0.0.0.0` |
| 启动监控 | `/etc/log/ikguard/stub.log` 不存在或为空(有任何记录 = 发现了新的启动点) |
| SSH 加固 | `sshguard check`：端口/`open_sshd` 取官方值；`sshguard=0` 时防火墙里没有 `IKG_*` 链；`=1` 时 `IKG_SSH_WAN` 含 `ifaces` + `ctstate NEW` |
| SSH 日志 | `sshguard log 5` 有输出（来自官方 `/etc/log/syslog.db` 的 `messages` 表，含失败尝试） |
| 审计日志 | 打开 `audit` 后 `/etc/log/ikguard/audit-<date>.log` 出现 `collect.begin` 等事件 |
| Web 接口 | `POST /Action/call {"func_name":"ikguard","action":"show","param":{"TYPE":"data"}}` 返回 `Result:30000` |
| Web 页面 | 系统设置 → 插件管理(`#/system-setting/plugin-management`)：**无"需要绑定爱快云平台"提示**，点开插件后标题显示"插件"而不是"Docker" |
| 前端补丁 | 分包里 `plugins/docker/` 已变成 `plugins/app/`、`yunbindstatus=2` |
| 使用条款 | 首次进入只有灰色按钮，同意后出现插件卡片；`/etc/mnt/plugins/.eula` 有 `accepted=1` |

---

## 5. 审计取证 = 被动采集(不用 cron)

`audit=1` 时运行常驻采集器 `ikaudit collect`，事件全由内核推送：

* `conntrack -E` → 连接事件(公网方向)；`dport=53` 的另存为 DNS 事件
  (conntrack 不含报文，所以 DNS **没有域名**，只有"谁向谁查")

封锁不走 iptables(域名封锁在 /etc/hosts)，所以没有"封锁命中"事件源；
**组件启动尝试的监控由空壳自己完成** -> `stub.log`(见 §5.1)，同样零轮询。

日志目录 `/etc/log/ikguard/`（持久分区；保留 3 天 + 目录总量 300MB、单文件 10MB 封顶，
采集器每 60 秒（或事件间隙）自动维护）：

| 文件 | 内容 |
| --- | --- |
| `boot.log` | 框架开机日志(所有脚本的 log 输出) |
| `audit-YYYYMMDD.log` | 结构化事件: `collect.begin/stop` 等 |
| `conn-YYYYMMDD.log` | 连接事件(`[NEW]`/`[DESTROY]`) |
| `dns-YYYYMMDD.log` | DNS 事件(`dport=53`) |
| `stub.log` | **启动尝试监控**: 空壳/被禁脚本记录"谁想启动我"(时间 + 拉起者 cmdline) |
| `report.txt` | 最近一次采集报告 |

> 设计上**明确移除**的三件事：①不做"程序启动"轮询判断 —— 本内核
> `CONFIG_CONNECTOR`/`CONFIG_AUDIT`/`CONFIG_KPROBES`/`CONFIG_FTRACE` 都没编，没有 exec/fork 事件源；
> ②不抓包 —— 抓包既费磁盘又和"被动"无关；③不记"封锁命中" —— 封锁只走 hosts+空壳，没有 DROP 规则。
> 启动尝试监控改由空壳承担：只有真的发生启动时才写一行，平时零代价。
> 规模阈值可用环境变量覆盖: `AU_KEEP_DAYS` / `AU_MAX_TOTAL` / `AU_MAX_FILE`。

常用命令:

```bash
/etc/mnt/.boot/bin/ikaudit status          # 采集器/事件源/日志/启动监控状态
/etc/mnt/.boot/bin/ikaudit tail 80         # 看审计事件
/etc/mnt/.boot/bin/ikaudit collect-status  # 采集器是否在运行
/etc/mnt/.boot/bin/ikaudit collect-start   # 命令行手动启动采集器(页面只提供 audit 开关)
/etc/mnt/.boot/bin/ikaudit collect-stop    # 停止采集器(按 pid 关闭并清残留)
/etc/mnt/.boot/bin/ikaudit report          # 立刻生成报告(异常返回码 1)
```

### 5.1 域名封锁(/etc/hosts) 与 启动监控

**封锁 = 域名封锁，不做 IP/网段封锁，不碰 ipset/iptables**（v0.0.6 起）：

* 云端域名(25 个 + 可选 `/etc/mnt/ikblock.domains` 扩展)写进 `/etc/hosts.d/ikblock` 片段，
  再按固件自己的方式 `cat /etc/hosts.d/* >/etc/hosts` 汇总成 `/etc/hosts` 指向 `0.0.0.0`；
* 只影响**本机自己**的域名解析，局域网客户端的 DNS 查询不经过本机 hosts，不受影响；
* 零进程、零防火墙规则、每开机重写一次(`/etc/hosts.d` 随根分区还原)。
* **为什么必须写成片段**：固件有三处会整体重建 `/etc/hosts` —— `basic.sh:__set_hostname()`
  (开机必经, rc 里排在 plugins.sh 之后)、`function/basic`(网页改主机名)、`pppoe_server.sh`
  (NAS 名变更)，实现都是 `cat /etc/hosts.d/* >/etc/hosts`。往 `/etc/hosts` 直接追加的条目会被
  它们冲掉(真机首测就是这么丢的封锁)；写成片段与固件同源，任何一次重建都会带上。

历史包袱：旧版曾用 `bd_resolve_domains()` 每 10 分钟把域名解析结果灌进 ipset —— 每域名
一次 `nslookup`(单次 2.5~5.1s)，24 个域名一轮 60~120s，长于 60s 的 cron 周期，叠加节流
竞态后 2~6 个守卫并发，把 2 vCPU 设备打出 27%~65% 的 CPU 尖峰。已连同 ipset/iptables
网络层整体删除。

**启动监控(零代价)**：被禁的 5 个客户端被换成空壳、6 个启动脚本被禁用 —— 它们一旦被
任何代码路径启动，都会先往 `/etc/log/ikguard/stub.log` 写一行
`[时间] [ikblock] <组件> 被启动(已拦截) ppid=<pid>` + 拉起者的 cmdline，然后立即退出。
文件为空 = 没有任何启动尝试；有记录 = 发现了文件层没覆盖的新启动点（记录里就是拉起者）。

两个真机上确认过的实现细节：

* **开机竞态不算启动尝试**：rc 的 `start_remote_services()` / `start_ikuai_services()` 函数体、
  `boot()` 里的启动行，在我们打补丁之前就已被 bash 解析进内存（补丁走的是 `boot()` 中段的
  `plugins.sh` 钩子，`sed` 改的是磁盘副本），所以每次开机 rc 仍会按内存旧副本把
  `ik_rc_client` / `cre` / `pmd` 和 `utils/update_hosts.sh` 拉起一遍（已被空壳/被禁脚本拦下，
  strace 抓到过这些 `execve`）。判定分三级：① `bd_apply` 补丁时沿祖先链认出本次开机 rc 的
  pid 记进 `/tmp/.ikblock.rc.pid`，拉起者 pid 对上直接放行（rc 常在空壳读到它之前就已退出）；
  ② 拉起者是 rc 后台子 shell 时，靠它的 cmdline（就是 rc 的命令行）或顺它自己的
  `/proc/<pid>/stat` 向上找到 rc（起床第一件事用内建 `read` 抓 stat，fork 出 `tr` 再读就晚了）；
  ③ 前两级都判不出来才记一笔，第二行写明 `(拉起者已退出, 无法归属)`，不伪造拉起者。
* **被禁脚本是被 `source` 起来的**：`/etc/ikcommon` 的收尾是 `. $1 ""; Command $S0`，
  所以脚本里 `$0` 是 `/etc/ikcommon` 而非脚本名 —— 组件名在生成时就写死字面量；
  另外生成片段绝不能走 `awk -v`（它会把 `printf` 格式串里的 `\n` 变成真换行、写出语法错误
  的脚本，连启动尝试都记不下来，真机踩过），测试里对生成物有 `bash -n` 断言。

### 5.2 怎么验证封锁生效

封锁 = 空壳 + 启动点改写 + hosts 域名封锁，验证也围绕这三件事(无需外网)：

```bash
ssh sshd@127.0.0.1 -p 10022 "
  grep -c '0.0.0.0' /etc/hosts;                       # 期望: >= 24(云端域名全在)
  ls -l /etc/hosts.d/ikblock;                         # 期望: 片段在
  cat /etc/hosts.d/* > /etc/hosts;                    # 模拟 basic.sh 重建 hosts
  grep -c '0.0.0.0' /etc/hosts;                       # 期望: 重建后仍 >= 24
  grep -c 'ikblock' /usr/sbin/ik_rc_client /usr/sbin/cre /usr/sbin/pmd /usr/sbin/dtalkd /usr/sbin/dtalkc;
                                                      # 期望: 每个都是 1(空壳)
  ps | grep -E 'cre|pmd|ik_rc_client|dtalk';          # 期望: 空
  cat /etc/log/ikguard/stub.log 2>/dev/null;          # 期望: 空(没有任何启动尝试)
  bash -n /usr/ikuai/script/utils/update_hosts.sh;    # 期望: 无输出(生成的拦截脚本语法正确)
  grep ikaudit_update /usr/ikuai/script/utils/monitor_process.sh;  # 期望: 已注释
"
```

也可以在 Web 页"工具 → 封锁自检"一键跑同样四项(即时出结果)。
本机解析验证: `nslookup www.ikuai8.com 127.0.0.1` 走 iKuai 自带 DNS 不受 hosts 影响，
属正常；本机程序用 getaddrinfo 解析才会命中 hosts 的 `0.0.0.0`。

配置完 WAN 的 iKuai 正规做法是「网络设置 → 内外网设置 → wan1 → 绑定网卡 eth1 → 动态 IP(DHCP)」，
用官方接口一次配好并持久化的做法见 [§9](#9-让虚拟机真的连上外网--真实-lan-客户端模拟)。

### 5.3 历史沿革：为什么从"cron 轮询"改成"被动采集"

早期版本用 `* * * * * ikaudit watch` 每分钟轮询(/proc 进程快照、conntrack 快照 diff、
iptables 计数器 diff、tcpdump 抓包)，踩过这些坑：

| 现象 | 原因 |
| --- | --- |
| 审计日志只有开机那一次的数据 | 任务只写进了 `/etc/crontabs/cron.d/`，而 iKuai 的 `crond` 只读 `/etc/crontabs/root` |
| `dns.cloud` 事件每分钟重刷一整天 | 每次 tick 都全文 `grep` 当天 DNS 日志(后来改用偏移量增量扫描) |
| 体检报告计数恒为 0 | 统计表达式写成 `grep -c "cloud\."`，而事件名里点号在 `cloud` 前面 |
| DNS 抓包被 cron 每分钟重新拉起 | `au_watch()` 末尾无条件 `au_dns_start`，用户点"停止"最多活 1 分钟 |
| `proc-*.log` 体积大、全是自身噪声 | 快照把框架自己的 `sed/awk/ikaudit` 子进程也记了进去 |

**v0.0.4 起改为被动采集**：常驻一个采集器订阅 `conntrack -E`，`audit` 默认关闭、
开启后不写任何 cron；程序启动判断与 tcpdump 抓包整体移除。
**v0.0.6 起**：后门守卫的每分钟 cron 与域名解析整体删除(§5.1，CPU 尖峰根因)、
内核 LOG 封锁命中事件源随 iptables 网络层一并删除、`probe` 定时自检移除 ——
**现在框架不写任何 cron，一条都不需要**。历史数据仅作参考。

```
$ grep -nE 'ikaudit|backdoor_guard' /etc/crontabs/root
# (空) 框架不写任何 cron: 守卫只在开机做一次, 采集是常驻进程, 启动监控在空壳里
```

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
  `show`(TYPE=`data/flags/plugins/pending/eula/logs/check`) / `seting` / `eula` /
  `apply` / `plugin` / `check` / `logclear`
* 页面功能:
  * **概览**: 框架版本、签名校验、后门进程、hosts 封锁条数、启动尝试次数、采集状态、日志占用
  * **开关配置**: `backdoor` `audit` `sshd` `plugins` `cron` `shell`
    修改即写入 `/etc/mnt/boot_args` 并立刻重跑对应脚本
  * **插件管理**: **上传 zip 安装**、扫描 `/etc/mnt/plugins/*.zip`、列出/卸载插件
  * **审计日志**: 实时查看 report/audit/conn/dns/stub/boot 日志
  * **工具**: 封锁自检(即时: 空壳/hosts/进程/stub.log 四项) —— 采集器不在此启停, 只由 `审计取证` 开关控制

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

### 6.7 插件示例: 纯 shell 的 `bnfix`(给系统共享库打定点补丁)

第二个示例 `examples/bnfix-plugin/` 演示的是**另一种形态的插件**：不编译、不带任何二进制，
只用一个 shell 脚本 + 一行"补丁描述"去修设备上已有的组件。适合"厂商组件有缺陷、又拿不到源码"
这类场景（本例是给 `/usr/lib/libcrypto.so.1.0.0` 打 1 个字节的定点补丁）。

```
examples/bnfix-plugin/
├── build.sh             组装 pkg/ + 打 dist/bnfix.zip(约 15KB，不做任何编译)
└── pkg/                 Release / install.sh / boot.sh / uninstall.sh /
                         bin/bnfix / share/bnfix.conf / share/selfcheck.der /
                         function/bnfix / www/plugins/...
```

它演示的关键点(详细说明见 `examples/bnfix-plugin/README.md`):

1. **"根分区每次重启还原"正是可用的机制**：补丁打在根分区上，本来重启就没了；
   于是 `boot.sh` 每次开机重新打一遍 —— 这同时天然满足
   "卸载后重启即彻底失效"（插件没了，就没人再打补丁了）。
2. **就地改写已有字节**：设备根分区 `/dev/root` 只有 111MB 且已 100% 占满（`Avail=0`），
   所以不能往 `/usr/lib` 放新文件；用 `dd conv=notrunc` 覆盖 1 个字节不需要任何新增空间。
3. **安全护栏**：`share/bnfix.conf` 里写死目标库的原始 md5、补丁后 md5 与 `offset/字节`；
   只有 md5 命中才动手，打完再核对补丁后 md5，不一致立刻写回。固件换了就拒绝执行，不会乱改。
4. **自检**：`bnfix verify --full` 会先还原回原始字节、跑一次自检样本（确认会触发原缺陷），
   再打上补丁跑一次（确认已修复），最后给出 `pass`；`bnfix status` 输出 JSON 供前端展示。
5. **`LD_PRELOAD` 走不通的坑**（本示例记录在案）：目标库带 `DT_SYMBOLIC` 且整库无 `JUMP_SLOT`
   重定位，库内部调用在链接期就被绑成相对调用，不经过 PLT，因此 `LD_PRELOAD` 同名符号无效
   （`/proc/<pid>/maps` 里能看到 shim，但永远不会被调用）。另外 uClibc-ng 1.0.40 的加载器
   **不支持 `/etc/ld.so.preload`**（只认 `LD_PRELOAD` 环境变量）。

实测(在设备上安装后):

```
$ ikplugin install /tmp/bnfix.zip
补丁已生效 -> md5=9c79a8b10fb888035ba77910ffd27e65

$ /usr/sbin/bnfix status
{"enabled":"1","mode":"patch","lib":"/usr/lib/libcrypto.so.1.0.0","lib_state":"patched","fixed":true,...}

$ /usr/ikuai/function/bnfix show TYPE=data
{"status":{"enabled":"1","fixed":true,...}}

# 重启后 boot.sh 自动重新施加:
$ grep boot /etc/log/ikguard/bnfix.log | tail -1
...[boot] 补丁时刻 uptime=14.38

# 卸载 + 再重启: 库回到原始 md5, 缺陷复现
```

---

## 7. 开关(`/etc/mnt/boot_args`)

| 键 | 默认 | 作用 |
| --- | --- | --- |
| `sshd` | 1 | 控制台账号 shell 换成 bash，可 SSH 登录 |
| `backdoor` | 1 | 后门/更新通道阻断(空壳+改写启动点+hosts 封域名；不碰防火墙、不装定时器) |
| `plugins` | 1 | 插件系统(含 Web 插件资源同步；首次使用需同意《使用条款》) |
| `cron` | 1 | 铺开 `/etc/mnt/cron.d` |
| `shell` | 1 | 链接 `/etc/mnt/shells` 下的程序/配置 |
| `audit` | 0 | 审计取证=**常驻被动采集器**(conntrack 连接事件)；=0 时停掉采集器并清理遗留定时任务 |
| `sshguard` | 0 | SSH 加固：封禁 WAN 侧来的**新 SSH 连接**(官方 `ifaces` 判公网网卡、官方 `sshd_port`)；=0 时撤销规则。开启后只剩 LAN 侧能连 SSH，**别把自己锁在门外**(Web 不受影响，可随时关) |

> 采集**不占 cron**：`audit=1` 开机自动拉起采集器、`=0` 停止；DNS 不单独抓包，只是连接事件里 `dport=53` 的子集。
> 框架自身不写任何定时任务。

**已废弃并会自动清理的键**(升级时 install.sh 会 `sed -i` 删除):

| 键 | 原意 | 现状 |
| --- | --- | --- |
| `remote` | iKuai 云"远程控制/远程维护"开关 | 历史遗留的空开关：**没有任何脚本读取它**。真正的云端远程控制已由后门阻断层覆盖 —— `ik_rc_client`/`cre`/`pmd` 被换成空壳、`monitor_process.sh` 不再守护、云端域名被 hosts 指向 0.0.0.0。所以"默认关闭"= 该通道本来就不可用 |
| `plugins_verify` | 插件包强制签名校验 | 已去掉：插件包不再要求签名(带 `MANIFEST.MF` 只校验摘要，带签名+公钥才额外验签) |
| `backdoor_hosts` | 单独的 hosts 域名封锁开关 | v0.0.6 起域名封锁是后门阻断的组成部分，不再单独开关 |
| `probe` | 云端连通性定时自检 | v0.0.6 起随 iptables 网络层一并移除(DNS+TCP 探测对 hosts 封锁无意义)；自检改由 Web 页"封锁自检"即时执行 |

命令行修改(等价于 Web 页面开关)：

```bash
sed -i 's/^backdoor=.*/backdoor=0/' /etc/mnt/boot_args     # 关闭
/etc/mnt/.boot/scripts/02_disable_backdoor.sh              # 立即生效
```

---

## 7b. SSH 加固(封禁公网访问 + 一键封禁来源 IP)

真机 3.7.16 核实: SSH 是自带的 **dropbear**(官方 `remote_control.sh __set_sshd` 拉起, 监听
`0.0.0.0`), **官方没有做任何 WAN 侧限制** —— 22 不在 iKuai 的 `DROP_T_PORTS_WAN_IN`
(只有 53 54 680~690 700 1900)、`WEBACL` 只管 web 端口。所以 `open_sshd=1` 且上游做了映射时,
公网可直接连上来爆破。本框架补的是官方缺的那条链。

```bash
sshguard status                       # 状态: 端口/open_sshd/公网封禁/名单
sshguard on                           # 封禁 WAN 侧新 SSH 连接(等同 sshguard=1)
sshguard off                          # 解除
sshguard log 30                       # SSH 日志(登录成功/失败/注销; 读官方 /etc/log/syslog.db)
sshguard ban 203.0.113.9 SSH爆破        # 一键封禁(只挡它访问 SSH 端口)
sshguard unban 203.0.113.9 / sshguard clear
```

* 公网网卡用官方定义判定(`/usr/ikuai/include/iptables.sh` 的 `IPT_WAN_NO_VPN_IFACE_IN`,
  即 `-m ifaces --ifaces wan*,vwan*,adsl* --dir in`)；SSH 端口读官方
  `config.db:remote_control.sshd_port`, 都不写死。
* 规则带 `--ctstate NEW`: 只拦新连接 —— iKuai 的 INPUT 是"默认 ACCEPT + 靶向 DROP",
  没有 ESTABLISHED 放行, 不限 NEW 会把自己正在用的 SSH 会话一起打断(实测: 生效后当前会话
  仍可用)。
* 来源封禁只挡**该 IP 访问 SSH 端口**, Web 与其它的不受影响; 名单在
  `/etc/mnt/ikguard/ssh-ban.list`(持久), 开机 `scripts/07` 重放; 名单清空后链一起拆掉。

**救援(实测过一遍)**: 公网 SSH 被封后 Web 照常可用 —— 登录后

```bash
# passwd 必须是 md5(明文密码), 明文会返回"账号或密码错误"
curl -c /tmp/c -X POST http://<设备>/Action/login -H 'Content-Type: application/json' \
     -d '{"username":"admin","passwd":"<md5>","pass":"","remember_password":""}'
curl -b /tmp/c -X POST http://<设备>/Action/call -H 'Content-Type: application/json' \
     -d '{"func_name":"ikguard","action":"seting","param":{"key":"sshguard","value":"0"}}'
```

**判据坑(踩过)**: 在 QEMU user-net 下 `hostfwd` 是 **QEMU 先 accept 再往客户机连** —— 裸
socket `connect()` 成功**不代表**客户机可达(哪怕被 DROP 也返回 0.0s 成功)。判断"封禁是否生效"
必须看**能否完成 SSH 握手**(如 `ikctl.py sh` / paramiko 读 banner), 或看内核里的包计数。

## 8. 回滚与排障

* **框架没生效**: 先看 `/etc/plugins_ok`(不存在 = 验签或执行失败)，再手工确认签名：
  `openssl dgst -sha256 -verify <公钥> -signature /etc/mnt/.boot/SIGNATURE.RSA /etc/mnt/.boot/MANIFEST.MF`
* **签名不匹配**: 说明改动过的文件没有重新签名 → 回滚该文件或重新 `sign.sh` + `build.sh` 再升级。
* **回滚到上一版**: 升级前的 `.boot` 会被整目录覆盖，可提前 `tar czf /etc/log/ikguard/boot-$(date +%F).tgz -C /etc/mnt .boot` 备份，回滚即解回该目录并重启。
* **需要紧急停用**: `sed -i 's/^backdoor=.*/backdoor=0/' /etc/mnt/boot_args` 后把
  `/etc/hosts` 里 `# [ikblock]` 段删掉、把空壳文件还原(或删除 `/etc/mnt/.boot` 目录后重启，
  根分区还原即回到固件原状)。

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

> 下面的输出是 v0.0.5(iptables/ipset 网络层)时代的实测记录，仅作历史参考；
> v0.0.6 起封锁改为 hosts + 空壳，验证方式见 §5.2。

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
python3 ikctl.py verify                             # 一键体检(28 项)
python3 ikctl.py audit --tail 60                    # 看报告/审计/DNS/连接日志
```

`verify` 依次检查: 签名校验 → `plugins_ok` → `boot.log` 各阶段 → 后门进程/程序 →
ipset/iptables → 审计日志与体检结论 → DNS 抓包 → Web 插件资源/接口，最后给出
`通过 N/28` 汇总。实测重启后为 28/28 通过。

## 附录 C. 一条命令更新+重启(ikupd.py)

只要 **地址 / 账号 / 密码** 就能升级插件包并重启(全程走设备自带接口, 不依赖 ssh 里的文件操作):

```bash
# 更新基础包并自动重启、等它回来
python3 ikupd.py -a 192.168.9.1 -u admin -p '<控制台密码>' \
        update ikuai-plugins-v0.0.4-base.bin --reboot --wait

python3 ikupd.py -a 192.168.9.1 -u admin -p '<控制台密码>' update <包>   # 只更新
python3 ikupd.py -a 192.168.9.1 -u admin -p '<控制台密码>' reboot --wait  # 只重启
python3 ikupd.py -a 192.168.9.1 -u admin -p '<控制台密码>' status        # 看挂载状态
```

动作链: `POST /Action/login` → `POST /Action/upload`(字段名=文件名) →
`/Action/call {func_name:upgrade, action:parse_file}` → `{action:update_file}` → SSH `reboot`。
`status` 会打印 `/etc/plugins_ok`、`/etc/mnt/.boot/Release` 里的版本、`boot_args`、
`sshd` 账号 shell 以及 `ikguard` 是否挂载。
