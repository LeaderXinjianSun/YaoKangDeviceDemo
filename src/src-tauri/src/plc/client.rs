//! PLC 长连接监督器：
//! - 开机按 SQLite 参数自动连接，TCP/回读异常判离线，指数退避自动重连，手动断开才停；
//! - 连接成功后常驻心跳任务：每 100ms 用功能码 06 向 D210 写新随机 u16，并周期回读判停；
//! - 订阅管理器：group 引用计数，telemetry 组周期读 D200~D207，退订即停；
//! - 所有报文共用一条 TCP 长连接与一把异步锁（tokio-modbus 的 Context 为 &mut self，
//!   编译期即要求串行），心跳用 try_lock 实现"优先级最低、忙则跳过"。

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Emitter};
use tokio::sync::{Mutex, Notify};
use tokio::time::{interval, timeout, MissedTickBehavior};
use rand::Rng;
use tokio_modbus::client::{tcp, Context};
use tokio_modbus::prelude::*;
use tokio_modbus::Slave;

use super::address::PlcMap;
use super::codec::{decode_real, ByteOrder};

/// 事件名
const EV_STATUS: &str = "plc::status";
const EV_TELEMETRY: &str = "plc::telemetry";

/// telemetry 组：D200~D207 四个 REAL（胸背/臀腿/臀盘/电推杆）
const TELEMETRY_D: u16 = 200;
const TELEMETRY_CNT: u16 = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum StatusKind {
    Connecting,
    Online,
    Reconnecting,
    Offline,
}

impl StatusKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Connecting => "connecting",
            Self::Online => "online",
            Self::Reconnecting => "reconnecting",
            Self::Offline => "offline",
        }
    }
}

/// telemetry 事件载荷（前端 camelCase）
#[derive(Debug, Clone, Serialize)]
pub(crate) struct Telemetry {
    #[serde(rename = "chestBack")]
    chest_back: f32,
    #[serde(rename = "hipLeg")]
    hip_leg: f32,
    #[serde(rename = "hipDisc")]
    hip_disc: f32,
    pushrod: f32,
}

/// 来自 app_config 的连接/时序参数
#[derive(Debug, Clone)]
pub(crate) struct PlcConfig {
    ip: String,
    port: u16,
    unit_id: u8,
    heartbeat_reg: u16,
    heartbeat_ms: u64,
    watchdog_read_ms: u64,
    watchdog_fails: u32,
    conn_timeout_ms: u64,
    io_timeout_ms: u64,
    read_interval_ms: u64,
    backoff_ms: Vec<u64>,
    byte_order: ByteOrder,
    map: PlcMap,
}

impl PlcConfig {
    pub(crate) fn from_map(m: &HashMap<String, String>) -> Self {
        fn get<'a>(m: &'a HashMap<String, String>, k: &str, d: &'a str) -> &'a str {
            m.get(k).map(String::as_str).unwrap_or(d)
        }
        // 键缺失或值非法时一律回落到默认值（get 返回 ""，parse 必然失败）
        let num = |k: &str, d: u64| get(m, k, "").parse().unwrap_or(d);
        let backoff_ms = get(m, "reconnect_backoff_ms", "1000,2000,5000,10000")
            .split(',')
            .filter_map(|s| s.trim().parse::<u64>().ok())
            .collect::<Vec<_>>();
        Self {
            ip: get(m, "plc_ip", "192.168.1.88").to_string(),
            port: num("plc_port", 502) as u16,
            unit_id: num("modbus_unit_id", 1) as u8,
            heartbeat_reg: num("heartbeat_reg", 210) as u16,
            heartbeat_ms: num("heartbeat_ms", 100).max(10),
            watchdog_read_ms: num("watchdog_read_ms", 1000).max(100),
            watchdog_fails: num("watchdog_fails", 3) as u32,
            conn_timeout_ms: num("conn_timeout_ms", 3000).max(100),
            io_timeout_ms: num("io_timeout_ms", 1000).max(50),
            read_interval_ms: num("read_interval_ms", 500).max(100),
            backoff_ms: if backoff_ms.is_empty() {
                vec![1000, 2000, 5000, 10000]
            } else {
                backoff_ms
            },
            byte_order: ByteOrder::parse(get(m, "real_byte_order", "CDAB")),
            map: PlcMap {
                d_base: num("d_base", 0) as u16,
                m_base: num("m_base", 0) as u16,
            },
        }
    }
}

