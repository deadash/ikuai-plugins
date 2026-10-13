//! rustdemo - iKuai 插件框架的 Rust 示例插件
//!
//! 演示插件系统的完整能力(安装/卸载 + 开机自启 + 前端设置 + 持久化 + 数据库):
//!   * 守护进程按配置间隔采集系统指标(uptime/load/内存/连接跟踪数)写入嵌入式数据库
//!   * 数据库用 redb(纯 Rust / 静态链接 / 事务), 存放于持久分区
//!       /etc/mnt/plugins/rustdemo/data/rustdemo.redb
//!   * redb 库文件是**独占锁**, 所以守护进程是唯一的写入者, 命令行/后端接口通过
//!     Unix socket(data/rustdemo.sock) 查询; 守护不在时才直接开库(不冲突)
//!   * 配置(采集间隔/保留条数/备注)也存在数据库的 config 表, 由 Web 页面修改
//!   * 所有命令输出 JSON, 后端接口(usr/ikuai/function/rustdemo)直接透传给前端
//!
//! 命令:
//!   rustdemo daemon            守护进程: 周期采集 + Unix socket 服务
//!   rustdemo status            守护/数据库状态(JSON)
//!   rustdemo stats             统计信息(JSON)
//!   rustdemo tail [n]          最近 n 条记录(JSON, 默认 30, 上限 200)
//!   rustdemo config            读取配置(JSON)
//!   rustdemo get <key>         读单个配置项
//!   rustdemo set <key> <value> 写配置项(interval/retention/note)
//!   rustdemo sample            立刻采集一条
//!   rustdemo clear             清空采样数据(保留配置)
//!   rustdemo drop              删除所有表(卸载时用)
//!   rustdemo init              初始化数据库/默认配置

use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process;
use std::sync::Arc;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use redb::{Database, ReadableTable, ReadableTableMetadata, TableDefinition};
use serde_json::{json, Value};

const TBL_CONFIG: TableDefinition<&str, &str> = TableDefinition::new("config");
const TBL_SAMPLES: TableDefinition<u64, &str> = TableDefinition::new("samples");
const TBL_EVENTS: TableDefinition<u64, &str> = TableDefinition::new("events");

const DEFAULT_DB: &str = "/etc/mnt/plugins/rustdemo/data/rustdemo.redb";
const DEFAULT_INTERVAL: u64 = 15;
const DEFAULT_RETENTION: u64 = 500;
const MAX_TAIL: usize = 200;

struct Ctx {
    db_path: PathBuf,
}

impl Ctx {
    fn dir(&self) -> PathBuf {
        self.db_path.parent().unwrap_or(&self.db_path).to_path_buf()
    }
    fn socket_path(&self) -> PathBuf {
        self.dir().join("rustdemo.sock")
    }
    fn pid_file(&self) -> PathBuf {
        self.dir().join("daemon.pid")
    }
    fn log_file(&self) -> PathBuf {
        self.dir().join("daemon.log")
    }
    fn open(&self) -> Result<Database, String> {
        fs::create_dir_all(self.dir()).map_err(|e| format!("创建目录失败: {e}"))?;
        Database::create(&self.db_path).map_err(|e| format!("打开数据库失败: {e}"))
    }
    /// 守护进程在跑时用 socket 查询(redb 是独占锁, 不能同时开两个)
    fn request(&self, line: &str) -> Option<String> {
        let s = UnixStream::connect(self.socket_path()).ok()?;
        s.set_read_timeout(Some(Duration::from_secs(10))).ok()?;
        s.set_write_timeout(Some(Duration::from_secs(10))).ok()?;
        let mut s = s;
        s.write_all(format!("{line}\n").as_bytes()).ok()?;
        let mut out = String::new();
        BufReader::new(s).read_line(&mut out).ok()?;
        let out = out.trim().to_string();
        if out.is_empty() {
            None
        } else {
            Some(out)
        }
    }
}

// ------------------------------------------------------------------ /proc 采集

fn read_proc(path: &str) -> Option<String> {
    fs::read_to_string(path).ok()
}

