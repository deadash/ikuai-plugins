# Web 插件：卡片 / 页面 / 后端接口

iKuai 的「系统设置 → 插件管理」是**数据驱动**的：后端遍历 `/usr/ikuai/www/plugins/*/*.json` 聚合卡片列表，
卡片点击后以 iframe 打开 `/plugins/app/<name>.html`。
本框架用 `plugin_web_patch()` 把官方写死的 `plugins/docker/` 改成了 `plugins/app/`。

## 三件套

```
www/plugins/<name>/<name>.json   卡片元数据(<name> 必须等于文件名, 也等于目录名)
www/plugins/app/<name>.html      插件页面(自包含 HTML)
www/plugins/app/<name>.png       卡片图标(建议 64x64)
function/<func_name>             后端接口(可选)
```

框架在**安装和每次开机**时把这几个目录软链到根分区(`lib/plugin.sh:plugin_web_link()`),
卸载时 `plugin_unlink()` 精确清理 —— **插件脚本不要自己维护这些链接**。

## 卡片 JSON

```json
{"name":"mytool","manufacturer":"deadash","version":"1.0.0",
 "title":"我的工具","author":"deadash","description":"一句话说明"}
```

* `name` 必须与文件名一致(前端用它拼 `/plugins/app/<name>.png|html`)。
* `title` 是卡片显示名 —— 框架的前端补丁把卡片文案从 `name` 改成了 `title`(`_s(e.title||e.name)`)。
* 卡片列表实测返回：

```json
{"Result":30000,"ErrMsg":"Success","Data":{"data":[
  {"name":"mytool","manufacturer":"deadash","version":"1.0.0","title":"我的工具", ...}]}}
```

## 页面(HTML)

页面是**独立 HTML**（框架用 iframe 打开，目录被改名为 `app`）。
**界面一律用统一 UI 套件 ikui**，页面里就两行：

```html
<link rel="stylesheet" href="./ikui.css">
<script src="./ikui.js"></script>
```

（`ikui.js` / `ikui.css` 跟页面同目录，由 `scripts/add-ui.sh` 放进 `www/plugins/app/`。）
组件、用法、以及**模板必须放 `<script type="text/x-template">`** 这个坑：
**见 `references/ui.md`**，写页面之前先看它。

数据交互直接 `fetch('/Action/call')`。前端**不要**引外部 CDN(设备内网环境)：

```js
function api(action, param) {
  return fetch('/Action/call', {
    method:'POST', headers:{'Content-Type':'application/json'},
    body: JSON.stringify({ func_name:'mytool', action:action, param:param||{} })
  }).then(r => r.json()).then(j => {
    if (j.Result !== 30000) throw new Error(j.ErrMsg || ('错误码 '+j.Result));
    return j.Data || {};
  });
}
```

> 页面改完记得 **Ctrl+F5 强刷**(分包/文件名不变，浏览器可能吃缓存)。

## 后端接口(`function/<func_name>`)

shebang 必须是 `#!/bin/bash /etc/ikcommon`：

```bash
#!/bin/bash /etc/ikcommon

__show_data() {                 # Show 会调用 __show_<TYPE>()
    local status
    status="$(/etc/mnt/plugins/mytool/bin/mytool status 2>/dev/null)"; [ -n "$status" ] || status='{}'
    json_append __json_result__ status:json
}

show()   { Show __json_result__; }     # 动作名必须是 name() 形式, 不能以下划线开头
seting() { case "$key" in ...) esac; } # 参数以 shell 变量注入: $key $value
```

### 分发链与返回码

```
openresty(ActionCall) -> /usr/ikuai/function/func_api.sh <func_name> <action> k=v...
```

`func_api.sh` 先检查该文件里是否存在 `^<action> ()` 的定义，不存在直接：

```json
{"Result":30002,"ErrMsg":"invalid action"}
```

返回码：`30000` 成功 / `30001` add 失败 / `30002` 修改失败(脚本 `return 1`) / `30003` 无此 func_name / `30004` 导入失败。

`show` 的 stdout 会被包成 `{"Result":30000,"ErrMsg":"Success","Data":<你的 JSON>}`。

### 可用工具(`/etc/ikcommon` 自动 source)

`ikcommon` 里已经 `Include json.sh,fsyslog.sh,sqlite.sh,check_varl.sh`，所以在后端接口里可以直接用：

| 函数 | 用途 |
| --- | --- |
| `json_append __json_result__ key:json` | 把变量 `key`(内容已是 JSON 字符串)追加进结果对象 |
| `json_append __json_result__ key:str` | 追加字符串(自动转义 `"`) |
| `json_append __json_result__ key:int` | 追加整数(变量为空时给 0) |
| `json_output a:str b:int c:json` | 直接生成一行 JSON 并 echo |
| `Show __json_result__` | 按 `$TYPE` 调 `__show_<TYPE>()` 后输出结果对象 |
| `json_decode 前缀 "$js"` / 用 `lua + cjson` | 把 JSON 解析成 shell 变量(`json_decode` 内部就是调 `lua`) |
| `sql_config_get_list <db> "select ..."` `sql_config_insert <db> <表> k:int k2:str` `sql_config_update <db> <表> "<where>" k:str` | 设备自带的 sqlite 封装 |
| `Syslog "..."` | 写系统日志(`logger -t sys_event`) |

> 变量名与 `json_append` 的键名**必须一致**(json 类型是直接展开变量)。

### 参数限制(重要)

* 请求参数值**不能包含空格和引号** —— lua 侧 `__rest_check_illegality_char` 会拒。
  自由文本(备注之类)前端把空格编码成 `+`，后端 `value="$(printf '%s' "$value" | tr '+' ' ')"` 还原。
* 失败时向 stdout 打印错误信息并 `return 1` → 前端看到 `Result=30002`。
* `TYPE` 是框架约定：页面用 `TYPE=data`(或 `data,total` 之类)选择 `__show_*` 分支。

### 新 func_name 的权限

超级管理员(组 1)不受限；其他用户组按 `perm_config` / `perm_default` 判定，新 func_name 走默认权限。

## 不开浏览器也能验证

```bash
PW=$(printf '%s' '<密码>' | md5sum | cut -d' ' -f1)
curl -s -c /tmp/ck -X POST http://<设备>/Action/login -H 'Content-Type: application/json' \
     -d "{\"username\":\"admin\",\"passwd\":\"$PW\",\"remember_password\":0}"
curl -s -b /tmp/ck -X POST http://<设备>/Action/call -H 'Content-Type: application/json' \
     -d '{"func_name":"plugins","action":"show","param":{"TYPE":"data"}}'      # 卡片列表
curl -s -b /tmp/ck -X POST http://<设备>/Action/call -H 'Content-Type: application/json' \
     -d '{"func_name":"mytool","action":"show","param":{"TYPE":"data"}}'
curl -s -b /tmp/ck -o /dev/null -w '%{http_code}\n' http://<设备>/plugins/app/mytool.html
```

> 注意 `passwd` 传的是 **md5(密码)**；静态资源未登录会 **302** 到登录页。
> 插件后端也可以在设备上直接跑：`/usr/ikuai/function/mytool show TYPE=data`(不走 openresty)。
