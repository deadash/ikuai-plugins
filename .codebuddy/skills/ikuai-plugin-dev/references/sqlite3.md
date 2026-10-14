# 推荐的 sqlite3 用法(设备版本 3.8.11.1)

设备实测：`/usr/bin/sqlite3` = **3.8.11.1 (2015-07-29)**，`/usr/lib/libsqlite3.so.0.8.6`，
Lua 侧 `require("lsqlite3")` 可用(`sqlite3.version()` 同为 3.8.11.1)。

**这是 2015 年的版本**，很多"现代 SQL"不可用。写 SQL 前先对照下面的边界表，
否则会出现"本地能跑、设备报 syntax error"。

## 1. 三种调用方式

| 方式 | 适用 | 说明 |
| --- | --- | --- |
| `sqlite3` CLI | 插件 `bin/*`、`boot.sh`、`install.sh` | 最省事，**推荐默认用这个** |
| Lua `lsqlite3` | 需要复杂逻辑/JSON 输出时 | 见 `lua.md` |
| `/etc/ikcommon` 的 `sql_config_*` | **仅** `function/<name>` 后端接口里 | ikcommon 已 `Include sqlite.sh`，见文末 |

## 2. 语法边界(实测)

### ✅ 可用

```sql
PRAGMA journal_mode=WAL;            -- 返回 wal
PRAGMA busy_timeout=3000;
PRAGMA user_version=7;              -- 读回 7, 适合做"schema 版本"
WITH x(n) AS (SELECT 1 UNION ALL SELECT 2) SELECT COUNT(*) FROM x;   -- CTE(3.8.3+)
CREATE INDEX ix ON t(a) WHERE a > 0;                                 -- 部分索引(3.8+)
CREATE TABLE / CREATE VIEW / CREATE TRIGGER
ALTER TABLE t ADD COLUMN c INT;                                      -- 只支持 ADD
INSERT OR REPLACE INTO t(...) VALUES(...);                           -- 用这个代替 UPSERT
INSERT OR IGNORE  INTO t(...) VALUES(...);
GROUP_CONCAT(col)
strftime('%s','now') / CAST(... AS INTEGER)
ATTACH '/tmp/other.db' AS o;   PRAGMA database_list;
DELETE FROM t WHERE id <= (SELECT MAX(id) - 500 FROM t);             -- 保留最近 N 条
```

### ❌ 不可用(需要更高版本 / 未编译进)

| 写法 | 需要 | 实测报错 |
| --- | --- | --- |
| `INSERT ... ON CONFLICT(k) DO UPDATE SET ...`(UPSERT) | 3.24 | `near "on": syntax error` |
| `INSERT/UPDATE/DELETE ... RETURNING` | 3.35 | `near "returning": syntax error` |
| `UPDATE t SET ... FROM ...` | 3.33 | `near "from": syntax error` |
| 窗口函数 `ROW_NUMBER() OVER ()` | 3.25 | `near "(": syntax error` |
| `ALTER TABLE ... RENAME COLUMN` | 3.25 | `near "column": syntax error` |
| `ALTER TABLE ... DROP COLUMN` | 3.35 | — |
| `json_extract(x,'$.a')` / `->` / `->>`(json1) | 扩展 | `near "a": syntax error` |
| `iif(a,b,c)` | 3.32 | `no such function: iif` |
| `STRICT` 表 | 3.37 | — |
| `VACUUM INTO 'x.db'` | 3.27 | — |
| CLI `-json` 输出 | 3.33 | `unknown option: -json` |

**替代方案**：
* UPSERT → `INSERT OR REPLACE`(注意它会先 DELETE 整行，未提供的列会被重置为默认值)，
  或 `UPDATE ... ; INSERT OR IGNORE ...` 两步。
* UPDATE ... FROM → 用子查询：`UPDATE t SET x=(SELECT y FROM o WHERE o.id=t.id);`
* json1 → 用 Lua + `cjson`(`lua.md`)，或 shell 里拼 JSON。
* CLI `-json` → `-line` / `-separator '|'` 自己拼，或 `lua + lsqlite3 + cjson`。

## 3. 推荐封装(插件 `bin/*` 里)