fn uptime_secs() -> u64 {
    read_proc("/proc/uptime")
        .and_then(|s| s.split_whitespace().next().map(|v| v.to_string()))
        .and_then(|v| v.parse::<f64>().ok())
        .map(|v| v as u64)
        .unwrap_or(0)
}

fn load1() -> f64 {
    read_proc("/proc/loadavg")
        .and_then(|s| s.split_whitespace().next().map(|v| v.to_string()))
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(0.0)
}

fn mem_available_kb() -> u64 {
    read_proc("/proc/meminfo")
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("MemAvailable:"))
                .and_then(|l| l.split_whitespace().nth(1).map(|v| v.to_string()))
                .and_then(|v| v.parse::<u64>().ok())
        })
        .unwrap_or(0)
}

fn conntrack_count() -> u64 {
    read_proc("/proc/net/nf_conntrack")
        .map(|s| s.lines().count() as u64)
        .unwrap_or(0)
}

fn now_ts() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ------------------------------------------------------------------ 数据库操作
// 下面这些函数是"真正的实现", 命令行与守护进程的 socket 服务都调用它们。

fn get_config(db: &Database, key: &str) -> Option<String> {
    let rtx = db.begin_read().ok()?;
    let t = rtx.open_table(TBL_CONFIG).ok()?;
    t.get(key).ok()?.map(|v| v.value().to_string())
}

fn set_config(db: &Database, key: &str, value: &str) -> Result<(), String> {
    let wtx = db.begin_write().map_err(|e| e.to_string())?;
    {
        let mut t = wtx.open_table(TBL_CONFIG).map_err(|e| e.to_string())?;
        t.insert(key, value).map_err(|e| e.to_string())?;
    }
    wtx.commit().map_err(|e| e.to_string())?;
    Ok(())
}

fn next_seq(db: &Database) -> u64 {
    let n = get_config(db, "__seq").and_then(|v| v.parse().ok()).unwrap_or(0) + 1;
    let _ = set_config(db, "__seq", &n.to_string());
    n
}

fn log_event(db: &Database, kind: &str, detail: &str) {
    let seq = next_seq(db);
    if let Ok(wtx) = db.begin_write() {
        if let Ok(mut t) = wtx.open_table(TBL_EVENTS) {
            let v = json!({"ts": now_ts(), "kind": kind, "detail": detail}).to_string();
            let _ = t.insert(seq, v.as_str());
        }
        let _ = wtx.commit();
    }
}

fn ensure_defaults(db: &Database) -> Result<(), String> {
    let defaults: [(&str, &str); 4] = [
        ("interval", "15"),
        ("retention", "500"),
        ("note", ""),
        ("created_at", "__now__"),
    ];
    for (k, v) in defaults {
        if get_config(db, k).is_none() {
            let val = if v == "__now__" { now_ts().to_string() } else { v.to_string() };
            set_config(db, k, &val)?;
        }
    }
    Ok(())
}

fn sample_count(db: &Database) -> u64 {
    db.begin_read()
        .ok()
        .and_then(|rtx| rtx.open_table(TBL_SAMPLES).ok())
        .and_then(|t| t.len().ok())
        .unwrap_or(0)
}

fn insert_sample(db: &Database) -> Result<u64, String> {
    let sample = json!({
        "ts": now_ts(),
        "uptime": uptime_secs(),
        "load1": load1(),
        "mem_available_kb": mem_available_kb(),
        "conntrack": conntrack_count(),
    });
    let seq = next_seq(db);
    let wtx = db.begin_write().map_err(|e| e.to_string())?;
    {
        let mut t = wtx.open_table(TBL_SAMPLES).map_err(|e| e.to_string())?;
        t.insert(seq, sample.to_string().as_str()).map_err(|e| e.to_string())?;
    }
    wtx.commit().map_err(|e| e.to_string())?;
    Ok(seq)
}

