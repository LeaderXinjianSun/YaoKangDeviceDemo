//! PLC 长连接监督器：
//! - 开机按 SQLite 参数自动连接，TCP/回读异常判离线，指数退避自动重连，手动断开才停；
//! - 连接成功后常驻心跳任务：每 100ms 用功能码 06 向 D210 写新随机 u16，并周期回读判停；
//! - 订阅管理器：group 引用计数，telemetry 组周期读 D200~D207，退订即停；
//! - 所有报文共用一条 TCP 长连接与一把异步锁（tokio-modbus 的 Context 为 &mut self，
//!   编译期即要求串行），心跳用 try_lock 实现"优先级最低、忙则跳过"；
//! - P6：连接成功后常驻报警监视任务，一次读 M300~M401 + D400，边沿落 SQLite 并推事件。

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager};
use tokio::sync::{Mutex, Notify};
use tokio::time::{interval, timeout, MissedTickBehavior};
use rand::Rng;
use tokio_modbus::client::{tcp, Context};
use tokio_modbus::prelude::*;
use tokio_modbus::Slave;

use super::address::PlcMap;
use super::alarms::{
    AlarmItem, AlarmSnapshot, ALARM_POINTS, FAULT_CNT, FAULT_D, PROMPT_POINTS, STEP_D,
    WATCH_M_CNT, WATCH_M_START,
};
use super::arrays;
use super::codec::{decode_dint, decode_real, encode_dint, encode_real, ByteOrder};
use crate::db::alarms::Edge;

/// 事件名
const EV_STATUS: &str = "plc::status";
const EV_TELEMETRY: &str = "plc::telemetry";
/// 全局状态机 D220（HMI_GL_STEP，INT16）周期事件
const EV_GL_STEP: &str = "plc::gl_step";
/// P6：全部报警点电平（变化时/重连首拍）、最高地址 TRUE 提示（变化时）、D400 动作步
const EV_ALARM_STATE: &str = "plc::alarm_state";
const EV_PROMPT: &str = "plc::prompt";
const EV_STEP_INDEX: &str = "plc::step_index";

/// telemetry 组：D200~D207 四个 REAL（胸背/臀腿/臀盘/电推杆）
const TELEMETRY_D: u16 = 200;
const TELEMETRY_CNT: u16 = 8;

