mod db;
mod plc;

use std::sync::{Arc, Mutex};

use rusqlite::Connection;
use tauri::Manager;

use plc::{Plc, PlcConfig};

/// 全局共享状态：
/// - db：rusqlite 为同步阻塞接口，包 Arc 以便异步命令在 spawn_blocking 中使用；
/// - plc：P1 长连接监督器（内部全异步，本身 Clone 廉价）。
pub struct AppState {
    db: Arc<Mutex<Connection>>,
    plc: Plc,
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
            let cfg_map = db::config_map(&conn)?;
            let auto_connect = cfg_map
                .get("auto_connect")
                .map(|v| v == "true")
                .unwrap_or(true);
            let plc = Plc::start(app.handle().clone(), PlcConfig::from_map(&cfg_map), auto_connect);
            app.manage(AppState {
                db: Arc::new(Mutex::new(conn)),
                plc,
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            ping,
            db::config_get_all,
            db::config_set,
            plc::client::plc_connect,
            plc::client::plc_disconnect,
            plc::client::plc_subscribe,
            plc::client::plc_unsubscribe,
            plc::client::plc_status,
            plc::client::axis_read,
            plc::client::coil_set,
            plc::client::coil_pulse,
            plc::client::coil_toggle,
            plc::client::write_real,
            plc::client::coil_clear_all,
            plc::client::array_upload,
            plc::client::array_download,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