fn prune(db: &Database, retention: u64) -> u64 {
    let total = sample_count(db);
    if total <= retention {
        return 0;
    }
    let remove = total - retention;
    let mut keys: Vec<u64> = Vec::new();
    if let Ok(rtx) = db.begin_read() {
        if let Ok(t) = rtx.open_table(TBL_SAMPLES) {
            if let Ok(it) = t.iter() {
                for (k, _) in it.flatten() {
                    keys.push(k.value());
                    if keys.len() >= remove as usize {
                        break;
                    }
                }
            }
        }
    }
    if keys.is_empty() {
        return 0;
    }
    if let Ok(wtx) = db.begin_write() {
        {
            if let Ok(mut t) = wtx.open_table(TBL_SAMPLES) {
                for k in &keys {
                    let _ = t.remove(k);
                }
            }
        }
        let _ = wtx.commit();
    }
    keys.len() as u64
}

fn daemon_pid(ctx: &Ctx) -> Option<u32> {
    let pid: u32 = fs::read_to_string(ctx.pid_file()).ok()?.trim().parse().ok()?;
    if PathBuf::from(format!("/proc/{pid}")).exists() {
        Some(pid)
    } else {
        None
    }
}

// ------------------------------------------------------------------ 各查询的 JSON 实现

fn json_stats(ctx: &Ctx, db: &Database) -> Value {
    let mut last: Option<Value> = None;
    if let Ok(rtx) = db.begin_read() {
        if let Ok(t) = rtx.open_table(TBL_SAMPLES) {
            if let Ok(it) = t.iter() {
                for (_, v) in it.flatten() {
                    if let Ok(x) = serde_json::from_str::<Value>(v.value()) {
                        last = Some(x);
                    }
                }
            }
        }
    }
    let pid = daemon_pid(ctx);
    json!({
        "db_path": ctx.db_path.display().to_string(),
        "db_size": fs::metadata(&ctx.db_path).map(|m| m.len()).unwrap_or(0),
        "samples": sample_count(db),
        "interval": get_config(db, "interval").unwrap_or_else(|| DEFAULT_INTERVAL.to_string()),
        "retention": get_config(db, "retention").unwrap_or_else(|| DEFAULT_RETENTION.to_string()),
        "note": get_config(db, "note").unwrap_or_default(),
        "created_at": get_config(db, "created_at").unwrap_or_default(),
        "last": last,
        "daemon_pid": pid,
        "daemon_running": pid.is_some(),
    })
}

fn json_config(db: &Database) -> Value {
    let mut out = BTreeMap::new();
    for k in ["interval", "retention", "note", "created_at"] {
        out.insert(k.to_string(), json!(get_config(db, k).unwrap_or_default()));
    }
    serde_json::to_value(out).unwrap_or_else(|_| json!({}))
}

fn json_tail(db: &Database, n: usize) -> Value {
    let n = n.min(MAX_TAIL);
    let total = sample_count(db);
    let skip = total.saturating_sub(n as u64) as usize;
    let mut items: Vec<Value> = Vec::new();
    if let Ok(rtx) = db.begin_read() {
        if let Ok(t) = rtx.open_table(TBL_SAMPLES) {
            if let Ok(it) = t.iter() {
                for (_, v) in it.flatten().skip(skip) {
                    if let Ok(x) = serde_json::from_str::<Value>(v.value()) {
                        items.push(x);
                    }
                }
            }
        }
    }
    Value::Array(items)
}

/// 配置项校验 + 写入, 返回给前端的 JSON
fn do_set(db: &Database, key: &str, value: &str) -> Result<Value, String> {
    match key {
        "interval" => {
            let v: u64 = value.parse().map_err(|_| "interval 必须是整数".to_string())?;
            if !(2..=86400).contains(&v) {
                return Err("interval 允许范围 2~86400 秒".into());
            }
        }
        "retention" => {
            let v: u64 = value.parse().map_err(|_| "retention 必须是整数".to_string())?;
            if !(10..=100000).contains(&v) {
                return Err("retention 允许范围 10~100000 条".into());
            }
        }
        "note" => {
            if value.chars().count() > 128 {
                return Err("note 最多 128 个字符".into());
            }
        }
        _ => return Err(format!("不支持的配置项: {key}")),
    }
    ensure_defaults(db)?;
    set_config(db, key, value)?;
    log_event(db, "config", &format!("{key}={value}"));
    Ok(json!({"ok": true, "key": key, "value": value}))
}