/// glstep 组：D220 全局状态机单个 INT16（-1 急停/0 复位/1 调试/2 运行）
const GL_STEP_D: u16 = 220;

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
    /// P6 报警/提示常驻轮询周期；配置缺失时由 from_map 回退 read_interval_ms
    alarm_interval_ms: u64,
    backoff_ms: Vec<u64>,
    byte_order: ByteOrder,
    /// Inc/Abs/停止等上升沿命令线圈的短脉冲宽度
    cmd_pulse_ms: u64,
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
            // alarm_interval_ms 单独配置；未配置/非法（0）时回退 read_interval_ms
            alarm_interval_ms: {
                let v = get(m, "alarm_interval_ms", "").parse().unwrap_or(0);
                if v >= 100 { v } else { num("read_interval_ms", 500).max(100) }
            },
            backoff_ms: if backoff_ms.is_empty() {
                vec![1000, 2000, 5000, 10000]
            } else {
                backoff_ms
            },
            byte_order: ByteOrder::parse(get(m, "real_byte_order", "CDAB")),
            cmd_pulse_ms: num("cmd_pulse_ms", 200).max(20),
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
    /// 当前置位的点动脉冲线圈（M 软元件号 -> 看门狗停止信号）。
    /// 断线/手动断开时通知全部看门狗退出；记录保留以便重连后补写 OFF
    held: Mutex<HashMap<u16, Arc<Notify>>>,
    /// P6：报警监视任务最近一帧快照（alarm_current 命令首屏同步用）
    alarm_last: Mutex<AlarmSnapshot>,
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
                held: Mutex::new(HashMap::new()),
                alarm_last: Mutex::new(AlarmSnapshot::default()),
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
        // 连接已断无法写 OFF：停止看门狗计时，保留置位记录待重连后补清零
        self.freeze_held().await;
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
        // 与断线一致：看门狗退出，置位记录保留（下次连接时补清零）
        self.freeze_held().await;
        self.set_status(StatusKind::Offline).await;
        self.inner.wake.notify_one();
    }

    async fn subscribe(&self, group: &str) -> Result<(), String> {
        if group != "telemetry" && group != "glstep" {
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
        let g = group.to_string();
        tauri::async_runtime::spawn(async move {
            if g == "glstep" {
                gl_step_task(plc, stop).await;
            } else {
                telemetry_task(plc, stop).await;
            }
        });
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

    // ---------- P2：写原语（全部报文共用 conn 同一把串行锁） ----------

    /// 写单个线圈（FC05，绝对 Modbus 线圈地址）。
    /// 超时/传输错误立即判离线；Modbus 异常作为业务错误返回
    async fn write_coil_raw(&self, addr: u16, on: bool) -> Result<(), String> {
        let cfg = self.config_clone().await;
        let io = Duration::from_millis(cfg.io_timeout_ms);
        let mut guard = self.inner.conn.lock().await;
        let Some(ctx) = guard.as_mut() else {
            return Err("PLC 未连接".into());
        };
        match timeout(io, ctx.write_single_coil(addr, on)).await {
            Ok(Ok(Ok(()))) => Ok(()),
            Ok(Ok(Err(e))) => Err(format!("Modbus 写线圈失败：{e:?}")),
            Ok(Err(e)) => {
                drop(guard);
                self.mark_downline().await;
                Err(format!("写线圈传输错误：{e}"))
            }
            Err(_) => {
                drop(guard);
                self.mark_downline().await;
                Err(format!("写线圈超时（{}ms）", cfg.io_timeout_ms))
            }
        }
    }

    /// 写 REAL（FC16，两个保持寄存器，D 软元件号），字节序按配置
    async fn write_real_raw(&self, d: u16, v: f32) -> Result<(), String> {
        let cfg = self.config_clone().await;
        let addr = cfg.map.d_reg(d);
        let regs = encode_real(v, cfg.byte_order);
        let io = Duration::from_millis(cfg.io_timeout_ms);
        let mut guard = self.inner.conn.lock().await;
        let Some(ctx) = guard.as_mut() else {
            return Err("PLC 未连接".into());
        };
        match timeout(io, ctx.write_multiple_registers(addr, &regs)).await {
            Ok(Ok(Ok(()))) => Ok(()),
            Ok(Ok(Err(e))) => Err(format!("Modbus 写寄存器失败：{e:?}")),
            Ok(Err(e)) => {
                drop(guard);
                self.mark_downline().await;
                Err(format!("写寄存器传输错误：{e}"))
            }
            Err(_) => {
                drop(guard);
                self.mark_downline().await;
                Err(format!("写寄存器超时（{}ms）", cfg.io_timeout_ms))
            }
        }
    }

    /// 读 REAL（FC03，两个保持寄存器，D 软元件号），字节序按配置
    async fn read_real_raw(&self, d: u16) -> Result<f32, String> {
        let cfg = self.config_clone().await;
        let addr = cfg.map.d_reg(d);
        let io = Duration::from_millis(cfg.io_timeout_ms);
        let mut guard = self.inner.conn.lock().await;
        let Some(ctx) = guard.as_mut() else {
            return Err("PLC 未连接".into());
        };
        match timeout(io, ctx.read_holding_registers(addr, 2)).await {
            Ok(Ok(Ok(v))) if v.len() >= 2 => Ok(decode_real([v[0], v[1]], cfg.byte_order)),
            Ok(Ok(Ok(_))) => Err("读寄存器返回长度不足".into()),
            Ok(Ok(Err(e))) => Err(format!("Modbus 读寄存器失败：{e:?}")),
            Ok(Err(e)) => {
                drop(guard);
                self.mark_downline().await;
                Err(format!("读寄存器传输错误：{e}"))
            }
            Err(_) => {
                drop(guard);
                self.mark_downline().await;
                Err(format!("读寄存器超时（{}ms）", cfg.io_timeout_ms))
            }
        }
    }

    /// 读单个线圈（FC01，M 软元件号）
    async fn read_coil_m(&self, m: u16) -> Result<bool, String> {
        let cfg = self.config_clone().await;
        let addr = cfg.map.m_coil(m);
        let io = Duration::from_millis(cfg.io_timeout_ms);
        let mut guard = self.inner.conn.lock().await;
        let Some(ctx) = guard.as_mut() else {
            return Err("PLC 未连接".into());
        };
        match timeout(io, ctx.read_coils(addr, 1)).await {
            Ok(Ok(Ok(v))) => Ok(v.first().copied().ok_or("读线圈返回空")?),
            Ok(Ok(Err(e))) => Err(format!("Modbus 读线圈失败：{e:?}")),
            Ok(Err(e)) => {
                drop(guard);
                self.mark_downline().await;
                Err(format!("读线圈传输错误：{e}"))
            }
            Err(_) => {
                drop(guard);
                self.mark_downline().await;
                Err(format!("读线圈超时（{}ms）", cfg.io_timeout_ms))
            }
        }
    }

    /// 批量写保持寄存器（FC16，绝对 Modbus 地址），P4 数组下发用
    async fn write_regs_raw(&self, addr: u16, regs: &[u16]) -> Result<(), String> {
        // FC16 单帧最多写 123 个保持寄存器（PDU 253 字节 - 6 字节头），超出自动分片
        const FC16_MAX: usize = 123;
        let cfg = self.config_clone().await;
        let io = Duration::from_millis(cfg.io_timeout_ms);
        for (i, chunk) in regs.chunks(FC16_MAX).enumerate() {
            let chunk_addr = addr + (i * FC16_MAX) as u16;
            let mut guard = self.inner.conn.lock().await;
            let Some(ctx) = guard.as_mut() else {
                return Err("PLC 未连接".into());
            };
            match timeout(io, ctx.write_multiple_registers(chunk_addr, chunk)).await {
                Ok(Ok(Ok(()))) => {}
                Ok(Ok(Err(e))) => return Err(format!("Modbus 写寄存器失败：{e:?}")),
                Ok(Err(e)) => {
                    drop(guard);
                    self.mark_downline().await;
                    return Err(format!("写寄存器传输错误：{e}"));
                }
                Err(_) => {
                    drop(guard);
                    self.mark_downline().await;
                    return Err(format!("写寄存器超时（{}ms）", cfg.io_timeout_ms));
                }
            }
        }
        Ok(())
    }

    /// 批量读保持寄存器（FC03，绝对 Modbus 地址），P4 数组上读用
    async fn read_regs_raw(&self, addr: u16, cnt: u16) -> Result<Vec<u16>, String> {
        // FC03 单帧最多读 125 个保持寄存器，超出自动分片后按地址顺序拼接
        const FC03_MAX: u16 = 125;
        let cfg = self.config_clone().await;
        let io = Duration::from_millis(cfg.io_timeout_ms);
        let mut out = Vec::with_capacity(cnt as usize);
        let mut cur_addr = addr;
        let mut remain = cnt;
        while remain > 0 {
            let n = remain.min(FC03_MAX);
            let mut guard = self.inner.conn.lock().await;
            let Some(ctx) = guard.as_mut() else {
                return Err("PLC 未连接".into());
            };
            match timeout(io, ctx.read_holding_registers(cur_addr, n)).await {
                Ok(Ok(Ok(v))) if v.len() >= n as usize => {
                    out.extend_from_slice(&v[..n as usize]);
                }
                Ok(Ok(Ok(v))) => {
                    return Err(format!("读寄存器返回长度不足：{}<{n}", v.len()))
                }
                Ok(Ok(Err(e))) => return Err(format!("Modbus 读寄存器失败：{e:?}")),
                Ok(Err(e)) => {
                    drop(guard);
                    self.mark_downline().await;
                    return Err(format!("读寄存器传输错误：{e}"));
                }
                Err(_) => {
                    drop(guard);
                    self.mark_downline().await;
                    return Err(format!("读寄存器超时（{}ms）", cfg.io_timeout_ms));
                }
            }
            cur_addr += n;
            remain -= n;
        }
        Ok(out)
    }

    /// P4 运动数组下发：按段 FC16 批量写 depth 步数据，最后写 D1100 深度、D1101 模式
    async fn array_upload(
        &self,
        depth: u16,
        mode: u16,
        rows: &[Vec<f64>],
    ) -> Result<(), String> {
        arrays::validate(depth, mode, rows)?;
        let cfg = self.config_clone().await;
        let n = depth as usize;
        // 先写全部数据段
        for (col, seg) in arrays::SEGMENTS.iter().enumerate() {
            let mut regs = Vec::with_capacity(n * 2);
            for row in rows {
                let pair = match seg.kind {
                    arrays::SegKind::Real => encode_real(row[col] as f32, cfg.byte_order),
                    arrays::SegKind::Dint => {
                        encode_dint(row[col].round() as i32, cfg.byte_order)
                    }
                };
                regs.extend_from_slice(&pair);
            }
            self.write_regs_raw(cfg.map.d_reg(seg.start), &regs).await?;
        }
        // 数据写完最后再给深度与模式，PLC 以此识别一组完整下发
        let d1100 = cfg.map.d_reg(arrays::DEPTH_D);
        self.write_regs_raw(d1100, &[depth, mode]).await?;
        Ok(())
    }

    /// P4 运动数组上读：读 D1100/D1101 控制量，再按段读回 13 段 × depth 步
    async fn array_download(&self) -> Result<ArrayDump, String> {
        let cfg = self.config_clone().await;
        let head = self
            .read_regs_raw(cfg.map.d_reg(arrays::DEPTH_D), 2)
            .await?;
        let depth = head[0];
        let mode = head[1];
        if !(1..=arrays::MAX_DEPTH as u16).contains(&depth) {
            return Err(format!("PLC 数组深度 D{}={depth} 超出 1~{}，请先下发", arrays::DEPTH_D, arrays::MAX_DEPTH));
        }
        let n = depth as usize;
        let mut rows = vec![vec![0.0f64; arrays::SEGMENTS.len()]; n];
        for (col, seg) in arrays::SEGMENTS.iter().enumerate() {
            let regs = self
                .read_regs_raw(cfg.map.d_reg(seg.start), (n * 2) as u16)
                .await?;
            for step in 0..n {
                let pair = [regs[step * 2], regs[step * 2 + 1]];
                rows[step][col] = match seg.kind {
                    arrays::SegKind::Real => decode_real(pair, cfg.byte_order) as f64,
                    arrays::SegKind::Dint => decode_dint(pair, cfg.byte_order) as f64,
                };
            }
        }
        Ok(ArrayDump { depth, mode, rows })
    }

    /// 点动脉冲线圈"按 1 松 0"（参数为 M 软元件号）。
    /// on=true：写 ON 并启动看门狗；on=false：取消看门狗并写 OFF
    async fn pulse_set(&self, m: u16, on: bool) -> Result<(), String> {
        if on {
            let cfg = self.config_clone().await;
            let addr = cfg.map.m_coil(m);
            // 先确认写 ON 成功，再登记到 held（断线/切页/失焦清零、重连补 OFF）。
            // Jog 不设超时自动复位，完全由松开事件决定何时写 OFF
            self.write_coil_raw(addr, true).await?;
            if let Some(old) =
                self.inner.held.lock().await.insert(m, Arc::new(Notify::new()))
            {
                old.notify_one();
            }
            Ok(())
        } else {
            let addr = self.config_clone().await.map.m_coil(m);
            self.release_coil(m, addr).await
        }
    }

    /// 上升沿命令短脉冲（Inc/Abs/停止/模式切换，参数为 M 软元件号）：
    /// 写 ON → 保持 cmd_pulse_ms → 自动写 OFF；同样纳入 held 跟踪，
    /// 断线/切页/失焦清零与重连补写 OFF 的机制与点动完全一致
    async fn pulse_cmd(&self, m: u16) -> Result<(), String> {
        let cfg = self.config_clone().await;
        let addr = cfg.map.m_coil(m);
        let width_ms = cfg.cmd_pulse_ms;
        self.write_coil_raw(addr, true).await?;
        self.hold_coil(m, addr, width_ms).await;
        Ok(())
    }

    /// 登记一个命令脉冲线圈并启动到时自动 OFF 的任务（重复触发替换旧任务）
    async fn hold_coil(&self, m: u16, addr: u16, width_ms: u64) {
        let stop = Arc::new(Notify::new());
        // 同一线圈重复触发：替换定时任务，旧任务收到通知自行退出
        if let Some(old) = self.inner.held.lock().await.insert(m, stop.clone()) {
            old.notify_one();
        }
        let plc = self.clone();
        tauri::async_runtime::spawn(async move {
            pulse_release_task(plc, m, addr, width_ms, stop).await;
        });
    }

    /// 取消线圈的定时任务并立即写 OFF；OFF 未送达则登记冻结条目待重连补写
    async fn release_coil(&self, m: u16, addr: u16) -> Result<(), String> {
        let stop = self.inner.held.lock().await.remove(&m);
        let res = self.write_coil_raw(addr, false).await;
        if let Some(stop) = stop {
            stop.notify_one();
        }
        if res.is_err() {
            // OFF 未送达（离线/传输错误）：登记为冻结条目，重连后补写 OFF
            self.inner
                .held
                .lock()
                .await
                .entry(m)
                .or_insert_with(|| Arc::new(Notify::new()));
        }
        res
    }

    /// 取反（M 软元件号）：读—改—写全程持同一把锁，返回写后的新值
    async fn toggle_coil_m(&self, m: u16) -> Result<bool, String> {
        let cfg = self.config_clone().await;
        let addr = cfg.map.m_coil(m);
        let io = Duration::from_millis(cfg.io_timeout_ms);
        let mut guard = self.inner.conn.lock().await;
        let Some(ctx) = guard.as_mut() else {
            return Err("PLC 未连接".into());
        };
        let cur = match timeout(io, ctx.read_coils(addr, 1)).await {
            Ok(Ok(Ok(v))) => v.first().copied().ok_or("读线圈返回空")?,
            Ok(Ok(Err(e))) => return Err(format!("Modbus 读线圈失败：{e:?}")),
            Ok(Err(e)) => {
                drop(guard);
                self.mark_downline().await;
                return Err(format!("读线圈传输错误：{e}"));
            }
            Err(_) => {
                drop(guard);
                self.mark_downline().await;
                return Err(format!("读线圈超时（{}ms）", cfg.io_timeout_ms));
            }
        };
        let new = !cur;
        match timeout(io, ctx.write_single_coil(addr, new)).await {
            Ok(Ok(Ok(()))) => Ok(new),
            Ok(Ok(Err(e))) => Err(format!("Modbus 写线圈失败：{e:?}")),
            Ok(Err(e)) => {
                drop(guard);
                self.mark_downline().await;
                Err(format!("写线圈传输错误：{e}"))
            }
            Err(_) => {
                drop(guard);
                self.mark_downline().await;
                Err(format!("写线圈超时（{}ms）", cfg.io_timeout_ms))
            }
        }
    }

    /// 连接失效时调用：通知所有点动看门狗停止计时；置位记录保留待重连补清零
    async fn freeze_held(&self) {
        for stop in self.inner.held.lock().await.values() {
            stop.notify_one();
        }
    }

    /// 将所有登记置位的点动线圈写 OFF 并清空记录。
    /// 重连成功后自动调用，也供"切页/失焦一键清零"命令使用；
    /// 中途传输失败则停止，剩余记录保留给下一次重连补写
    async fn release_all_held(&self) {
        let entries: Vec<(u16, u16)> = {
            let cfg = self.config_clone().await;
            self.inner
                .held
                .lock()
                .await
                .keys()
                .map(|&m| (m, cfg.map.m_coil(m)))
                .collect()
        };
        for (m, addr) in entries {
            match self.write_coil_raw(addr, false).await {
                Ok(()) => {
                    if let Some(stop) = self.inner.held.lock().await.remove(&m) {
                        stop.notify_one();
                    }
                }
                // 已判离线：剩余条目保留，下一次重连由本方法继续补写
                Err(_) => return,
            }
        }
    }
}

/// 命令短脉冲定时回落：到时（或被新触发/断线冻结通知）后写 OFF；
/// 仅用于 Inc/Abs/停止/模式等上升沿命令，Jog 不启用
async fn pulse_release_task(plc: Plc, m: u16, addr: u16, wd_ms: u64, stop: Arc<Notify>) {
    tokio::select! {
        _ = tokio::time::sleep(Duration::from_millis(wd_ms)) => {}
        _ = stop.notified() => return,
    }
    match plc.write_coil_raw(addr, false).await {
        Ok(()) => {
            // 仅当登记的仍是本任务时注销（期间可能已被新按下替换）
            let mut held = plc.inner.held.lock().await;
            if held.get(&m).map_or(false, |n| Arc::ptr_eq(n, &stop)) {
                held.remove(&m);
            }
        }
        // OFF 未送达：mark_downline 的 freeze_held 已保留条目，重连后补清零
        Err(_) => {}
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
                // 断线/手动断开期间被置位的点动线圈，重连后第一时间补写 OFF
                plc.release_all_held().await;
                let heartbeat = plc.clone();
                tauri::async_runtime::spawn(async move { heartbeat_task(heartbeat).await });
                // P6：报警/提示/D400 常驻监视与心跳同生命周期，连接失效即退出、重连重新拉起
                let watcher = plc.clone();
                tauri::async_runtime::spawn(async move { alarm_watch_task(watcher).await });
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

/// glstep 订阅任务：周期读 D220 全局状态机（INT16）并发 plc::gl_step 事件；
/// 离线时空转，重连后自动恢复，退订时由 stop 信号终止
async fn gl_step_task(plc: Plc, stop: Arc<Notify>) {
    let cfg = plc.config_clone().await;
    let addr = cfg.map.d_reg(GL_STEP_D);
    let io = Duration::from_millis(cfg.io_timeout_ms);

    let mut ticker = interval(Duration::from_millis(cfg.read_interval_ms));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);

    loop {
        tokio::select! {
            _ = ticker.tick() => {}
            _ = stop.notified() => return,
        }

        let mut guard = plc.inner.conn.lock().await;
        let Some(ctx) = guard.as_mut() else { continue };
        let result = timeout(io, ctx.read_holding_registers(addr, 1)).await;
        drop(guard);

        match result {
            Ok(Ok(Ok(regs))) if !regs.is_empty() => {
                // D220 为有符号 INT16：-1 急停 / 0 复位 / 1 调试 / 2 运行
                let step = regs[0] as i16;
                let _ = plc.app.emit(EV_GL_STEP, step);
            }
            // Modbus 异常/异常长度：忽略本拍
            Ok(Ok(Ok(_))) | Ok(Ok(Err(_))) => {}
            // 超时/IO 错误：判离线由监督器重连，本任务继续存活待恢复
            _ => plc.mark_downline().await,
        }
    }
}

/// P6 报警/操作提示/D400 常驻监视任务（与心跳同生命周期，连接失效即退出、重连重新拉起）：
/// - 每拍 FC01 一次读 M300~M401（空洞按下标忽略）+ FC03 读 D400，共用同一把串行锁；
/// - 启动时加载 alarm_state 基线，重连后第一拍只对齐基线并推当前状态、不写边沿日志，
///   防止重启后把已存在的报警误记一次 raised；
/// - 第二拍起做边沿比较：0→1 写 raised、1→0 写 cleared，每拍状态 upsert alarm_state；
/// - 推 plc::alarm_state（变化时）/ plc::prompt（最高地址 TRUE 提示变化时）/
///   plc::step_index（D400，每拍）事件。
async fn alarm_watch_task(plc: Plc) {
    let cfg = plc.config_clone().await;
    let m_addr = cfg.map.m_coil(WATCH_M_START);
    let d400_addr = cfg.map.d_reg(STEP_D);
    let io = Duration::from_millis(cfg.io_timeout_ms);

    // 重启基线：addr -> on；无记录的点按 false
    let mut prev: HashMap<u16, bool> = {
        let db = plc.app.state::<crate::AppState>().db.clone();
        match tauri::async_runtime::spawn_blocking(move || {
            let conn = db.lock().map_err(|e| format!("锁失败: {e}"))?;
            crate::db::alarms::load_baseline(&conn)
        })
        .await
        {
            Ok(Ok(map)) => map,
            _ => HashMap::new(),
        }
    };
    let mut prev_prompt: Option<u16> = None;
    let mut first = true;

    let mut ticker = interval(Duration::from_millis(cfg.alarm_interval_ms));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);

    loop {
        ticker.tick().await;

        let mut guard = plc.inner.conn.lock().await;
        let Some(ctx) = guard.as_mut() else { continue };
        let coils = timeout(io, ctx.read_coils(m_addr, WATCH_M_CNT)).await;
        let dres = timeout(io, ctx.read_holding_registers(d400_addr, 1)).await;
        drop(guard);

        // 超时/IO 错误：连接不可信，判离线退出，监督器重连后重新拉起本任务
        let coils_io_bad = matches!(coils, Err(_) | Ok(Err(_)));
        let d_io_bad = matches!(dres, Err(_) | Ok(Err(_)));
        if coils_io_bad || d_io_bad {
            plc.mark_downline().await;
            return;
        }

        // Modbus 异常/长度不足：本拍跳过线圈处理；D400 异常则该拍不推 step
        let coils_ok = matches!(&coils, Ok(Ok(Ok(v))) if v.len() >= WATCH_M_CNT as usize);
        let step = match dres {
            Ok(Ok(Ok(regs))) if !regs.is_empty() => Some(regs[0] as i16),
            _ => None,
        };
        if !coils_ok {
            if let Some(s) = step {
                let _ = plc.app.emit(EV_STEP_INDEX, s);
            }
            continue;
        }
        let coils = coils.unwrap().unwrap().unwrap();

        // 报警点电平（按下标取点，空洞忽略）
        let items: Vec<AlarmItem> = ALARM_POINTS
            .iter()
            .map(|&(m, name)| AlarmItem {
                addr: m,
                name: name.to_string(),
                on: coils[(m - WATCH_M_START) as usize],
            })
            .collect();

        // 边沿（第一拍不做）与待持久化状态
        let mut edges: Vec<Edge> = Vec::new();
        let mut alarm_changed = first;
        if !first {
            for it in &items {
                let old = prev.get(&it.addr).copied().unwrap_or(false);
                if old != it.on {
                    edges.push(Edge {
                        addr: it.addr,
                        name: it.name.clone(),
                        raised: it.on,
                    });
                    alarm_changed = true;
                }
            }
        }

        // 操作提示：地址最大且 TRUE 的一个
        let prompt = PROMPT_POINTS
            .iter()
            .filter(|&&(m, _)| coils[(m - WATCH_M_START) as usize])
            .last()
            .map(|&(m, name)| AlarmItem {
                addr: m,
                name: name.to_string(),
                on: true,
            });
        let prompt_addr = prompt.as_ref().map(|p| p.addr);

        // 更新快照供 alarm_current 首屏同步
        {
            let snap = AlarmSnapshot {
                alarms: items.clone(),
                prompt: prompt.clone(),
                step_index: step,
            };
            *plc.inner.alarm_last.lock().await = snap;
        }

        // 事件：报警变化/首拍推全量；提示变化/首拍推 Option；D400 每拍
        if alarm_changed {
            let _ = plc.app.emit(EV_ALARM_STATE, &items);
        }
        if first || prompt_addr != prev_prompt {
            let _ = plc.app.emit(EV_PROMPT, &prompt);
        }
        if let Some(s) = step {
            let _ = plc.app.emit(EV_STEP_INDEX, s);
        }

        // 落库：边沿日志 + 全量状态 upsert（同一事务、spawn_blocking，保序等待）
        let states: Vec<(u16, bool)> = items.iter().map(|i| (i.addr, i.on)).collect();
        let db = plc.app.state::<crate::AppState>().db.clone();
        let _ = tauri::async_runtime::spawn_blocking(move || {
            if let Ok(conn) = db.lock() {
                let _ = crate::db::alarms::persist_poll(&conn, &edges, &states);
            }
        })
        .await;

        // 对齐基线
        for it in &items {
            prev.insert(it.addr, it.on);
        }
        prev_prompt = prompt_addr;
        first = false;
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

/// 点动线圈"按 1 松 0"（Jog±）。
/// 参数 m 为 M 软元件号（如 M201 传 201，后端按 m_base 换算）。
/// 不设超时自动复位：保持到收到松开/切页/失焦；断线时冻结，重连补写 OFF
#[tauri::command]
pub(crate) async fn coil_set(
    state: tauri::State<'_, crate::AppState>,
    m: u16,
    on: bool,
) -> Result<(), String> {
    state.plc.pulse_set(m, on).await
}

/// 轴参数回读：使能线圈（无使能轴为 None）+ 各 D 参数 REAL（按入参顺序）
#[derive(Debug, Serialize)]
pub(crate) struct AxisSnapshot {
    enable: Option<bool>,
    values: Vec<f32>,
}

/// 进入调试页/切换轴时回读某轴的使能状态与调试参数（速度/Inc 距离/Abs 目标）
#[tauri::command]
pub(crate) async fn axis_read(
    state: tauri::State<'_, crate::AppState>,
    enable: Option<u16>,
    ds: Vec<u16>,
) -> Result<AxisSnapshot, String> {
    let mut values = Vec::with_capacity(ds.len());
    for d in ds {
        values.push(state.plc.read_real_raw(d).await?);
    }
    let enable = match enable {
        Some(m) => Some(state.plc.read_coil_m(m).await?),
        None => None,
    };
    Ok(AxisSnapshot { enable, values })
}

/// 上升沿命令短脉冲（Inc+/Inc-/Abs/停止/运行/调试/退出/复位）：
/// 后端写 ON 后按 cmd_pulse_ms（默认 200ms）自动写 OFF，并受点动看门狗保护
#[tauri::command]
pub(crate) async fn coil_pulse(
    state: tauri::State<'_, crate::AppState>,
    m: u16,
) -> Result<(), String> {
    state.plc.pulse_cmd(m).await
}

/// 保持型线圈取反（如调试使能 M200）：同一把锁内读当前值→写反值，返回新值
#[tauri::command]
pub(crate) async fn coil_toggle(
    state: tauri::State<'_, crate::AppState>,
    m: u16,
) -> Result<bool, String> {
    state.plc.toggle_coil_m(m).await
}

/// 写 REAL：d 为 D 软元件号（占 D、D+1 两个寄存器，FC16），字节序按配置
#[tauri::command]
pub(crate) async fn write_real(
    state: tauri::State<'_, crate::AppState>,
    d: u16,
    v: f32,
) -> Result<(), String> {
    state.plc.write_real_raw(d, v).await
}

/// 一键清零：把所有当前置位的点动线圈写 OFF（切页/失焦/停止按钮调用）
#[tauri::command]
pub(crate) async fn coil_clear_all(
    state: tauri::State<'_, crate::AppState>,
) -> Result<(), String> {
    state.plc.release_all_held().await;
    Ok(())
}

// ---------- P4：运动数组 ----------

/// 数组上读结果：D1100 深度、D1101 模式与 13 列 × depth 步行数据
#[derive(Debug, Serialize)]
pub(crate) struct ArrayDump {
    depth: u16,
    mode: u16,
    /// rows[步][列]，列顺序与 arrays::SEGMENTS 一致
    rows: Vec<Vec<f64>>,
}

/// 数组下发入参（与上读结果同构）。arrayId 为下发时关联的配方（无配方时为 null）
#[derive(Debug, Deserialize)]
pub(crate) struct ArrayUploadReq {
    depth: u16,
    mode: u16,
    rows: Vec<Vec<f64>>,
    #[serde(rename = "arrayId")]
    array_id: Option<i64>,
}

/// 运动数组下发：按段 FC16 批量写，最后写深度/模式；写前做范围校验，超限直接拒绝。
/// 每次调用（成功或失败）均追加一条 download_log
#[tauri::command]
pub(crate) async fn array_upload(
    state: tauri::State<'_, crate::AppState>,
    req: ArrayUploadReq,
) -> Result<(), String> {
    let array_id = req.array_id;
    let result = state
        .plc
        .array_upload(req.depth, req.mode, &req.rows)
        .await;
    // 下发结果落日志（日志自身失败不改变下发结论）
    let (ok, detail) = match &result {
        Ok(()) => (true, Some(format!("下发 {} 步成功", req.depth))),
        Err(e) => (false, Some(e.clone())),
    };
    let db = state.db.clone();
    let _ = tauri::async_runtime::spawn_blocking(move || {
        if let Ok(conn) = db.lock() {
            let _ = crate::db::log_from_command(&conn, array_id, ok, detail);
        }
    })
    .await;
    result
}

/// 运动数组上读（点一次读一次，不轮询、不订阅）
#[tauri::command]
pub(crate) async fn array_download(
    state: tauri::State<'_, crate::AppState>,
) -> Result<ArrayDump, String> {
    state.plc.array_download().await
}

// ---------- P6：诊断与报警 ----------

/// 读取 D300~D302 三轴故障码（原始 u16，前端按 4 位十六进制显示）。
/// 与轴报警是否存在无关：无报警/离线时照常可点，读失败返回错误，未读到过的轴前端显示 0000
#[tauri::command]
pub(crate) async fn fault_codes_read(
    state: tauri::State<'_, crate::AppState>,
) -> Result<Vec<u16>, String> {
    let cfg = state.plc.config_clone().await;
    let addr = cfg.map.d_reg(FAULT_D);
    state.plc.read_regs_raw(addr, FAULT_CNT).await
}

/// 首屏同步：取报警常驻任务最近一帧（全部报警电平 / 当前提示 / D400 动作步）
#[tauri::command]
pub(crate) async fn alarm_current(
    state: tauri::State<'_, crate::AppState>,
) -> Result<AlarmSnapshot, String> {
    Ok(state.plc.inner.alarm_last.lock().await.clone())
}
