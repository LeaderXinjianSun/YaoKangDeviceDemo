mod db;

use std::sync::Mutex;

use rusqlite::Connection;
use tauri::Manager;

/// 全局共享状态。P0 只有 SQLite 连接；
/// P1 起在此加入 PLC 连接监督器（Arc<tokio::runtime::...> 等）。
pub struct AppState {
    db: Mutex<Connection>,
}

#[tauri::command]
fn ping() -> String {
    "pong".into()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            let conn = db::open_app_db(app.handle())?;
            db::seed_defaults(&conn)?;
            app.manage(AppState {
                db: Mutex::new(conn),
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            ping,
            db::config_get_all,
            db::config_set,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
