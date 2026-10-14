# bnfix - OpenSSL CVE-2022-0778 修复插件

给 iKuai 设备自带的 **OpenSSL 1.0.2u / `libcrypto.so.1.0.0`** 打一个 **1 字节定点补丁**，
修掉 `BN_mod_sqrt()` 的无限循环（CVE-2022-0778）。插件在**每次开机自动重新施加**补丁
（根分区每次重启都会从固件镜像还原），因此：

| 操作 | 结果 |
| --- | --- |
| 装插件并启用 | `/usr/lib/libcrypto.so.1.0.0` 立刻变成补丁版 |
| **重启设备** | 仍然生效（`boot.sh` 重新打补丁；服务在补丁之后才 exec，因此用的是已修复的库） |
| 卸载插件 | 立刻还原；**再重启一次，修复彻底失效**（没有任何东西会再打补丁） |

本目录的实测记录见文末「实机验证」。

---

## 1. 漏洞在设备上的实际形态

`openssl x509`（或任何解析证书的路径）遇到**显式曲线参数 + 压缩点**的证书时会**永远自旋**：

```sh
# PoC: certs/cert.der.new @ https://github.com/drago-96/CVE-2022-0778
openssl x509 -in poc.der -inform DER -text -noout &
sleep 6; kill -0 $! && echo HANG      # 6 秒后仍存活, 且 /proc/<pid>/stat 的 utime+stime 持续增长
```

设备上加载这份 libcrypto 的进程（实测）：`openresty`(nginx master+worker)、`ikdnsd`、`ikluajit`，
另外 `openvpn` / `ik_http_lua` 也链它。单次触发就能把一个核打满。

## 2. 为什么**不能**用 LD_PRELOAD 一个 shim（已验证，所以没采用）

最直觉的做法是写个 `libbnfix.so` 导出 `BN_mod_sqrt`，用 `LD_PRELOAD` 拦下来。**在本设备上这条路走不通**
（这是开发过程中实测过的结论，验证用的 shim 与 `diag` 命令都已删除，不随插件分发）：

```
不挂 shim : hang        # 原库本来就会挂死
挂上 shim : hang        # 挂上之后照样挂死 —— 说明我们导出的函数根本没被调用
```

根因（对拉下来的库做静态分析）：

```
$ readelf -dW libcrypto.so.1.0.0 | grep SYMBOLIC
 0x0000000000000010 (SYMBOLIC)  0x0                       # <- DT_SYMBOLIC 存在

$ readelf -rW --use-dynamic libcrypto.so.1.0.0 | awk '{print $3}' | sort | uniq -c
      5 R_X86_64_64
    101 R_X86_64_GLOB_DAT
   5956 R_X86_64_RELATIVE                                  # <- 没有任何 JUMP_SLOT
```

`DT_SYMBOLIC` + 零 `JUMP_SLOT` 意味着：**库内部对 `BN_mod_sqrt` 的调用在链接期就被绑定成了直接相对调用**，
根本不经过 PLT/GOT，而 `ossl_ec_GFp_simple_set_compressed_coordinates()` 调 `BN_mod_sqrt` 正是在库内部。
LD_PRELOAD 只能影响"从其它目标引用过来的符号"，对库内自顾自的调用无能为力
（`/proc/<pid>/maps` 里能看到 shim，但它永远不会被执行）。

> 顺带一个坑：uClibc-ng 1.0.40 的加载器**不支持 `/etc/ld.so.preload`**（字符串表里根本没有它，只认
> `LD_PRELOAD` 环境变量），所以"写 preload 文件"这条备选路也不存在。

## 3. 为什么也不是"换一份修好的整库"

设备根分区 `/dev/root` 只有 **111MB 且已经 100% 占满**（`Avail = 0`），塞不进另一份 2MB 的库：

```
$ df -h /usr/lib
Filesystem   Size  Used Avail Use% Mounted on
/dev/root   111.0M 108.6M    0 100% /
```

（插件也支持 `bnfix submit <file>` 把整库放到持久分区再 `mount --bind` 覆盖，但默认不需要走这条。）

## 4. 修复：`BN_mod_sqrt` 里的 1 字节补丁

### 4.1 定位

```sh
nm -D --defined-only libcrypto.so.1.0.0 | grep BN_mod_sqrt
# 00000000000acc4b T BN_mod_sqrt        (该 R E 段的文件偏移 == 虚拟地址)
```

把 `0xacc4b` 起 0x746 字节抠出来反汇编，Tonelli-Shanks 的内层循环长这样（AT&T 语法）：

