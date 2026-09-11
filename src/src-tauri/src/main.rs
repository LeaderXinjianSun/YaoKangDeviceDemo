// 桌面端入口：不写业务逻辑，全部走 lib（移动端也可复用）
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    ldr_plc_desktop_lib::run()
}