/// 一个订阅组的引用计数与停止信号
struct Subscription {
    count: u32,
    stop: Arc<Notify>,
}

struct Inner {
    /// 唯一长连接；None = 当前未连接。重连期为 None，命令立即返回错误不等待
    conn: Mutex<Option<Context>>,
    status: Mutex<StatusKind>,
    config: Mutex<PlcConfig>,
    /// 用户手动断开后置位，监督器不再自动重连；手动连接/重启后清除
    manual_stop: AtomicBool,
    /// 至少成功连上过一次（用于区分首连 connecting 与断线 reconnecting）
    ever_online: AtomicBool,
    /// 监督器睡眠/等待的唤醒信号：手动连接、手动断开、掉线
    wake: Notify,
    subs: Mutex<HashMap<String, Subscription>>,
}

#[derive(Clone)]
pub(crate) struct Plc {
    app: AppHandle,
    inner: Arc<Inner>,
}

impl Plc {
    /// 构建监督器并启动后台任务（在 Tauri setup 中调用）
    pub(crate) fn start(app: AppHandle, cfg: PlcConfig, auto_connect: bool) -> Self {
        let plc = Self {
            app,
            inner: Arc::new(Inner {
                conn: Mutex::new(None),
                status: Mutex::new(if auto_connect {
                    StatusKind::Connecting
                } else {
                    StatusKind::Offline
                }),
                config: Mutex::new(cfg),
                manual_stop: AtomicBool::new(!auto_connect),
                ever_online: AtomicBool::new(false),
                wake: Notify::new(),
                subs: Mutex::new(HashMap::new()),
            }),
        };
        let supervisor = plc.clone();
        tauri::async_runtime::spawn(async move { run_supervisor(supervisor).await });
        plc
    }

    async fn config_clone(&self) -> PlcConfig {
        self.inner.config.lock().await.clone()
    }

    async fn set_status(&self, s: StatusKind) {
        *self.inner.status.lock().await = s;
        let _ = self.app.emit(EV_STATUS, s.as_str());
    }

    /// 建立一条新 TCP 连接（带连接超时）
    async fn dial(&self, cfg: &PlcConfig) -> Result<Context, String> {
        let addr = format!("{}:{}", cfg.ip, cfg.port)
            .parse::<std::net::SocketAddr>()
            .map_err(|e| format!("PLC 地址无效 {}:{}：{e}", cfg.ip, cfg.port))?;
        let stream = timeout(
            Duration::from_millis(cfg.conn_timeout_ms),
            tokio::net::TcpStream::connect(addr),
        )
        .await
        .map_err(|_| format!("连接 PLC 超时（{}ms）", cfg.conn_timeout_ms))?
        .map_err(|e| format!("连接 PLC 失败：{e}"))?;
        let _ = stream.set_nodelay(true);
        Ok(tcp::attach_slave(stream, Slave::from(cfg.unit_id)))
    }

    /// 报文 IO 异常/超时统一入口：丢弃坏连接并唤醒监督器重连
    async fn mark_downline(&self) {
        let mut conn = self.inner.conn.lock().await;
        if conn.is_none() {
            return;
        }
        conn.take();
        drop(conn);
        self.set_status(StatusKind::Reconnecting).await;
        self.inner.wake.notify_one();
    }

    /// 手动入口：以最新参数连接/立即重连
    async fn connect(&self, cfg: PlcConfig) {
        *self.inner.config.lock().await = cfg;
        self.inner.manual_stop.store(false, Ordering::SeqCst);
        // 踢掉旧连接，强制监督器用新参数重建（在线时改 IP/端口点连接即走这里）
        self.inner.conn.lock().await.take();
        self.set_status(StatusKind::Connecting).await;
        self.inner.wake.notify_one();
    }

    /// 手动入口：断开并停止自动重连
    async fn disconnect(&self) {
        self.inner.manual_stop.store(true, Ordering::SeqCst);
        self.inner.conn.lock().await.take();
        self.set_status(StatusKind::Offline).await;
        self.inner.wake.notify_one();
    }

    async fn subscribe(&self, group: &str) -> Result<(), String> {
        if group != "telemetry" {
            return Err(format!("未知订阅组：{group}"));
        }
        let mut subs = self.inner.subs.lock().await;
        if let Some(s) = subs.get_mut(group) {
            s.count += 1;
            return Ok(());
        }
        let stop = Arc::new(Notify::new());
        subs.insert(
            group.to_string(),
            Subscription {
                count: 1,
                stop: stop.clone(),
            },
        );
        let plc = self.clone();
        tauri::async_runtime::spawn(async move { telemetry_task(plc, stop).await });
        Ok(())
    }

