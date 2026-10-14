--[[
  report.lua —— 演示"插件里调用设备自带 Lua"。

  设备上 lua/luajit 都是 LuaJIT 2.1(Lua 5.1 语义), 且自带这些库(实测):
    require("cjson")     -- JSON 编解码
    require("lsqlite3")  -- SQLite 绑定(与自带的 sqlite3 CLI 同一个库, 3.8.11.1)
    require("resty.shell") / require("resty.core") ...

  用法: luajit report.lua <db 路径>
  输出: 一行 JSON(echo 给 shell, 由后端接口 json_append 成 Data.report)
]]

local sqlite3 = require("lsqlite3")
local cjson   = require("cjson")

local path = arg[1] or "/etc/mnt/plugins/plugdemo/data/plugdemo.db"

local ok, db = pcall(sqlite3.open, path)
if not ok or not db then
    print(cjson.encode({ error = "open failed" }))
    return
end

local n, sum, first_ts, last_ts = 0, 0, nil, nil
-- nrows 是迭代器: 每行是一个按列名索引的 table
for row in db:nrows("SELECT ts, load1 FROM sample ORDER BY id") do
    n = n + 1
    sum = sum + (tonumber(row.load1) or 0)
    local ts = tonumber(row.ts) or 0
    if first_ts == nil or ts < first_ts then first_ts = ts end
    if last_ts == nil or ts > last_ts then last_ts = ts end
end

db:close()

print(cjson.encode({
    samples  = n,
    avg_load = n > 0 and (sum / n) or 0,
    first_ts = first_ts or 0,
    last_ts  = last_ts or 0,
    engine   = jit and jit.version or _VERSION,
}))
