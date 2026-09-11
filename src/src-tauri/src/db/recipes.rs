//! P5 运动数组配方与下发记录的 SQLite 存取（move_array / move_step / download_log）。
//!
//! 所有函数为同步 rusqlite 操作，由 Tauri 命令在 spawn_blocking 中调用，不阻塞 UI。
//! rows 的列顺序与 plc::arrays::SEGMENTS 一致（13 列）。

use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};

use crate::plc::arrays;

/// 配方（含全部步数据），用于"按 id 载入"
#[derive(Debug, Serialize)]
pub struct Recipe {
    pub id: i64,
    pub name: String,
    pub depth: u16,
    pub mode: u16,
    pub remark: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    /// rows[步][列]，13 列顺序同 arrays::SEGMENTS
    pub rows: Vec<Vec<f64>>,
}

/// 配方列表项（不含步数据，列表轻量）
#[derive(Debug, Serialize)]
pub struct RecipeMeta {
    pub id: i64,
    pub name: String,
    pub depth: u16,
    pub mode: u16,
    pub remark: Option<String>,
    pub updated_at: String,
}

/// 保存/新建配方入参；id 为 None 时新建，为 Some 时整体覆盖更新
#[derive(Debug, Deserialize)]
pub struct RecipeSaveReq {
    pub id: Option<i64>,
    pub name: String,
    pub depth: u16,
    pub mode: u16,
    pub remark: Option<String>,
    pub rows: Vec<Vec<f64>>,
}

/// 下发记录
#[derive(Debug, Serialize)]
pub struct DownloadLogEntry {
    pub id: i64,
    /// 下发时关联的配方；直接编辑表格下发（未存配方）时为 None
    pub array_id: Option<i64>,
    pub ts: String,
    pub ok: bool,
    pub detail: Option<String>,
}

/// 名称唯一性冲突时给出友好提示
fn friendly(e: rusqlite::Error) -> String {
    if let Some(rusqlite::ErrorCode::ConstraintViolation) = e.sqlite_error_code() {
        "配方名已存在，请换一个名称".to_string()
    } else {
        e.to_string()
    }
}

/// 写入/覆盖某配方的全部 move_step（调用方须已开启事务）
fn replace_steps(tx: &Connection, array_id: i64, rows: &[Vec<f64>]) -> Result<(), String> {
    tx.execute("DELETE FROM move_step WHERE array_id = ?1", params![array_id])
        .map_err(|e| e.to_string())?;
    {
        let mut stmt = tx
            .prepare(
                "INSERT INTO move_step
                   (array_id, step_no,
                    chest_pos, leg_pos, seat_pos,
                    chest_vel, leg_vel, seat_vel,
                    chest_acc, leg_acc, seat_acc,
                    chest_dec, leg_dec, seat_dec,
                    interval_ms)
                 VALUES (?1,?2, ?3,?4,?5, ?6,?7,?8, ?9,?10,?11, ?12,?13,?14, ?15)",
            )
            .map_err(|e| e.to_string())?;
        for (i, row) in rows.iter().enumerate() {
            let interval = row[12].round() as i64;
            stmt.execute(params![
                array_id,
                (i + 1) as i64,
                row[0], row[1], row[2],
                row[3], row[4], row[5],
                row[6], row[7], row[8],
                row[9], row[10], row[11],
                interval,
            ])
            .map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

/// 读出某配方全部步数据
fn load_steps(conn: &Connection, array_id: i64, depth: usize) -> Result<Vec<Vec<f64>>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT chest_pos, leg_pos, seat_pos,
                    chest_vel, leg_vel, seat_vel,
                    chest_acc, leg_acc, seat_acc,
                    chest_dec, leg_dec, seat_dec,
                    interval_ms
             FROM move_step WHERE array_id = ?1 ORDER BY step_no",
        )
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(params![array_id], |r| {
            Ok(vec![
                r.get::<_, f64>(0)?,
                r.get::<_, f64>(1)?,
                r.get::<_, f64>(2)?,
                r.get::<_, f64>(3)?,
                r.get::<_, f64>(4)?,
                r.get::<_, f64>(5)?,
                r.get::<_, f64>(6)?,
                r.get::<_, f64>(7)?,
                r.get::<_, f64>(8)?,
                r.get::<_, f64>(9)?,
                r.get::<_, f64>(10)?,
                r.get::<_, f64>(11)?,
                r.get::<_, i64>(12)? as f64,
            ])
        })
        .map_err(|e| e.to_string())?;
    let mut out = Vec::with_capacity(depth);
    for row in rows {
        out.push(row.map_err(|e| e.to_string())?);
    }
    if out.len() != depth {
        return Err(format!("配方步数 {} 与深度 {depth} 不一致", out.len()));
    }
    Ok(out)
}

/// 新建或整体覆盖保存配方，返回配方 id
pub fn save(conn: &Connection, req: RecipeSaveReq) -> Result<i64, String> {
    arrays::validate(req.depth, req.mode, &req.rows)?;
    let name = req.name.trim();
    if name.is_empty() {
        return Err("配方名称不能为空".into());
    }

    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    let id = match req.id {
        Some(id) => {
            let n = tx
                .execute(
                    "UPDATE move_array
                        SET name=?1, depth=?2, mode=?3, remark=?4,
                            updated_at=datetime('now','localtime')
                      WHERE id=?5",
                    params![name, req.depth, req.mode, req.remark, id],
                )
                .map_err(friendly)?;
            if n == 0 {
                return Err(format!("配方 id={id} 不存在"));
            }
            id
        }
        None => {
            tx.execute(
                "INSERT INTO move_array(name, depth, mode, remark)
                 VALUES (?1, ?2, ?3, ?4)",
                params![name, req.depth, req.mode, req.remark],
            )
            .map_err(friendly)?;
            tx.last_insert_rowid()
        }
    };
    replace_steps(&tx, id, &req.rows)?;
    tx.commit().map_err(|e| e.to_string())?;
    Ok(id)
}

/// 配方列表（不含步数据），按更新时间倒序
pub fn list(conn: &Connection) -> Result<Vec<RecipeMeta>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT id, name, depth, mode, remark, updated_at
             FROM move_array ORDER BY updated_at DESC, id DESC",
        )
        .map_err(|e| e.to_string())?;
    let metas = stmt
        .query_map([], |r| {
            Ok(RecipeMeta {
                id: r.get(0)?,
                name: r.get(1)?,
                depth: r.get(2)?,
                mode: r.get(3)?,
                remark: r.get(4)?,
                updated_at: r.get(5)?,
            })
        })
        .map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for m in metas {
        out.push(m.map_err(|e| e.to_string())?);
    }
    Ok(out)
}