fn do_clear(db: &Database) -> Result<Value, String> {
    let removed = {
        let wtx = db.begin_write().map_err(|e| e.to_string())?;
        let n = {
            let mut t = wtx.open_table(TBL_SAMPLES).map_err(|e| e.to_string())?;
            let n = t.len().map_err(|e| e.to_string())?;
            t.retain(|_, _| false).map_err(|e| e.to_string())?;
            n
        };
        wtx.commit().map_err(|e| e.to_string())?;
        n
    };
    log_event(db, "clear", &format!("清空 {removed} 条采样"));
    Ok(json!({"ok": true, "removed": removed}))
}

fn do_sample(db: &Database) -> Result<Value, String> {
    ensure_defaults(db)?;
    let seq = insert_sample(db)?;
    let retention = get_config(db, "retention").and_then(|v| v.parse().ok()).unwrap_or(DEFAULT_RETENTION);
    let pruned = prune(db, retention);
    Ok(json!({"ok": true, "seq": seq, "pruned": pruned, "samples": sample_count(db)}))
}

fn do_init(ctx: &Ctx, db: &Database) -> Result<Value, String> {
    ensure_defaults(db)?;
    log_event(db, "init", "数据库初始化");
    Ok(json!({"ok": true, "db": ctx.db_path.display().to_string()}))
}

fn do_drop(db: &Database) -> Result<Value, String> {
    let wtx = db.begin_write().map_err(|e| e.to_string())?;
    let _ = wtx.delete_table(TBL_SAMPLES);
    let _ = wtx.delete_table(TBL_EVENTS);
    let _ = wtx.delete_table(TBL_CONFIG);
    wtx.commit().map_err(|e| e.to_string())?;
    Ok(json!({"ok": true}))
}

// ------------------------------------------------------------------ socket 协议
// 一行一个请求, 一行一个 JSON 响应:
//   ping | status | stats | config | tail <n> | sample | clear | drop | set <key> <value>

fn handle_line(ctx: &Ctx, db: &Database, line: &str) -> Value {
    // 注意: 用 splitn(3) 而不是 split_whitespace() —— 第三个参数(如 note)允许带空格,
    // 否则 "set note 机房A 出口路由" 会被截断成 "机房A"。
    let mut it = line.splitn(3, ' ');
    let cmd = it.next().unwrap_or("");
    let arg1 = it.next().unwrap_or("");
    let arg2 = it.next().unwrap_or("");
    let res: Result<Value, String> = match cmd {
        "ping" => Ok(json!({"ok": true, "pong": true})),
        "stats" => Ok(json_stats(ctx, db)),
        "config" => Ok(json_config(db)),
        "tail" => Ok(json_tail(db, arg1.parse().unwrap_or(30))),
        "get" => Ok(json!({"key": arg1, "value": get_config(db, arg1).unwrap_or_default()})),
        "set" => do_set(db, arg1, arg2),
        "sample" => do_sample(db),
        "clear" => do_clear(db),
        "init" => do_init(ctx, db),
        "drop" => do_drop(db),
        "" => Ok(json!({"ok": true})),
        _ => Err(format!("未知命令: {cmd}")),
    };
    match res {
        Ok(v) => v,
        Err(e) => json!({"ok": false, "error": e}),
    }
}

fn serve(ctx: &Ctx, db: &Database) -> Result<(), String> {
    let path = ctx.socket_path();
    let _ = fs::remove_file(&path);
    let listener = UnixListener::bind(&path).map_err(|e| format!("绑定 socket 失败: {e}"))?;
    for stream in listener.incoming() {
        let Ok(mut s) = stream else { continue };
        let line = {
            let mut buf = String::new();
            let mut r = BufReader::new(&s);
            if r.read_line(&mut buf).is_err() {
                continue;
            }
            buf.trim().to_string()
        };
        let resp = handle_line(ctx, &db, &line);
        let _ = s.write_all(format!("{resp}\n").as_bytes());
        let _ = s.flush();
    }
    Ok(())
}

// ------------------------------------------------------------------ 命令行