```
ad212:  movl   $0x1,0x8(%rsp)      ; i = 1
ad21a:  cmpl   $0x1,0x8(%r14)      ; BN_is_one(t) ?
ad21f:  je     0xad24d
ad221:  incl   0x8(%rsp)           ; i++
ad225:  cmp    0x8(%rsp),%ebx      ; 比较 e 与 i
ad229:  je     0xad31c             ; 0f 84 ed 00 00 00   <== 就是这里: (e == i) -> 报错退出
ad22f:  ...  call BN_mod_mul(t,t,t,p,ctx)
ad246:  jne    0xad21a             ; while (!BN_is_one(t))
...
ad31c:  ... ERR_put_error(BN_R_NOT_A_SQUARE) ...
```

对比上游源码就能看懂问题：

```c
i = 1;
if (!BN_mod_sqr(t, b, p, ctx)) goto end;
while (!BN_is_one(t)) {
    i++;
    if (i == e) { BNerr(BN_R_NOT_A_SQUARE); goto end; }   /* <-- 只在 i 恰好等于 e 时退出 */
    if (!BN_mod_mul(t, t, t, p, ctx)) goto end;
}
```

外循环会把 `e` 重写成当前的 `i`。当第一轮结束时 `i == 1`，于是 `e = 1`；第二轮里 `i++` 之后
`i` 从 2 开始递增，`i == 1` **永远为假** → 无限自旋。上游的修复（commit `9eafb53614bf...`）
就是给这个循环加了上界。

### 4.2 补丁

把 `je`（`0F 84`，等于就退出）改成 **`jle`（`0F 8E`，`e <= i` 就退出）**，即只改文件偏移 `0xad22a` 一个字节：

```
偏移 0xad22a : 0x84 (je)  ->  0x8e (jle)
文件 md5      : 0b65982b3ec6f87fccb2993b3407decf  ->  9c79a8b10fb888035ba77910ffd27e65
```

为什么 `jle` 就是正解：

* 合法输入下恒有 `i <= e`（只有 `i == e` 才会走到"非平方剩余"分支），所以 `e <= i` 与 `e == i` **语义完全一致**；
* 而在被攻击者利用的那个状态（`e == 1`、`i ≥ 2`）下，`e <= i` 立刻成立 → 直接走错误分支返回，
  等价于上游修复后的行为（拒绝这个点，返回 `NULL`），不再自旋。

实测里这 1 个字节的效果非常干净：补丁前 6 秒后仍存活且 CPU 持续增长，补丁后毫秒级返回。

### 4.3 一个容易踩的坑

第一次我改成了 `jge`（`0F 8D`）。注意 AT&T 的 `cmp 0x8(%rsp),%ebx` 是算 `ebx - mem`，
所以 `jge` 是 `e >= i` —— 方向正好相反，**补丁无效**（现象不变，还是挂死）。
`jle` 才是 `e <= i`。定位到字节之后一定要在设备上实测，别只看反汇编。

## 5. 插件结构

```
examples/bnfix-plugin/
├── build.sh                        组装 pkg/ + 打 dist/bnfix.zip(约 20KB)
│                                   --base <原库> 时会额外生成打好补丁的整库(供 submit)
└── pkg/                            (= 会被 zip 的内容)
    ├── Release                     plugin=bnfix / version=1.0.0
    ├── install.sh                  安装: apply + 尽力重启服务
    ├── boot.sh                     每次开机: 重新 apply(根分区还原后) + 记录补丁时刻
    ├── uninstall.sh                卸载: revert + 清链接
    ├── bin/bnfix                   CLI: status/apply/revert/verify/submit/unsubmit/restart/log
    ├── share/bnfix.conf            补丁描述: 目标库 / 两个 md5 / offset+字节
    ├── share/selfcheck.der         自检用证书样本(492 字节)
    ├── function/bnfix              后端接口(show/seting/verify/verifyfull/restart)
    └── www/plugins/...             插件卡片 + 页面 + 图标
```

> 没有 `.so`：本插件不需要任何共享库 —— 修复就是"就地改 1 个字节"，
> 自检/撤销都只用 `dd` 与 `md5sum`，设备上现成的工具就够。

安全设计：

* **md5 白名单**：只有当 `libcrypto.so.1.0.0` 的 md5 恰好等于已知原始值（`0b65982b...`）时才打补丁；
  打完再核对是否等于预期的补丁后 md5，不一致就自动写回原字节。固件换了、库不一样 → 拒绝执行，不会乱改。
* **幂等**：已经是补丁态就直接返回；`boot.sh` 每次开机跑一遍不会叠加。
* **可逆**：`revert` 把原字节写回，不需要任何备份文件（不占空间）。
* **不写根分区新文件**：全程只有 1 次 `dd conv=notrunc` 覆盖已有字节，根分区 0 可用空间也能用。

