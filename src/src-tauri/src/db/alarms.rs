//! P6 报警/操作提示的 SQLite 存取：
//! - alarm_state：各报警点最新电平（应用关闭前/电平变化时保存），重启作为边沿检测基线；
//! - alarm_log：上升沿 raised / 下降沿 cleared 历史，诊断页按时段倒序查询。
//!
//! 所有函数为同步 rusqlite 操作，由常驻任务在 spawn_blocking 中调用，不阻塞异步运行时。

use std::collections::HashMap;

use rusqlite::{params, Connection};
use serde::Serialize;

/// 一次电平跳变（0→1 raised / 1→0 cleared）
pub(crate) struct Edge {
    pub addr: u16,
    pub name: String,
    pub raised: bool,
}

/// alarm_log 查询结果（前端 camelCase）
#[derive(Debug, Serialize)]
pub struct AlarmLogEntry {
    pub id: i64,
    pub addr: i64,
    pub name: String,
    /// raised=报警发生 / cleared=报警解除
    pub kind: String,
    pub ts: String,
}

/// 加载报警基线：addr -> on（重启后作为上一拍电平，避免重复记录上升沿）
pub(crate) fn load_baseline(conn: &Connection) -> Result<HashMap<u16, bool>, String> {
    let mut stmt = conn
        .prepare("SELECT addr, is_on FROM alarm_state")
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |r| {
            Ok((r.get::<_, i64>(0)? as u16, r.get::<_, i64>(1)? != 0))
        })
        .map_err(|e| e.to_string())?;
    let mut map = HashMap::new();
    for row in rows {
        let (addr, on) = row.map_err(|e| e.to_string())?;
        map.insert(addr, on);
    }
    Ok(map)
}

/// 持久化一拍结果：edges 追加 alarm_log，states 全部 upsert 进 alarm_state（同一事务）
pub(crate) fn persist_poll(
    conn: &Connection,
    edges: &[Edge],
    states: &[(u16, bool)],
) -> Result<(), String> {
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    for e in edges {
        tx.execute(
            "INSERT INTO alarm_log(addr, name, kind) VALUES (?1, ?2, ?3)",
            params![
                e.addr,
                e.name,
                if e.raised { "raised" } else { "cleared" }
            ],
        )
        .map_err(|err| err.to_string())?;
    }
    for (addr, on) in states {
        tx.execute(
            "INSERT INTO alarm_state(addr, is_on, updated_at)
             VALUES (?1, ?2, datetime('now','localtime'))
             ON CONFLICT(addr) DO UPDATE SET
                 is_on = excluded.is_on,
                 updated_at = excluded.updated_at",
            params![addr, *on as i64],
        )
        .map_err(|e| e.to_string())?;
    }
    tx.commit().map_err(|e| e.to_string())?;
    Ok(())
}

/// 按时段倒序查询报警记录；begin/end 为 "YYYY-MM-DD HH:MM:SS"，None 表示该端不限
pub fn logs(
    conn: &Connection,
    begin: Option<String>,
    end: Option<String>,
    limit: u32,
) -> Result<Vec<AlarmLogEntry>, String> {
    let mut sql = String::from(
        "SELECT id, addr, name, kind, ts FROM alarm_log WHERE 1=1",
    );
    if begin.is_some() {
        sql.push_str(" AND ts >= ?1");
    }
    if end.is_some() {
        sql.push_str(" AND ts <= ?2");
    }
    sql.push_str(" ORDER BY ts DESC, id DESC LIMIT ?3");

    let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
    let entries = stmt
        .query_map(params![begin, end, limit], |r| {
            Ok(AlarmLogEntry {
                id: r.get(0)?,
                addr: r.get(1)?,
                name: r.get(2)?,
                kind: r.get(3)?,
                ts: r.get(4)?,
            })
        })
        .map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for e in entries {
        out.push(e.map_err(|e| e.to_string())?);
    }
    Ok(out)
}

// ---------- Tauri 命令（spawn_blocking 包装同步 rusqlite） ----------

macro_rules! db_cmd {
    ($state:expr, $body:expr) => {{
        let db = $state.db.clone();
        tauri::async_runtime::spawn_blocking(move || {
            let conn = db.lock().map_err(|e| format!("锁失败: {e}"))?;
            $body(&conn)
        })
        .await
        .map_err(|e| format!("数据库任务失败: {e}"))?
    }};
}

/// 报警记录时段查询（诊断页）：begin/end 为本地时间字符串，可只传其一或都不传
#[tauri::command]
pub async fn alarm_logs(
    state: tauri::State<'_, crate::AppState>,
    begin: Option<String>,
    end: Option<String>,
    limit: Option<u32>,
) -> Result<Vec<AlarmLogEntry>, String> {
    let n = limit.unwrap_or(500).clamp(1, 2000);
    db_cmd!(state, |c: &Connection| logs(c, begin, end, n))
}