    async fn unsubscribe(&self, group: &str) {
        let mut subs = self.inner.subs.lock().await;
        if let Some(s) = subs.get_mut(group) {
            s.count = s.count.saturating_sub(1);
            if s.count == 0 {
                if let Some(s) = subs.remove(group) {
                    s.stop.notify_waiters();
                }
            }
        }
    }

    async fn status(&self) -> StatusKind {
        *self.inner.status.lock().await
    }

    /// 重读参数（不影响现有连接）；新订阅任务启动时会取到最新字节序/读取周期
    async fn reload_config(&self, cfg: PlcConfig) {
        *self.inner.config.lock().await = cfg;
    }
}

/// 连接监督器：连接 → 失败退避重连 / 成功后等掉线或手动操作
async fn run_supervisor(plc: Plc) {
    let mut fails = 0u32;
    loop {
        if plc.inner.manual_stop.load(Ordering::SeqCst) {
            // 手动断开：安静等待下一次手动连接
            plc.inner.wake.notified().await;
            continue;
        }

        let cfg = plc.config_clone().await;

        // 连接仍在（被多余唤醒）：继续在线等待
        if plc.inner.conn.lock().await.is_some() {
            plc.inner.wake.notified().await;
            continue;
        }

        let first = !plc.inner.ever_online.load(Ordering::SeqCst);
        plc.set_status(if first {
            StatusKind::Connecting
        } else {
            StatusKind::Reconnecting
        })
        .await;

        match plc.dial(&cfg).await {
            Ok(ctx) => {
                *plc.inner.conn.lock().await = Some(ctx);
                fails = 0;
                plc.inner.ever_online.store(true, Ordering::SeqCst);
                plc.set_status(StatusKind::Online).await;
                let heartbeat = plc.clone();
                tauri::async_runtime::spawn(async move { heartbeat_task(heartbeat).await });
            }
            Err(_) => {
                // 退避等待；手动连接可提前打断
                let delay =
                    cfg.backoff_ms[(fails as usize).min(cfg.backoff_ms.len() - 1)];
                fails = fails.saturating_add(1);
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_millis(delay)) => {}
                    _ = plc.inner.wake.notified() => {}
                }
                continue;
            }
        }

        // 在线：掉线（心跳/读任务 mark_downline）或手动操作时被唤醒
        plc.inner.wake.notified().await;
    }
}

/// 心跳任务：连接的整个生命周期内运行，连接失效即退出（监督器重连后会重新拉起）
async fn heartbeat_task(plc: Plc) {
    let cfg = plc.config_clone().await;
    let reg = cfg.map.d_reg(cfg.heartbeat_reg);
    let io = Duration::from_millis(cfg.io_timeout_ms);
    let read_every = (cfg.watchdog_read_ms / cfg.heartbeat_ms).max(1);
    let mut ticks = 0u64;
    let mut read_fails = 0u32;

    let mut ticker = interval(Duration::from_millis(cfg.heartbeat_ms));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);

    loop {
        ticker.tick().await;
        ticks += 1;

        // 心跳优先级最低：锁被业务占用则跳过本拍，绝不排队阻塞业务
        let mut guard = match plc.inner.conn.try_lock() {
            Ok(g) => g,
            Err(_) => continue,
        };
        let Some(ctx) = guard.as_mut() else { return };

        let value = rand::thread_rng().gen::<u16>();
        // tokio-modbus 为三层结果：timeout / 传输错误 / Modbus 异常
        let write = timeout(io, ctx.write_single_register(reg, value)).await;
        // 传输错误或超时：连接已不可信，立即判停；Modbus 异常响应按本拍失败计数
        let write_io_bad = matches!(write, Err(_) | Ok(Err(_)));
        let write_bad = !matches!(write, Ok(Ok(Ok(()))));

        // 回读：每 read_every 拍一次，值应等于本拍写入值
        let mut read_bad_io = false;
        let mut read_mismatch = false;
        if !write_bad && ticks % read_every == 0 {
            match timeout(io, ctx.read_holding_registers(reg, 1)).await {
                Ok(Ok(Ok(v))) if v.len() == 1 && v[0] == value => {}
                // Modbus 异常或值不符：本拍回读失败
                Ok(Ok(Ok(_))) | Ok(Ok(Err(_))) => read_mismatch = true,
                // 超时/IO 错误：连接已不可信，必须重建（否则下次报文会读到本次残留响应）
                _ => read_bad_io = true,
            }
        }
        drop(guard);

        if write_io_bad || read_bad_io {
            // 通道①：TCP 报错/超时，立即判离线
            plc.mark_downline().await;
            return;
        }
        if write_bad || read_mismatch {
            // 通道②：Modbus 异常/回读值不符，连续 N 拍判离线
            read_fails += 1;
            if read_fails >= cfg.watchdog_fails {
                plc.mark_downline().await;
                return;
            }
        } else {
            read_fails = 0;
        }
    }
}