## 6. 用法

```sh
# 装(二选一)
#   网页: 系统设置 -> 插件管理 -> ikguard -> 插件管理 -> 选择 bnfix.zip -> 上传并安装
ikplugin install /root/bnfix.zip

# 启用/撤销(默认安装即启用)
bnfix status            # JSON: enabled/mode/lib_state/md5/fixed/users
bnfix apply             # 打补丁
bnfix revert            # 还原本字节
bnfix verify            # 快速自检: 用自检证书实际跑一遍, 看当前库的表现
bnfix verify --full     # 完整自检: 先还原看原始表现, 再补上确认已修复
bnfix restart           # 重启受影响的服务(nginx/ikdnsd)
bnfix submit <libcrypto.so.1.0.0>   # 提交整库, 用 bind-mount 覆盖(可选路线)
bnfix log 20            # 看记录
```

`/etc/log/ikguard/bnfix.log` 是插件的记录（安装/开机/补丁/自检/还原都在里面）。

## 7. 实机验证（本仓库实测）

```
# 1) 安装 → 立刻生效
$ ikplugin install /tmp/bnfix.zip
补丁已生效 -> md5=9c79a8b10fb888035ba77910ffd27e65
$ md5sum /usr/lib/libcrypto.so.1.0.0
9c79a8b10fb888035ba77910ffd27e65

# 2) 完整自检：先还原看原始表现(会挂死)，再补上确认已修复
$ bnfix verify --full
{"lib_state":"patched","baseline":"hang","with_fix":"ok:rc=0","pass":true}

# 3) 重启设备 → boot.sh 自动重新打补丁
$ cat /etc/plugins_ok
1
$ grep boot /etc/log/ikguard/bnfix.log | tail -2
...[boot] 补丁时刻 uptime=12.05
...[boot] 状态: {"enabled":"1",...,"fixed":true,...}
$ md5sum /usr/lib/libcrypto.so.1.0.0
9c79a8b10fb888035ba77910ffd27e65
#   关键: 服务是在补丁之后才 exec 的，所以真的用上了修复后的库
  openresty pid=7738 启动于 uptime=13.5s   -> 晚于补丁(12.05s)
  ikluajit  pid=7847 启动于 uptime=15.6s   -> 晚于补丁
  ikdnsx    pid=9660 启动于 uptime=49.4s   -> 晚于补丁
$ bnfix verify
{"lib_state":"patched","with_fix":"ok:rc=0","pass":true}

# 4) 卸载 → 立刻还原；再重启 → 彻底失效
$ ikplugin remove bnfix
$ md5sum /usr/lib/libcrypto.so.1.0.0
0b65982b3ec6f87fccb2993b3407decf        # 已还原
# 重启后:
$ md5sum /usr/lib/libcrypto.so.1.0.0
0b65982b3ec6f87fccb2993b3407decf        # 没有任何东西再打补丁
$ openssl x509 -in poc.der -inform DER -text -noout &   # 漏洞复现
=> HANG, README 记录 600 CPU ticks
```

回归项（都通过）：正常证书解析、`openssl ecparam -conv_form compressed` 生成 EC 密钥/自签证书、
用设备自身 TLS 栈对 `127.0.0.1:443` 做握手（`ECDHE-RSA-AES256-GCM-SHA384`）。

## 8. 局限与风险

1. **只针对 CVE-2022-0778 这一个循环**。这份 libcrypto 里还有一批 2019 年之后披露的 CVE
   （见 `docs/SECURITY_AUDIT_20261014.md`），本插件不覆盖。彻底解决要靠厂商出新固件。
2. **固件升级后要重新确认**。`share/bnfix.conf` 里写死了原库 md5 与偏移；新版固件的 libcrypto
   一旦变化，插件会拒绝打补丁（安全失败），需要重新定位那一个字节再更新 `bnfix.conf`。
3. **改的是厂商二进制的一个字节**。虽然语义等价性有论证、且有"补丁前后 md5 + 回归测试"兜底，
   仍属于"无源码条件下的不得已手段"；能拿到修复固件时应优先用官方修复。
4. 已经在运行的进程不会自动换库（Linux 语义），`bnfix restart` 只能重启 nginx/ikdnsd；
   `ikluajit` 之类建议直接重启设备。
5. `bnfix submit` 的 bind-mount 路线会覆盖的是"整个库文件"，本设备上默认不用（根分区满 +
   不需要）。它的用途是把一份**自己编译的修好版本**（`build.sh --base`）挂上去。