```bash
DB="$ROOT/data/myplugin.db"

# -cmd ".timeout 3000" 处理并发写锁(设备上只有一个写者时也建议带上, 避免 crond 撞上)
db() { sqlite3 -cmd ".timeout 3000" "$DB" "$@" 2>/dev/null; }
```

* 多条语句**合并成一次调用**：既是事务(原子)，也省进程开销。

```bash
db "INSERT INTO sample(ts,v) VALUES(CAST(strftime('%s','now') AS INTEGER),'$v');
    DELETE FROM sample WHERE id <= (SELECT MAX(id) - 500 FROM sample);"
```

* 拼接字符串务必**用单引号**并自行过滤；设备上 sqlite3 没有参数绑定能力(CLI 层)。
  数值参数先做 `case "$v" in ''|*[!0-9]*) return 1 ;; esac` 校验，别把它直接拼进 SQL。
* 需要防注入的字段，优先走 Lua `lsqlite3`(支持 `?` 占位符 + `bind_values`)。

## 4. 推荐建库脚本(幂等)

```sql
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS config(
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT OR IGNORE INTO config(key,value) VALUES('interval','15');
INSERT OR IGNORE INTO config(key,value) VALUES('note','');

CREATE TABLE IF NOT EXISTS sample(
    id     INTEGER PRIMARY KEY AUTOINCREMENT,
    ts     INTEGER NOT NULL,
    uptime TEXT,
    load1  TEXT
);
CREATE INDEX IF NOT EXISTS idx_sample_ts ON sample(ts);
```

* `install.sh` 与 `boot.sh` 都跑一遍这个脚本 —— 幂等、开销可忽略。
* 需要变更表结构时用 `PRAGMA user_version` 做迁移标记：

```bash
v="$(db 'PRAGMA user_version;')"
if [ "${v:-0}" -lt 2 ]; then
    db 'ALTER TABLE sample ADD COLUMN note TEXT;' 'PRAGMA user_version=2;'
fi
```

> 注意 `ALTER TABLE ... ADD COLUMN` 是 3.8 唯一支持的 ALTER 形式；改列名/删列只能"建新表 + 拷数据"。

## 5. 读写与清理

```bash
# 写
db "INSERT INTO sample(ts,uptime,load1) VALUES(CAST(strftime('%s','now') AS INTEGER),'$up','$load');"

# 读单值
n="$(db 'SELECT COUNT(*) FROM sample;')"

# 读多行(自己拼 JSON, 不要用 -json)
db -separator $'\t' 'SELECT ts,load1 FROM sample ORDER BY id DESC LIMIT 20;' | \
while IFS=$'\t' read -r ts v; do printf '%s{"ts":%s,"v":"%s"}' "${sep:+,}" "$ts" "$v"; sep=1; done

# 保留窗口(按 id 或 ts)
db "DELETE FROM sample WHERE ts < strftime('%s','now') - 86400;"
```

## 6. 备份与体积

```bash
sqlite3 -cmd ".timeout 3000" "$DB" ".backup '$ROOT/data/backup.db'"   # 在线备份(点命令)
sqlite3 "$DB" "VACUUM;"                                               # 注意: 需要额外空闲空间
```

WAL 模式会额外产生 `-wal` / `-shm` 文件，停进程后 `sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE);"`
可以收拾干净。插件数据放持久分区 `/etc/mnt/plugins/<name>/data/`(升级会被保留)。

## 7. 设备自带的 sqlite 封装(仅后端接口)

`function/<func_name>` 的 shebang `#!/bin/bash /etc/ikcommon` 会 `Include json.sh,fsyslog.sh,sqlite.sh,check_varl.sh`，
于是可以直接用：

```bash
sql_config_get_list <db> "SELECT * FROM t" prefix=old_ format_timestamp="t1,t2"
sql_config_insert   <db> <表> name:str count:int flag:null
sql_config_update   <db> <表> "id=1" name:str
```

它们内部走 `sqlite3`，并对 `like` 特殊字符、时间戳格式化做了处理。
**注意**：这些函数只在 source 了 ikcommon 的脚本里存在，插件自己的 `bin/*`(不 source ikcommon)用不了，
所以在 `bin/*` 里请用上面的 `db()` 封装。