/// telemetry 订阅任务：周期读 D200~D207 并发 plc::telemetry 事件；
/// 离线时空转，重连后自动恢复，退订时由 stop 信号终止
async fn telemetry_task(plc: Plc, stop: Arc<Notify>) {
    let cfg = plc.config_clone().await;
    let addr = cfg.map.d_reg(TELEMETRY_D);
    let io = Duration::from_millis(cfg.io_timeout_ms);
    let order = cfg.byte_order;

    let mut ticker = interval(Duration::from_millis(cfg.read_interval_ms));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);

    loop {
        tokio::select! {
            _ = ticker.tick() => {}
            _ = stop.notified() => return,
        }

        let mut guard = plc.inner.conn.lock().await;
        let Some(ctx) = guard.as_mut() else { continue };
        let result = timeout(io, ctx.read_holding_registers(addr, TELEMETRY_CNT)).await;
        drop(guard);

        match result {
            Ok(Ok(Ok(regs))) if regs.len() >= TELEMETRY_CNT as usize => {
                let real = |i: usize| decode_real([regs[i], regs[i + 1]], order);
                let t = Telemetry {
                    chest_back: real(0),
                    hip_leg: real(2),
                    hip_disc: real(4),
                    pushrod: real(6),
                };
                let _ = plc.app.emit(EV_TELEMETRY, t);
            }
            // Modbus 异常/异常长度：忽略本拍
            Ok(Ok(Ok(_))) | Ok(Ok(Err(_))) => {}
            // 超时/IO 错误：判离线由监督器重连，本任务继续存活待恢复
            _ => plc.mark_downline().await,
        }
    }
}

// ---------- Tauri 命令 ----------

/// 手动连接/重连：先把参数页保存的 SQLite 配置重读为最新参数
#[tauri::command]
pub(crate) async fn plc_connect(
    state: tauri::State<'_, crate::AppState>,
) -> Result<(), String> {
    let db = state.db.clone();
    let map = tauri::async_runtime::spawn_blocking(move || {
        let conn = db.lock().map_err(|e| format!("锁失败: {e}"))?;
        crate::db::config_map(&conn)
    })
    .await
    .map_err(|e| format!("配置读取任务失败: {e}"))??;
    state
        .plc
        .connect(PlcConfig::from_map(&map))
        .await;
    Ok(())
}

#[tauri::command]
pub(crate) async fn plc_disconnect(state: tauri::State<'_, crate::AppState>) -> Result<(), String> {
    state.plc.disconnect().await;
    Ok(())
}

#[tauri::command]
pub(crate) async fn plc_subscribe(
    state: tauri::State<'_, crate::AppState>,
    group: String,
) -> Result<(), String> {
    // 订阅前刷新参数快照，使参数页保存的字节序/读取周期在重进页面时生效
    let db = state.db.clone();
    let map = tauri::async_runtime::spawn_blocking(move || {
        let conn = db.lock().map_err(|e| format!("锁失败: {e}"))?;
        crate::db::config_map(&conn)
    })
    .await
    .map_err(|e| format!("配置读取任务失败: {e}"))??;
    state.plc.reload_config(PlcConfig::from_map(&map)).await;
    state.plc.subscribe(&group).await
}

#[tauri::command]
pub(crate) async fn plc_unsubscribe(
    state: tauri::State<'_, crate::AppState>,
    group: String,
) -> Result<(), String> {
    state.plc.unsubscribe(&group).await;
    Ok(())
}

#[tauri::command]
pub(crate) async fn plc_status(
    state: tauri::State<'_, crate::AppState>,
) -> Result<String, String> {
    Ok(state.plc.status().await.as_str().to_string())
}
