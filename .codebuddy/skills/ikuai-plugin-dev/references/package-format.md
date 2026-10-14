# 插件包格式

实现依据：`lib/plugin.sh`(`plugin_install` / `plugin_verify` / `plugin_link` / `plugin_web_link` / `plugin_run`)。

## 目录布局(设备上)

```
/etc/mnt/plugins/                  插件根目录(持久盘, 重启不丢)
/etc/mnt/plugins/*.zip             待安装包(开机会自动安装, 装完归档到 .installed/)
/etc/mnt/plugins/<name>/           已安装插件本体
/etc/mnt/plugins/<name>/data/      插件私有持久数据(**升级时被保留**, 见下)
/etc/mnt/plugins/.state/<name>     安装状态(名称/版本/时间)
/etc/mnt/plugins/.installed/       已安装 zip 归档
/etc/mnt/.boot/plugin.pub          插件校验公钥(可选)
```

## zip 内容

| 条目 | 必需 | 说明 |
| --- | --- | --- |
| `Release` | 必需 | 文本，`key=value` 一行一条：`plugin=<名称>`、`version=<版本>`、可选 `comment=` |
| `install.sh` | 必需 | 安装动作执行；**必须幂等**；设备端会 `test -x`，所以 zip 里要有执行位 |
| `boot.sh` | 可选 | 仅开机执行；存在时**优先于** `install.sh`(两者只会执行一个) |
| `uninstall.sh` | 可选 | 卸载动作执行 |
| `bin/*` | 可选 | 所有文件软链到 `/usr/sbin/`，文件名去掉 `.sh` 后缀 |
| `etc/*` | 可选 | 按相对路径软链到 `/usr/local/etc/` |
| `www/plugins/<n>/<n>.json` | 可选 | 插件卡片元数据，`<n>` 必须等于文件名 |
| `www/plugins/app/<n>.html` | 可选 | 插件页面(iframe 加载) |
| `www/plugins/app/<n>.png` | 可选 | 卡片图标(建议 64×64) |
| `function/<func_name>` | 可选 | Web 后端接口；**文件名就是 `func_name`** |
| `MANIFEST.MF` / `SIGNATURE.RSA` | 可选 | 插件包**不强制签名**；带清单则逐文件校验 SHA-256 |

`Release` 里没有 `plugin=` 时会退化为 `name=`，再退化为**目录名**。

## 名称与安装路径

* 安装目录 = `/etc/mnt/plugins/<plugin 字段>`。
* 卡片名 = `www/plugins/<n>/` 的 `<n>`(必须与文件名一致，否则前端取不到图标/页面)。
* `function/<func_name>` 的 `func_name` 建议与插件名一致，便于排查。
* 同名再次安装 = **升级**：框架会先把已有的 `data/` 目录挪走、覆盖其余文件、再把 `data/` 放回，
  所以**数据库/状态放 `data/` 就能跨升级保留**。

## 执行环境变量

`plugin_run()` 执行脚本时注入：

```
PLUGIN_NAME     插件名(来自 Release)
PLUGIN_VERSION  版本
PLUGIN_DIR      插件安装目录绝对路径, 例 /etc/mnt/plugins/mytool
PLUGIN_ROOT     /etc/mnt/plugins
PLUGIN_ACTION   install | boot | uninstall
IK_SYSROOT      测试用系统根前缀(设备上为空)
```

脚本里推荐写 `ROOT="${PLUGIN_DIR:-/etc/mnt/plugins/<名>}"`，这样本地手动跑也能用。

## 校验规则(`plugin_verify`)

1. 没有 `MANIFEST.MF` → 直接通过(**普通 zip 即可安装**)。
2. 有 `MANIFEST.MF` → 逐行读 `Name:` / `SHA-256-Digest:`，与实际文件 SHA-256 比对，不一致即失败。
3. 同时有 `SIGNATURE.RSA` 且存在 `/etc/mnt/.boot/plugin.pub` → 额外用 `openssl dgst -sha256 -verify` 校验。

> 这与**框架本体**完全不同：`/etc/mnt/.boot/{MANIFEST.MF,SIGNATURE.RSA}` 被固件用内置公钥强制校验，
> 任何一条不过就 `return`，**整个框架不挂载**(SSH 修改、Web 插件、审计全都不生效)。

## 打包

```bash
cd pkg
zip -qr ../dist/myplugin.zip .          # 直接在 pkg/ 里打, 包里就是 Release/install.sh...
# 或
zip -qr ../dist/myplugin.zip myplugin/  # 单层目录也能装(安装时会自动下钻一层)
```

要点：
* **先在 `pkg/` 里 `chmod +x`** `install.sh` `boot.sh` `uninstall.sh` `bin/*` `function/*`(zip 存权限位)。
* 统一 LF 换行：`sed -i 's/\r$//' <文本文件>`。
* 仓库里 `core.filemode=false`：新增可执行文件后要 `git update-index --chmod=+x <file>`，
  否则别人克隆出来的包里没有执行位，设备上 `test -x` 一挂整包不装。
* `ikplugin pack <目录> <zip>` 可自动生成 `MANIFEST.MF`(有私钥时再签名)，一般不必用。

## 目录结构建议(与 `examples/` 一致)

```
examples/myplugin/
├── build.sh          # 组装 pkg/ + 打 dist/<name>.zip
├── README.md
├── src/              # 源码(需要编译时)
└── pkg/              # = 会被 zip 的内容
    ├── Release
    ├── install.sh boot.sh uninstall.sh
    ├── bin/<name>
    ├── function/<name>            (可选)
    └── www/plugins/...            (可选)
```

技能自带 `assets/template/` 就是这个结构的可直接运行版本。