/// 按 id 载入配方（含全部步数据）
pub fn get(conn: &Connection, id: i64) -> Result<Recipe, String> {
    let mut stmt = conn
        .prepare(
            "SELECT id, name, depth, mode, remark, created_at, updated_at
             FROM move_array WHERE id = ?1",
        )
        .map_err(|e| e.to_string())?;
    let mut recipe = stmt
        .query_row(params![id], |r| {
            let depth: u16 = r.get(2)?;
            Ok(Recipe {
                id: r.get(0)?,
                name: r.get(1)?,
                depth,
                mode: r.get(3)?,
                remark: r.get(4)?,
                created_at: r.get(5)?,
                updated_at: r.get(6)?,
                rows: Vec::new(),
            })
        })
        .map_err(|e| format!("读取配方失败: {e}"))?;
    recipe.rows = load_steps(conn, id, recipe.depth as usize)?;
    Ok(recipe)
}

/// 删除配方（move_step 经外键级联删除）
pub fn delete(conn: &Connection, id: i64) -> Result<(), String> {
    conn.execute("DELETE FROM move_array WHERE id = ?1", params![id])
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// 克隆配方：复制头与全部步到新名称，返回新 id
pub fn clone(conn: &Connection, id: i64, new_name: String) -> Result<i64, String> {
    let src = get(conn, id)?;
    let new_name = new_name.trim();
    if new_name.is_empty() {
        return Err("配方名称不能为空".into());
    }
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    tx.execute(
        "INSERT INTO move_array(name, depth, mode, remark)
         VALUES (?1, ?2, ?3, ?4)",
        params![new_name, src.depth, src.mode, src.remark],
    )
    .map_err(friendly)?;
    let new_id = tx.last_insert_rowid();
    replace_steps(&tx, new_id, &src.rows)?;
    tx.commit().map_err(|e| e.to_string())?;
    Ok(new_id)
}

/// 追加一条下发记录（array_id 可为空：未存配方直接编辑下发）
pub fn insert_log(
    conn: &Connection,
    array_id: Option<i64>,
    ok: bool,
    detail: Option<String>,
) -> Result<(), String> {
    conn.execute(
        "INSERT INTO download_log(array_id, ok, detail) VALUES (?1, ?2, ?3)",
        params![array_id, ok as i64, detail],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

/// 查询最近 limit 条下发记录（倒序）
pub fn logs(conn: &Connection, limit: u32) -> Result<Vec<DownloadLogEntry>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT id, array_id, ts, ok, detail FROM download_log
             ORDER BY id DESC LIMIT ?1",
        )
        .map_err(|e| e.to_string())?;
    let entries = stmt
        .query_map(params![limit], |r| {
            Ok(DownloadLogEntry {
                id: r.get(0)?,
                array_id: r.get(1)?,
                ts: r.get(2)?,
                ok: r.get::<_, i64>(3)? != 0,
                detail: r.get(4)?,
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

#[tauri::command]
pub async fn recipe_save(
    state: tauri::State<'_, crate::AppState>,
    req: RecipeSaveReq,
) -> Result<i64, String> {
    db_cmd!(state, |c: &Connection| save(c, req))
}

#[tauri::command]
pub async fn recipe_list(
    state: tauri::State<'_, crate::AppState>,
) -> Result<Vec<RecipeMeta>, String> {
    db_cmd!(state, |c: &Connection| list(c))
}

#[tauri::command]
pub async fn recipe_get(
    state: tauri::State<'_, crate::AppState>,
    id: i64,
) -> Result<Recipe, String> {
    db_cmd!(state, |c: &Connection| get(c, id))
}

#[tauri::command]
pub async fn recipe_delete(
    state: tauri::State<'_, crate::AppState>,
    id: i64,
) -> Result<(), String> {
    db_cmd!(state, |c: &Connection| delete(c, id))
}

#[tauri::command]
pub async fn recipe_clone(
    state: tauri::State<'_, crate::AppState>,
    id: i64,
    new_name: String,
) -> Result<i64, String> {
    db_cmd!(state, |c: &Connection| clone(c, id, new_name))
}

#[tauri::command]
pub async fn recipe_logs(
    state: tauri::State<'_, crate::AppState>,
    limit: Option<u32>,
) -> Result<Vec<DownloadLogEntry>, String> {
    let n = limit.unwrap_or(100).clamp(1, 500);
    db_cmd!(state, |c: &Connection| logs(c, n))
}

/// 供 array_upload 命令在下发后记录日志（同步函数，已处于命令上下文）
pub fn log_from_command(
    conn: &Connection,
    array_id: Option<i64>,
    ok: bool,
    detail: Option<String>,
) -> Result<(), String> {
    insert_log(conn, array_id, ok, detail)
}