/// 优先走守护进程的 socket(数据库被它占着锁), 守护不在时本地直连数据库
fn query(ctx: &Ctx, line: &str) -> Result<Value, String> {
    if let Some(resp) = ctx.request(line) {
        if let Ok(v) = serde_json::from_str::<Value>(&resp) {
            return Ok(v);
        }
    }
    let db = ctx.open()?;
    match handle_line(ctx, &db, line) {
        Value::Object(m) if m.get("ok") == Some(&json!(false)) => {
            Err(m.get("error").map(|e| e.to_string()).unwrap_or_else(|| "执行失败".into()))
        }
        v => Ok(v),
    }
}

fn cmd_daemon(ctx: &Ctx) -> Result<(), String> {
    let db = Arc::new(ctx.open()?);
    ensure_defaults(&db)?;
    fs::write(ctx.pid_file(), process::id().to_string()).map_err(|e| e.to_string())?;
    log_event(&db, "daemon", "守护进程启动");

    let mut logf = fs::OpenOptions::new().create(true).append(true).open(ctx.log_file()).ok();
    if let Some(f) = logf.as_mut() {
        let _ = writeln!(f, "[{}] daemon start pid={} db={}", now_ts(), process::id(), ctx.db_path.display());
    }

    // socket 服务线程: 命令行/后端接口的查询都走这里(redb 独占锁, 只有本进程能开库)
    {
        let ctx2 = Ctx { db_path: ctx.db_path.clone() };
        let db2 = Arc::clone(&db);
        thread::spawn(move || {
            let _ = serve(&ctx2, &db2);
        });
    }

    loop {
        let interval: u64 = get_config(&db, "interval").and_then(|v| v.parse().ok()).unwrap_or(DEFAULT_INTERVAL);
        // do_sample() 内部会按 retention 裁剪
        match do_sample(&db) {
            Ok(v) => {
                if let Some(f) = logf.as_mut() {
                    let _ = writeln!(f, "[{}] {v}", now_ts());
                }
            }
            Err(e) => {
                if let Some(f) = logf.as_mut() {
                    let _ = writeln!(f, "[{}] 采集失败: {e}", now_ts());
                }
            }
        }
        thread::sleep(Duration::from_secs(interval.max(2)));
    }
}

fn print_json(v: &Value) {
    println!("{v}");
}

fn is_error(v: &Value) -> bool {
    matches!(v, Value::Object(m) if m.get("ok") == Some(&json!(false)))
}

fn usage() {
    eprintln!("rustdemo - iKuai 插件示例(Rust + redb 嵌入式数据库 + Unix socket 服务)");
    eprintln!("用法: rustdemo [--db <路径>] <命令> [参数]");
    eprintln!("命令: daemon | status | stats | tail [n] | config | get <k> | set <k> <v> | sample | clear | drop | init");
}

fn main() {
    let mut args: Vec<String> = env::args().skip(1).collect();
    let mut db_path = env::var("RUSTDEMO_DB").unwrap_or_else(|_| DEFAULT_DB.to_string());

    if let Some(pos) = args.iter().position(|a| a == "--db") {
        if pos + 1 < args.len() {
            db_path = args[pos + 1].clone();
            args.drain(pos..=pos + 1);
        }
    }

    let ctx = Ctx { db_path: PathBuf::from(db_path) };
    let cmd = args.first().map(|s| s.as_str()).unwrap_or("");
    let a1 = args.get(1).map(|s| s.as_str()).unwrap_or("");
    let a2 = args.get(2).map(|s| s.as_str()).unwrap_or("");

    if cmd == "daemon" {
        if let Err(e) = cmd_daemon(&ctx) {
            println!("{}", json!({"ok": false, "error": e}));
            process::exit(1);
        }
        return;
    }

    let req = match cmd {
        "" => { usage(); process::exit(2); }
        "status" => "stats".to_string(),
        "stats" | "config" | "sample" | "clear" | "drop" | "init" => cmd.to_string(),
        "tail" => format!("tail {}", if a1.is_empty() { "30" } else { a1 }),
        "get" => format!("get {}", a1),
        "set" => format!("set {} {}", a1, a2),
        _ => { usage(); process::exit(2); }
    };

    match query(&ctx, &req) {
        Ok(v) => {
            print_json(&v);
            if is_error(&v) {
                process::exit(1);
            }
        }
        Err(e) => {
            println!("{}", json!({"ok": false, "error": e}));
            process::exit(1);
        }
    }
}
