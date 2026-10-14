# Lua 调用支持（LuaJIT 2.1.0-beta3）

设备上 `/usr/bin/lua` 是指向 `/usr/bin/luajit` 的软链，两个命令等价：

```
$ lua -v
LuaJIT 2.1.0-beta3 -- Copyright (C) 2005-2022 Mike Pall. https://luajit.org/
```

`_VERSION` 是 `Lua 5.1` —— **按 Lua 5.1 / LuaJIT 语法写**(`goto` 可用，`//` 整除、位运算运算符、
`\u{}` 转义等 5.3 特性不可用)。实测 `lua -e 'print(1//2)'` → `unexpected symbol near '/'`。

设备自己就这么用：`/usr/ikuai/include/json.sh` 的 `json_decode()` 内部就是

```bash
lua <<EOF
cjson = require "cjson"
...
EOF
```

所以"插件里调 Lua"是设备的既定做法，不是旁门左道。

## 可用模块(实测)

| 模块 | 状态 | 说明 |
| --- | --- | --- |
| `cjson` | ✅ | JSON 编解码 |
| `lsqlite3` | ✅ | SQLite 绑定(3.8.11.1，与 CLI 同库) |
| `iklua.utils` / `iklua.ffi.*` | ✅ | 设备自带工具：`socket`(fd/epoll)、`ping`、`ps`、`clock`、`signal`、`flock`、`urlcode`、`getopt`、`dns` |
| `resty.*` / `ngx.*` | ⚠️ | **只在 openresty 进程内有意义**；独立 `luajit` 里 `require("resty.shell")` 会报错(缺 ngx 全局) |
| `require("rt")` 等 | ❌ | 无 |

`package.path` 默认含 `./?.lua;/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua;...`。
插件自带模块时显式指路：

```bash
LUA_PATH="$ROOT/share/?.lua;$LUA_PATH" luajit "$ROOT/share/report.lua" "$DB"
```

## 从 shell 调用 Lua

```bash
# 1) 跑脚本
luajit "$ROOT/share/report.lua" "$DB"

# 2) 内联(适合一次性解析/拼 JSON)
out="$(lua -e '
  local cjson = require("cjson")
  print(cjson.encode({ ok = true, n = #arg }))
' a b c)"
```

## 常用片段

### JSON

```lua
local cjson = require("cjson")
cjson.encode({})            -- -> {}      (空表默认编成对象)
cjson.encode({1,2,3})       -- -> [1,2,3]
local t = cjson.decode('{"a":[1,2],"b":"x"}')
print(t.a[2], t.b)          -- 2   x
```

* `cjson` 不认非字符串/数字的键；稀疏数组会被编成对象 —— 需要严格数组时显式构造。
* 需要"空数组 `[]`"时可以用 `cjson.encode(setmetatable({}, {__jsontype="array"}))` 或干脆手工拼 `[]`。

### SQLite

```lua
local sqlite3 = require("lsqlite3")
local db = sqlite3.open("/etc/mnt/plugins/mytool/data/mytool.db")
db:exec("PRAGMA busy_timeout=3000;")                   -- 建议和 shell 侧一样带上

db:exec("CREATE TABLE IF NOT EXISTS sample(id INTEGER PRIMARY KEY, v TEXT);")

-- 写: 用占位符 + bind_values(这是 shell 侧做不到的防注入方式)
local st = db:prepare("INSERT OR REPLACE INTO sample(id,v) VALUES(?,?)")
st:bind_values(1, "abc")        -- 注意是 bind_values, 不是 bind("1","abc")
st:step()
st:finalize()

-- 读: nrows 是迭代器, 每行是按列名索引的表
for row in db:nrows("SELECT id, v FROM sample ORDER BY id") do
    print(row.id, row.v)
end

db:close()
```

> `stmt:bind(a, b)` 的语义是 `bind(参数序号, 值)`，传两个字符串会报
> `bad argument #1 to 'bind' (number expected, got string)` —— 多值请用 `bind_values`。

### 执行外部命令

独立 luajit 里没有 `resty.shell`，用 Lua 标准库：

```lua
local f = io.popen("cat /proc/loadavg", "r")
local load = f:read("*l")
f:close()
os.execute("logger -t mytool 'hello'")
```

> 设备没有 `timeout`(见 `autostart.md`)，`os.execute` 里别用。

## 什么时候用 Lua（取舍）

* **用 Lua**：要稳定解析/生成 JSON、要写较复杂的数据处理、要 `lsqlite3` 参数绑定、要常驻做 socket 服务。
* **用 shell**：只是几行 SQL / 文件操作 / 拉起进程 —— 调 lua 反而多一层依赖与转义风险。
* 插件 **不需要打包 Lua 解释器**：设备自带 LuaJIT 与常用模块，直接调即可。

## 一个现成的例子

技能自带模板 `assets/template/pkg/share/report.lua`(配合 `bin/plugdemo report`)：
用 `lsqlite3` 读采样表 + `cjson` 出 JSON，实测输出

```json
{"samples":4,"avg_load":0.3025,"last_ts":1791987062,"engine":"LuaJIT 2.1.0-beta3","first_ts":1791958203}
```
