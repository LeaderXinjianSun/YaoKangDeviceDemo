//! SQLite：参数键值表（P0）。
//! P5 起在同一库文件追加运动数组业务表。

use std::collections::HashMap;

use rusqlite::Connection;
use tauri::{AppHandle, Manager};

/// 连接参数 + 通信时序的首启默认值（第 9 条：默认 192.168.1.88:502）
const DEFAULTS: &[(&str, &str)] = &[
    ("plc_ip", "192.168.1.88"),
    ("plc_port", "502"),
    ("modbus_unit_id", "1"),
    ("real_byte_order", "ABCD"),
    ("read_interval_ms", "500"),
    ("heartbeat_reg", "210"),
    ("heartbeat_ms", "100"),
    ("watchdog_read_ms", "1000"),
    ("watchdog_fails", "3"),
    ("auto_connect", "true"),
    ("reconnect_backoff_ms", "1000,2000,5000,10000"),
    ("conn_timeout_ms", "3000"),
    ("io_timeout_ms", "1000"),
];

/// 打开（必要时创建）应用数据目录下的 ldr_plc.db
pub fn open_app_db<R: tauri::Runtime>(app: &AppHandle<R>) -> Result<Connection, String> {
    let dir = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("获取应用数据目录失败: {e}"))?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("创建数据目录失败: {e}"))?;

    let path = dir.join("ldr_plc.db");
    let conn = Connection::open(path).map_err(|e| format!("打开 SQLite 失败: {e}"))?;

    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS app_config (
             key        TEXT PRIMARY KEY,
             value      TEXT NOT NULL,
             updated_at TEXT NOT NULL DEFAULT (datetime('now','localtime'))
         );",
    )
    .map_err(|e| format!("建表失败: {e}"))?;

    Ok(conn)
}

/// 首启播种默认值；已存在的 key 不覆盖
pub fn seed_defaults(conn: &Connection) -> Result<(), String> {
    for (key, value) in DEFAULTS {
        conn.execute(
            "INSERT OR IGNORE INTO app_config(key, value) VALUES (?1, ?2)",
            rusqlite::params![key, value],
        )
        .map_err(|e| format!("播种 {key} 失败: {e}"))?;
    }
    Ok(())
}

#[tauri::command]
pub fn config_get_all(
    state: tauri::State<'_, crate::AppState>,
) -> Result<HashMap<String, String>, String> {
    let conn = state.db.lock().map_err(|e| format!("锁失败: {e}"))?;
    let mut stmt = conn
        .prepare("SELECT key, value FROM app_config")
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })
        .map_err(|e| e.to_string())?;

    let mut map = HashMap::new();
    for row in rows {
        let (k, v) = row.map_err(|e| e.to_string())?;
        map.insert(k, v);
    }
    Ok(map)
}

#[tauri::command]
pub fn config_set(
    state: tauri::State<'_, crate::AppState>,
    key: String,
    value: String,
) -> Result<(), String> {
    let conn = state.db.lock().map_err(|e| format!("锁失败: {e}"))?;
    conn.execute(
        "INSERT INTO app_config(key, value, updated_at)
             VALUES (?1, ?2, datetime('now','localtime'))
         ON CONFLICT(key) DO UPDATE SET
             value = excluded.value,
             updated_at = excluded.updated_at",
        rusqlite::params![key, value],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}
