# Rust 桌面应用技术方案（PLC 调试与运动坐标管理）

## 1. 项目背景与目标

基于 Tauri 开发 Windows 桌面上位机 Demo，通过 Modbus TCP 与 PLC 通信，实现：

- **运行 / 调试双流程切换**，对胸背轴、臀腿轴、臀盘轴、电推杆四轴进行调试控制；
- **实时监控**当前所在界面四轴当前坐标与 PLC 连接状态；
- **连接健壮性（第 10 条）**：开机按参数自动连接 PLC，掉线经 D210 回读/超时判定后自动重连；所有读写与重连均在 Rust 异步任务执行，不卡 UI；
- **按需读写**：不常驻轮询，切换到某界面才订阅/读写该界面对应寄存器，离开即停止（见 5.2）；**常驻例外有二：其一是连接期间以 100ms 间隔向** **`D210`（随机数，INT）写随机数作为上位机心跳；其二（第 2 阶段）是连接期间常驻读报警/提示线圈 M300~M401 与 D400 做边沿检测与全局展示（见 5.6）**，二者均与界面切换无关、断开即停；
- **运动坐标数据管理**：编辑 / 下发 / 存储从 `D2000` 开始的工作坐标、速度、加减速、间隔等运动数组（深度 1\~16）；
- **报警与操作提示（第 2 阶段）**：连接期间常驻轮询 `M300~M322` 报警线圈与 `M400~M401` 操作提示、`D400` 动作步索引，对报警做**上升沿/下降沿检测**并落库（含重启基线，重启不重复记录）；诊断页展示当前报警、按 4 位 HEX 读取 `D300~D302` 故障码、按时段查询历史报警；Header 单行显示当前操作提示与 D400；
- 本地 **SQLite** 持久化坐标数据；**连接参数（PLC IP/端口等）也存同一 SQLite 文件，参数界面可配置，IP 默认** **`192.168.1.88`、端口** **`502`（第 9 条）**；
- 深色界面、左侧导航；
- 在 GitHub 调研同类成熟项目，借鉴其架构与实现。

> Demo 要求：代码尽量简洁，无需复杂页面样式；优先参考成熟开源项目（见第 12 节）。

## 2. 技术栈

| 层      | 选型                                             |
| ------ | ---------------------------------------------- |
| 壳      | **Tauri 2.x**（Rust 后端 + WebView2）              |
| 前端     | Vue 3 + TypeScript + Vite                      |
| UI 库   | **Naive UI**（`n-config-provider` 内置 darkTheme） |
| 状态     | Pinia                                          |
| 路由     | Vue Router（左侧菜单）                               |
| Modbus | Rust crate **`tokio-modbus`**（TCP client，异步）   |
| SQLite | **`rusqlite`**（bundled），同时承载运动数据与连接参数配置（第 9 条） |
| 序列化    | serde / serde\_json                            |
| 日志     | `tracing` + `tracing-subscriber`               |

## 3. 寄存器映射分析（来自 寄存器地址.xlsx）

PLC（信捷，Modbus TCP）软元件到 Modbus 地址的换算在驱动层统一封装。

| 软元件              | Modbus 功能码                | 说明                                |
| ---------------- | ------------------------- | --------------------------------- |
| M 区（M101\~M401）  | 01 读线圈 / 05 写单线圈（或 15 批量） | M101\~M221 控制点；M300\~M322 报警、M400\~M401 操作提示，按 PLC 实际映射配置 |
| D 区（D200\~D2930） | 03 读保持寄存器 / 06、16 写       | REAL 占 2 个 D、INT 占 1 个、DINT 占 2 个 |

> 关键风险：不同信捷固件的 Modbus 地址映射不同，M/D 起始偏移在配置文件中集中管理，并提供寄存器原始值诊断页核对。

### 3.1 控制点（M 线圈）

| 地址                 | 功能                                       | 交互行为    |
| ------------------ | ---------------------------------------- | ------- |
| M110 / M111        | 选择运行 / 调试流程                              | 进入对应模式  |
| M120               | 退出调试流程                                   | —       |
| M101               | 普通停止；M218 调试停止                           | 安全按钮    |
| M102               | 复位                                       | —       |
| M200\~M205         | 胸背轴：使能 / Jog+ / Jog- / Inc+ / Inc- / Abs | 按 1 松 0 |
| M206\~M211         | 臀腿轴同上                                    | 按 1 松 0 |
| M212\~M217         | 臀盘轴同上                                    | 按 1 松 0 |
| M219 / M220 / M221 | 电推杆：Jog+ / Jog- / Abs（无使能、无 Inc）         | 按 1 松 0 |

### 3.2 实时监控数据（D 区，REAL）

`D200 胸背(mm)`、`D202 臀腿(°)`、`D204 臀盘(°)`、`D206 电推杆(°)` —— 仅在调试界面订阅读取，离开即停（第 8 条）。

**心跳寄存器（常驻写，第 8 条例外）**：`D210 随机数`（INT，变量名 HMI\_RDV1）——与 PLC 连接成功后，无论当前在哪个界面，后端每 **100ms** 写入一个新随机数（功能码 06），供 PLC 侧判断上位机在线；断开连接即停。

### 3.3 调试参数（D1000\~D1018）

每轴：调试速度 / Inc 距离 / Abs 目标位置（电推杆仅有 Abs 目标 `D1018`）。

### 3.4 运动数组（核心，D1100 + D2000 起）

控制量：`D1100` 数组深度（INT，1\~16）、`D1101` 运动模式（INT，1 调理 / 2 治疗 / 3 老化测试）。
运行参数：`D1110~D1124` 各轴运行速度与初始/工作位置。

数组按 16 步排布（步内连续，每步 2 个 D）：

| 数据段      | 起始    | 步数 | 末地址   | 类型   | 限值        |
| -------- | ----- | -- | ----- | ---- | --------- |
| 胸背轴工作坐标  | D2000 | 16 | D2030 | REAL | —         |
| 臀腿轴工作坐标  | D2032 | 16 | D2062 | REAL | —         |
| 臀盘轴工作坐标  | D2064 | 16 | D2094 | REAL | —         |
| 胸背轴工作速度  | D2096 | 16 | D2126 | REAL | 最大 500    |
| 臀腿轴工作速度  | D2128 | 16 | D2158 | REAL | 最大 148.76 |
| 臀盘轴工作速度  | D2160 | 16 | D2190 | REAL | 最大 148.76 |
| 胸背轴工作加速度 | D2192 | 16 | D2222 | REAL | 最大 2500   |
| 臀腿轴工作加速度 | D2224 | 16 | D2254 | REAL | 最大 743.8  |
| 臀盘轴工作加速度 | D2256 | 16 | D2286 | REAL | 最大 743.8  |
| 胸背轴工作减速度 | D2288 | 16 | D2318 | REAL | 最大 2500   |
| 臀腿轴工作减速度 | D2320 | 16 | D2350 | REAL | 最大 743.8  |
| 臀盘轴工作减速度 | D2352 | 16 | D2382 | REAL | 最大 743.8  |
| 运动间隔（ms） | D2900 | 16 | D2930 | DINT | —         |

> 地址表中坐标/速度/加减速均未给变量名，程序以"段起始 + 步索引 × 2"公式动态计算，避免硬编码 400+ 地址。

### 3.5 报警 / 操作提示 / 故障码（第 2 阶段，M300 段 / D300 段）

点表中实际定义、程序实际使用的点（空洞不读）：

| 区段 | 地址 | 含义 | 读取方式 |
| --- | --- | --- | --- |
| 报警线圈 | M300 / M301 / M302 / M303 | 胸背轴报警 / 臀腿轴报警 / 臀盘轴报警 / 推杆轴堵转 | 功能码 01 常驻周期读 `M300~M322` 一次 |
| 报警线圈 | M310 / M311 / M312 | 急停按钮1按下 / 急停按钮2按下 / 安全继电器报警 | 同上 |
| 报警线圈 | M320 / M321 / M322 | 暂停 / 停止按钮按下 / 上位机失联 | 同上 |
| 操作提示 | M400 / M401 | 请按复位按钮 / 请按脚踏 | 同一次 01 读取覆盖（区间内含空洞，忽略未定义位） |
| 故障码（INT） | D300 / D301 / D302 | 胸背轴 / 臀腿轴 / 臀盘轴故障码，**4 位 HEX 显示** | 诊断页按钮触发，功能码 03 一次性读 3 个寄存器 |
| 操作数据（INT） | D400 | 当前动作步索引 | 功能码 03 常驻周期读 1 个寄存器 |

- 报警线圈按 `m_coil(300)` 起、连续区间读取；只对上表 10 个报警点做边沿检测与落库，提示位 M400/M401 只展示不记日志。
- 故障码不与轴报警状态关联：D300 段为 0 即显示 `0000`，是否有 M300 段报警不影响该读取。

### 3.6 IO 信号（来自 IO 表，经 M/D 映射后可读时使用）

- 输入：X0/X1 推杆 A/B 相，X2/X3 急停 1/2，X4 安全继电器状态，X5 推杆到位，X6 脚踏启动，X7 复位；
- 输出：Y0\~Y2 灯带黄/绿/红，Y3/Y4 抱闸，Y5/Y6 推杆前进/后退。

## 4. 总体架构

```
┌────────────────────────── 前端 (Vue3/TS) ─────────────────────────┐
│ Header(状态机/操作提示/D400) 调试页(4轴) 数组页 诊断页(报警/故障码)  │
│        ↑ invoke() / emit 事件（坐标、状态、报警、提示、日志）       │
└──────────────────────────────┬────────────────────────────────────┘
                               │ Tauri IPC
┌──────────────────────────────┴──────────── Rust 后端 ─────────────┐
│ plc 模块        │ db 模块(SQLite)  │ app 状态/命令  │ 配置/日志     │
│ - 地址映射       │ - 运动数组表      │ - Tauri State  │ - IP/端口     │
│ - 按界面订阅读取  │ - 下发记录        │ - #[command]   │ - 读取周期    │
│ - 写线圈脉冲     │ - alarm_log 报警  │ - 事件广播      │ - 心跳100ms   │
│ - 批量读写寄存器  │ - alarm_state 基线│  (离开即停读)   │  写D210随机数 │
│ - D210心跳常驻写 │                  │                │ - 报警常驻轮询 │
│ - 报警/提示/D400 │                  │                │  M300~M401    │
│   常驻轮询+边沿  │                  │  (全程异步,    │  边沿检测落库  │
│ - 开机自动连接/   │                  │   不卡UI)      │               │
│   D210回读判停/   │                  │                │               │
│   断线自动重连    │                  │                │               │
│ 配置读写(SQLite app_config，默认192.168.1.88:502)                    │
└───────────────────────────────────────────────────────────────────┘
```

## 5. Rust 后端设计

### 5.1 地址层 `plc::address`

集中定义软元件与功能码、Modbus 偏移换算：

```rust
pub struct PlcMap { pub m_base: u16, pub d_base: u16 }

impl PlcMap {
    /// D 地址 -> 保持寄存器地址；REAL/DINT 占 2 个寄存器
    pub fn d_reg(&self, d: u16) -> u16 { self.d_base + d }
    pub fn m_coil(&self, m: u16) -> u16 { self.m_base + m }
}
```

运动数组用公式而非枚举：`reg = seg.start + step * 2`（step 0..depth）。

### 5.2 连接与按需读取 `plc::client`（第 8 条要求）

**核心原则：不常驻轮询，按当前界面订阅寄存器组，离开即停。**

- 连接与读任务解耦：
  - **自动连接（第 10 条）**：软件启动后后端用 SQLite 中的 IP/端口自动发起连接，无需用户点"连接"；连接成功后若掉线（TCP 错误或 D210 回读判定，见下）自动重连，指数退避（如 1s→2s→5s→10s 封顶），重连成功即恢复心跳与订阅；只有用户在参数页**手动断开**才停止自动重连，再次手动连接/重启应用后恢复。
  - 连接维护为后端单例，`plc_connect/plc_disconnect` 只是手动入口；连接本身不周期读业务数据；
  - 读取由"订阅"驱动：前端进入界面时 `plc_subscribe(group_key)`，离开时 `plc_unsubscribe(group_key)`；后端为每个被订阅的组起一个定时读取任务，引用计数归 0 立即停止，**任何时刻最多只读当前界面需要的寄存器**。
- **断线判定（第 10 条，双通道）**：① TCP 读写报错立即判离线；② 心跳任务每拍写完 `D210` 后按较低频率（如每 1s，可配）用功能码 03 回读 `D210`，若连续若干次（如 3 次）读失败或连接超时（socket 有读超时）也判离线 → 主动断开并进入重连流程。状态切换经 `plc::status` 事件推前端（绿/红灯），界面不做任何阻塞等待。
- **不卡 UI（第 10 条）**：所有 Modbus 连接、读写、重连均在 Rust 端 tokio 异步任务内完成，`#[tauri::command]` 全部 `async`，前端 `invoke` 只 await 不阻塞渲染线程；socket 设置连接/读写超时，重连退避用 `tokio::time::sleep`，绝不在命令里同步死等；rusqlite 等同步阻塞调用放 `spawn_blocking`/专用连接线程。
- 订阅组（`group_key` → 寄存器集合）在后端集中定义，与页面一一对应：

| 界面      | 订阅组         | 周期读取内容                    |
| ------- | ----------- | ------------------------- |
| 调试（任一轴） | `telemetry` | `D200~D207` 四轴当前坐标（8 寄存器） |
| 运动数组    | 无周期组        | 仅点击"上读"时一次性读数组，不轮询        |
| 诊断      | 无周期组        | 仅点"读取报警代码"时一次性读 `D300~D302`，不轮询 |
| 设置 / 其它 | 无           | 不读                        |

> **与界面无关的常驻读取**（不经过订阅引用计数，连接期间一直运行，断开即停、重连自愈）：
> - `glstep` 组：`D220` 全局状态机（INT16，1 寄存器），发 `plc::gl_step`；
> - **报警/提示/D400 监视**（见 5.6）：功能码 01 读 `M300~M322`（含 M400/M401 提示位）+ 功能码 03 读 `D400`，发 `plc::alarm_state` / `plc::prompt` / `plc::step_index`。
>
> 这两类与 D210 心跳同为按需订阅原则的例外，由后端在连接成功时自启，前端进入应用即常驻监听。

- 调试页四轴坐标共用一个 `telemetry` 组；进入即订阅、`onUnmounted`/路由离开即退订。
- 解析后通过 `app.emit("plc::telemetry", payload)` 推前端；连接状态变化发 `plc::status`（连接可常保以降低延迟，状态灯反映连接是否在线）。
- 写操作（点动、参数、下发）不受订阅限制，按需即时发起。
- **常驻心跳（第 8 条唯一例外，不经过订阅机制）**：连接成功即由后端启动一个 100ms 周期任务，用功能码 06 向 `D210`（随机数 INT）写一个新的 `u16` 随机值，PLC 据此判断上位机是否在线；该任务**与界面无关、全程运行**，断线重连期间暂停、恢复后续写，`plc_disconnect` 时停止。心跳写与其它写命令共用同一连接、同一把串行锁，避免报文交错；心跳失败不刷错误弹窗，只计入连接状态。
- **D210 回读监控（第 10 条）**：上位机侧同样借 `D210` 判断 PLC 是否在线——连接监督任务周期（默认 1s）回读 `D210`，结合写/读失败与超时判定离线并触发自动重连（判定阈值见上条），全程异步不阻塞界面。
- REAL 字节序：信捷通常 **大端 word、大端 byte（ABCD）**，做成可配置 `ABCD/CDAB/BADC/DCBA`，用诊断页核对；DINT（运动间隔）同理。
- 周期默认 500ms 且可配；也可改为"进入页面读一次 + 手动刷新"，进一步减少总线占用。

### 5.3 写命令（"按1松0" 与 "取反"）

- **按 1 松 0（点动脉冲）**：按下（`mousedown/touchstart`）写线圈 ON，松开（`mouseup/mouseleave/touchend`）写 OFF。后端加**软件看门狗**（如 5s 未收到 release 强制 OFF），防止鼠标异常导致持续运动。
- **取反**：读当前线圈值 → 写反值（读改写在同一把锁内，避免竞争）。
- 使能（ServoOn）可保持；Inc/Abs 运动命令按 PLC 上升沿触发约定发短脉冲，脉冲宽度可配。

```rust
#[tauri::command]
async fn coil_set(state: State<'_, Plc>, addr: u16, on: bool) -> Result<()>;
#[tauri::command]
async fn coil_toggle(state: State<'_, Plc>, addr: u16) -> Result<bool>;
#[tauri::command]
async fn write_real(state: State<'_, Plc>, d: u16, v: f32) -> Result<()>;
// 第 8 条：按界面订阅读取，离开退订
#[tauri::command]
async fn plc_subscribe(state: State<'_, Plc>, group: String) -> Result<()>;
#[tauri::command]
async fn plc_unsubscribe(state: State<'_, Plc>, group: String) -> Result<()>;
```

### 5.4 运动数组下发/上读

- **下发**：按段用功能码 16 批量写；先写数组数据，最后写 `D1100` 深度与 `D1101` 模式。
- **上读**：读回全部数组，前端对比 "PLC 实际值 vs 本地数据"。
- 写前范围校验（速度 ≤500/148.76，加减速 ≤2500/743.8，深度 1\~16）。

### 5.5 安全设计

- 调试停止 M218、普通停止 M101 常驻页面；
- Jog 按钮失焦 / 切页 / 断线自动清零；
- 写命令同一连接串行化，失败明确回传错误。

### 5.6 报警 / 操作提示常驻监视（第 2 阶段）

连接成功后由后端自启一个常驻监视任务（与心跳同生命周期：断线暂停、重连自愈、手动断开停止），周期默认取 `read_interval_ms`（500ms，可另配 `alarm_interval_ms`）：

1. 功能码 01 **一次**读 `M300~M401` 共 102 个连续线圈（Modbus 单次读线圈上限远大于此），在结果中按下标只取实际使用的 10 个报警位（M300~M303/M310~M312/M320~M322）与 2 个提示位（M400/M401），中间空洞忽略；相比分两次读区间，省一次事务。
2. 功能码 03 读 `D400` 1 个寄存器（INT16）。
3. 报文与心跳、业务命令共用同一连接与串行锁；单次 IO 超时跳过等下一拍，不弹窗。

**边沿检测与落库**：

- 内存维护 10 个报警点的上一拍电平；`0→1` 写一条 `alarm_log(kind='raised')`，`1→0` 写一条 `kind='cleared'`，均含 `addr/name/ts`，SQLite 写入走 `spawn_blocking`。
- 提示位 M400/M401 不做边沿落库，只取**地址最大且为 TRUE** 者的文案发 `plc::prompt`；D400 发 `plc::step_index`；当前全部报警位发 `plc::alarm_state`。

```rust
// 事件 payload（命名示意）
// plc::alarm_state : Vec<{ addr:u16, name:String, on:bool }>
// plc::prompt      : Option<{ addr:u16, text:String }>   // 最后一个 TRUE 的提示
// plc::step_index  : i16                                 // D400
#[tauri::command]
async fn alarm_logs(state: State<'_, AppState>, begin: String, end: String,
                    limit: u32) -> Result<Vec<AlarmLog>>;   // 时段筛选，ts DESC
#[tauri::command]
async fn fault_codes_read(state: State<'_, AppState>) -> Result<[u16; 3]>; // 一次性读 D300~D302
```

**重启基线（要求 4，防重复记录）**：

- 任一位电平变化时，把当前 10 个报警点电平 upsert 进 `alarm_state(addr,on,updated_at)`，保证关闭软件前最后状态已持久化（不强依赖关闭钩子）。
- 启动时加载 `alarm_state` 作为初始上一拍；连接成功后**第一拍只对齐基线 + 推当前状态、不写任何 alarm_log**，从第二拍起才做边沿比较。这样报警在重启前后持续为 1 不会被再记一次上升沿，重启后解除仍能正确记一条下降沿。

**故障码**：`fault_codes_read` 仅在诊断页点击时执行一次，读 `D300~D302`，前端按 `v.toString(16).padStart(4,'0')` 显示 4 位 HEX；与报警电平无关。

## 6. SQLite 数据模型

数据库文件放 app data 目录（`%APPDATA%/<app>/plc.db`）。**连接与通信参数也存此库（第 9 条），首次启动以默认值建表，参数界面保存后即时生效。**

```sql
-- 键值式参数表：IP/端口/字序/基址/周期/心跳/限值等全部参数
CREATE TABLE app_config (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at TEXT DEFAULT (datetime('now','localtime'))
);
-- 首启默认行（节选）：
-- ('plc.ip','192.168.1.88')、('plc.port','502')、('plc.unit_id','1')、
-- ('read_interval_ms','500')、('heartbeat_ms','100')、('heartbeat_reg','210')、
-- ('real_order','ABCD')、('m_base',…)、('d_base',…)、各轴限值等

CREATE TABLE move_array (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  name        TEXT NOT NULL UNIQUE,
  depth       INTEGER NOT NULL CHECK(depth BETWEEN 1 AND 16),
  mode        INTEGER NOT NULL,          -- 1调理 2治疗 3老化
  remark      TEXT,
  created_at  TEXT DEFAULT (datetime('now','localtime')),
  updated_at  TEXT DEFAULT (datetime('now','localtime'))
);

-- 每步一行，16 列对应数组各数据段
CREATE TABLE move_step (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  array_id     INTEGER NOT NULL REFERENCES move_array(id) ON DELETE CASCADE,
  step_no      INTEGER NOT NULL,         -- 1..16
  chest_pos    REAL, leg_pos REAL, seat_pos REAL,
  chest_vel    REAL, leg_vel REAL, seat_vel REAL,
  chest_acc    REAL, leg_acc REAL, seat_acc REAL,
  chest_dec    REAL, leg_dec REAL, seat_dec REAL,
  interval_ms  INTEGER,
  UNIQUE(array_id, step_no)
);

CREATE TABLE download_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  array_id INTEGER, ts TEXT, ok INTEGER, detail TEXT
);

-- ===== 第 2 阶段：报警 =====
-- 报警发生/解除历史（边沿检测，诊断页按时段筛选）
CREATE TABLE alarm_log (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  addr    INTEGER NOT NULL,          -- 线圈 M 地址，如 300
  name    TEXT NOT NULL,             -- 报警名称（点表注释），如 胸背轴报警
  kind    TEXT NOT NULL,             -- 'raised' 上升沿发生 / 'cleared' 下降沿解除
  ts      TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);
CREATE INDEX idx_alarm_log_ts ON alarm_log(ts);

-- 各报警点关软件前的最后电平，重启时作为边沿检测基线（要求 4，防重启重复记录）
CREATE TABLE alarm_state (
  addr       INTEGER PRIMARY KEY,    -- 仅 10 个报警点
  on         INTEGER NOT NULL,       -- 0/1
  updated_at TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);
-- 报警点清单（addr→name）固化在 Rust 配置常量中，首启可播种进 alarm_state(on=0)
```

## 7. 前端设计

### 7.1 布局与导航

- 整体深色（Naive UI `darkTheme`），`n-layout has-sider`：
  - 左侧 `n-menu`：**调试（胸背/臀腿/臀盘/电推杆）**、运动数组、诊断、设置；
  - 顶部 `n-layout-header`（全局常驻，任意路由可见）：右侧四个模式点动按钮（运行/调试/退出调试/复位）、D220 状态机彩色标签，以及第 2 阶段新增的——**操作提示单行文本**（取 M400 段地址最大的 TRUE 位文案，超出截断不换行）与 **D400 当前动作步索引数字**；
  - 底部状态栏：PLC 连接指示灯（仿参考图左下绿点）、错误信息。
- Demo 以功能可用为先，样式从简。

### 7.2 调试页（参考 McgsPro 截图）

四个轴共用一个组件，按轴能力裁剪（电推杆无使能 / Inc）：

- 左列轴切换菜单；右上【运行】【调试】；
- **调试使能**开关（M200/206/212）；
- 【Jog+】【Jog-】【Inc+】【Inc-】【Go】：`mousedown` 发 ON，`mouseup/mouseleave` 发 OFF；
- 参数输入：调试速度、点动距离、目标位置（D1000 段）；
- 右侧实时显示四轴当前坐标（mm / °，3 位小数）；
- 右下【退出调试】【调试停止】；
- 提供 **取反** 辅助按钮。

### 7.3 运动数组页

- 按"步 1..深度"组织的 `n-data-table` 可编辑表格，列：各轴坐标 / 速度 / 加减速 / 间隔；
- 切换深度动态增减行；超上限单元格标红；
- 操作：从 PLC 上读、整组下发、保存到 SQLite、载入本地记录。

### 7.4 参数（设置）页（第 9 条）

- 表单配置连接与通信参数：**PLC IP（默认** **`192.168.1.88`）、端口（默认** **`502`）**、unit id、REAL/DINT 字序、M/D 基址、读取周期、心跳间隔/寄存器、各轴限值；
- 进入页面时从 SQLite 读取当前值回填，"保存"写回 `app_config` 表；软件开机默认按库中参数**自动连接**（第 10 条），参数页另提供手动 连接/断开；IP/端口等连接参数在下次连接时生效（已连接时提示"断开后重连生效"或提供"保存并重连"按钮）；
- 页面展示连接状态（绿/红/重连中）与重连尝试，状态来自 `plc::status` 事件，界面自身不做任何阻塞式连接等待；
- Demo 不做 settings.json，所有参数唯一来源为 SQLite，避免两处配置不一致。

### 7.5 诊断页（第 2 阶段）

- **左：当前报警文本框**。只读、多行、**黑底白字**；内容为当前电平为 1 的报警，按点表顺序每条一行、以 `\n` 连接（`activeAlarms.map(a=>a.name).join("\n")`）；无报警时为空或显示"无报警"。数据来自 store 常驻监听的 `plc::alarm_state`，进入诊断页不产生新的读请求。
- **右：历史报警记录**。起止时间（`n-date-picker` daterange）+ 查询按钮，调 `alarm_logs(begin,end)` 取 `alarm_log`，`n-data-table` 按时间倒序展示时间 / 地址 / 名称 / 发生(raised)或解除(cleared)。
- **读取报警代码按钮**。点击调 `fault_codes_read()` 一次性读 D300~D302，按轴显示 3 个 **4 位十六进制**故障码（`0000`~`FFFF`）；不轮询、与当前轴报警是否存在无关。
- 样式从简：左右两栏用 `n-grid` 或 flex，文本框用 `n-input type="textarea" readonly` 覆盖 `background:#000;color:#fff`。

### 7.6 IPC 封装与按需订阅

`src/api/plc.ts` 封装 `invoke`；`stores/plc.ts` 监听事件维护 telemetry / connection / glStep / **activeAlarms / prompt / stepIndex** 状态。
按第 8 条，读取生命周期绑定到页面：在调试页 `onMounted` 调 `plc_subscribe('telemetry')`、`onUnmounted`（含路由离开守卫）调 `plc_unsubscribe`；运动数组页不订阅，仅按钮触发一次性读写。**例外（常驻、store `init()` 即订阅且不退订）**：D210 心跳（纯后端）、`glstep`、报警/提示/D400 监视——这些与当前页面无关，任意路由下都在刷新。确保除常驻项外，同一时刻只有当前界面在访问 PLC。

## 8. 项目结构

```
.
├─ src-tauri/
│  ├─ src/
│  │  ├─ main.rs
│  │  ├─ plc/{mod.rs, address.rs, client.rs, codec.rs, arrays.rs, alarms.rs}
│  │  ├─ db/{mod.rs, models.rs, recipes.rs, alarms.rs}
│  │  ├─ commands.rs
│  │  └─ config.rs
│  ├─ Cargo.toml
│  └─ tauri.conf.json
└─ src/
   ├─ views/{Commission,MoveArray,Diagnostic,Settings}.vue
   ├─ components/AxisPad.vue
   ├─ api/plc.ts
   ├─ stores/plc.ts
   ├─ router/index.ts
   ├─ App.vue
   └─ main.ts
```

## 9. 配置项（存 SQLite `app_config` 表，第 9 条）

所有参数存第 6 节同一 SQLite 文件的 `app_config` 键值表，由参数界面读写；不使用 settings.json。默认值：

| key                                   | 默认值                    | 说明                         |
| ------------------------------------- | ---------------------- | -------------------------- |
| `plc.ip`                              | `192.168.1.88`         | PLC IP，参数界面可改              |
| `plc.port`                            | `502`                  | Modbus TCP 端口              |
| `plc.unit_id`                         | `1`                    | 从站地址                       |
| `read_interval_ms`                    | `500`                  | 仅订阅组生效                     |
| `real_order` / `dint_order`           | `ABCD`                 | REAL/DINT 字序               |
| `m_base` / `d_base`                   | 按现场                    | 软元件 Modbus 基址偏移            |
| `pulse_watchdog_ms`                   | `5000`                 | 按1松0看门狗                    |
| `heartbeat_ms`                        | `100`                  | D210 心跳写间隔                 |
| `heartbeat_reg`                       | `210`                  | 心跳寄存器 D210                 |
| `alarm_interval_ms`                   | `500`                  | 报警/提示/D400 常驻轮询周期（第 2 阶段），缺省回退 `read_interval_ms` |
| `watchdog_read_ms` / `watchdog_fails` | `1000` / `3`           | D210 回读判停周期与连续失败次数（第 10 条） |
| `auto_connect`                        | `true`                 | 开机自动连接；掉线自动重连（手动断开时暂停）     |
| `reconnect_backoff_ms`                | `1000,2000,5000,10000` | 重连退避序列                     |
| `conn_timeout_ms` / `io_timeout_ms`   | `3000` / `1000`        | 连接/读写超时，保证命令不挂起、不卡 UI      |
| 各轴速度 / 加减速上下限                         | 见 3.4                  | 限值校验                       |

`config.rs` 启动时从 `app_config` 加载到内存配置结构，参数保存后更新数据库并刷新内存；IP/端口在下一次连接时生效。

## 10. 开发与联调计划

1. 搭框架：Tauri2 + Vue3 + Naive UI 深色壳、左侧菜单、路由、Pinia；建 SQLite 与 `app_config` 表（默认 IP 192.168.1.88 / 端口 502，首启自动播种）。
2. 参数页：IP/端口等参数表单读写 SQLite；打通 Modbus **开机自动连接 / D210 回读判停 / 断线指数退避自动重连（全程异步不卡 UI）** / **进入调试页才订阅 D200 坐标、离开即停** + D210 心跳 + 寄存器诊断页，现场核对地址映射与 REAL 字节序（最高风险项，先行）。
3. 调试页：按1松0、取反、使能、Inc/Abs、停止，接看门狗。
4. 运动数组：表格编辑 + 批量上读 / 下发 + 限值校验。
5. SQLite 业务表：数组记录保存 / 载入、下发日志（参数表已在第 1 步就位）。
6. 诊断与报警（第 2 阶段）：常驻轮询 M300~M401 报警/提示线圈与 D400，报警上升/下降沿写 `alarm_log`、状态写 `alarm_state` 作重启基线；诊断页当前报警黑底文本框 + 时段筛选 + D300~D302 故障码 HEX 按钮；Header 单行操作提示与 D400 显示。
7. 安全联调：断线清零、失焦清零、长按保护；真机核对 M/D 偏移与字序。
8. 打包：`tauri build` 出 Windows MSI/EXE。

## 11. 风险与对策

| 风险                         | 对策                                                                |
| -------------------------- | ----------------------------------------------------------------- |
| M/D 的 Modbus 实际偏移与假设不符     | 映射可配 + 诊断页联调核对                                                    |
| REAL/DINT 字节序差异            | 字序可配，用已知坐标值验证                                                     |
| 松开事件丢失致持续运动                | 后端看门狗强制 OFF + 断线 / 失焦清零                                           |
| CMD 脉冲还是电平触发不确定            | 对照 FB\_ECAxis / FB\_Pusher 逻辑，脉冲宽度可配                              |
| 批量写越界 / 深度错误               | 严格按段与深度校验                                                         |
| 离开界面后仍在读 PLC（违背第 8 条）      | 订阅引用计数 + 路由离开/卸载守卫统一退订，断开连接时清空全部订阅（心跳写 D210 是第 8 条明确例外，不受此限）      |
| 100ms 心跳写与业务写/订阅读争抢总线或报文交错 | 所有报文共用一条连接、互斥串行；心跳写优先级最低，单次超时即跳过等下一拍，不阻塞业务命令                      |
| 心跳停写（上位机卡死/断线）时 PLC 误判     | PLC 侧超时判定 + 上位机看门狗；心跳任务独立 tokio 任务，连续失败按断线处理并触发重连/状态灯变红           |
| PLC 掉线（网线断/断电）TCP 不立即报错    | D210 周期回读 + 读写超时双通道判停（第 10 条），判定后自动重连                             |
| 自动重连风暴 / 手动断开后仍重连          | 指数退避封顶；手动断开置"用户意图"标志暂停重连                                          |
| 连接/读写/重连卡住界面线程             | 全部 tokio 异步 + 超时，命令 async 非阻塞；同步 SQLite 走 spawn\_blocking（第 10 条） |
| 报警常驻轮询违背按需原则/增加总线负载      | 明确列为例外二；一次功能码 01 连续读 + 一次 03，周期可配（默认 500ms）；与心跳共用串行锁，超时跳过不刷错误；仿真器抓包核对报文量 |
| 软件重启后默认 0 基线导致同一报警重复记录上升沿 | `alarm_state` 持久化最后电平，启动加载为基线，重连后第一拍只对齐不落库，第二拍起才做边沿检测（要求 4） |
| 报警记录高频刷库 / 状态变化丢持久化       | 仅在 0→1、1→0 跳变时写一条日志并 upsert 基线，电平稳定不写库；写库走 spawn\_blocking 不阻塞轮询 |
| 操作提示多位同时 TRUE 展示不确定        | 规则固定为取地址最大（最后一个）TRUE 位文案，单行截断不换行（要求 7）                    |
| WebView2 缺失                | 安装包集成引导                                                           |

## 12. GitHub 同类项目调研与借鉴

按第 7 条要求，在 GitHub 检索 Tauri + Modbus + PLC 上位机类项目，选出可直接参考的成熟方案（2026-09 检索）。

### 12.1 重点参考项目

| 项目                                                                                        | 技术栈                                                               | 与本项目关联                                              | 借鉴点                                                                                |
| ----------------------------------------------------------------------------------------- | ----------------------------------------------------------------- | --------------------------------------------------- | ---------------------------------------------------------------------------------- |
| [LazyDoomSlayer/relay-deck](https://github.com/LazyDoomSlayer/relay-deck)                 | Tauri 2 + Vue 3 + `tokio-modbus 0.17` + tokio-serial/serialport   | **技术栈与场景最贴近**：桌面端经 Modbus 对继电器做通断控制，对应本项目 Jog"按1松0" | 单 crate 后端、最小依赖、线圈写命令封装、Vue 侧 IPC 调用方式                                             |
| [Karl-Dai/ModbusSim](https://github.com/Karl-Dai/ModbusSim)                               | Tauri 2 + Vue 3，Rust workspace（modbussim-core + master/slave app） | 同技术栈；含 Modbus Master 轮询、扫描组、字节序处理、报文日志              | workspace 中独立 `core` crate 解耦协议与 UI；轮询分组、REAL/字节序、连线状态管理；tauri-plugin-log/store 用法 |
| [inowio/modbus-workbench](https://github.com/inowio/modbus-workbench)                     | Tauri + React + TS                                                | Modbus TCP/RTU 配置、测试、监控一体                           | 连接配置表单、设备监控表格、轮询控制交互                                                               |
| [YearsAlso/modbus-tool](https://github.com/YearsAlso/modbus-tool)                         | Tauri + React + Rust                                              | 现代 Modbus 调试工具                                      | 寄存器读写面板、功能码分类的页面组织                                                                 |
| [lvlumi2020/tauri-modbus-tcp](https://github.com/lvlumi2020/tauri-modbus-tcp)             | Tauri，Modbus TCP                                                  | 纯 Modbus TCP 极简实现                                   | 最小 TCP 主站连接/读写代码骨架                                                                 |
| [krzysztofautomatyk/plc-ladder-sim](https://github.com/krzysztofautomatyk/plc-ladder-sim) | Tauri v2 + Rust(Tokio 扫描周期) + Svelte                              | PLC 扫描周期 + 内置 Modbus TCP slave                      | 可作无真机时的对调从站；周期任务模型                                                                 |
| [YEDASAVG/vyuh\_hmi](https://github.com/YEDASAVG/vyuh_hmi)                                | Flutter + Rust WebSocket + Modbus TCP                             | 工业 HMI 实时监控 PLC                                     | HMI 数据点建模、实时刷新模式（前端框架不同，仅借思路）                                                      |

> 另有 modbus-lab（modbus-rs）、hopekayo master/slave simulator、oldsyun/modbustool 等可作寄存器调试与对调辅助。

### 12.2 可直接落地的结论

1. **依赖版本已验证**：`tokio-modbus = "0.17"` 在 Tauri 2 + tokio 1.49 下有现成可编译工程（relay-deck），本方案照此选型；TCP 主站无需 tokio-serial/serialport，可进一步精简依赖。
2. **代码组织两档可选**：
   - Demo 从简：单 `src-tauri` crate，`plc / db / commands` 分模块（推荐，符合第 6 条）；
   - 后续扩展：仿 ModbusSim 拆 `plc-core` workspace crate，协议逻辑与 Tauri 解耦，便于单元测试。
3. **"按1松0"参考 relay-deck 的线圈命令封装**：前端 pointer 事件 → IPC → `write_single_coil`，并在后端补看门狗（该项目未做，是本项目增强点）。
4. **扫描组思路改造为"按界面订阅"（第 8 条）**：借 ModbusSim Master 的分组读取与统一 REAL/DINT 字序解码、连接状态与报文日志，但读取任务不常驻——仅当前界面订阅的组运行，离开即停（见 5.2）。
5. **无真机对调**：本地启 Modbus slave（ModbusSim 或 plc-ladder-sim）模拟 D 区/M 区，先行打通地址映射与字节序，再接真机。
6. **插件选择**：日志用 `tauri-plugin-log`；**参数与数据统一用 rusqlite bundled 落 SQLite（第 9 条，含** **`app_config`** **连接参数表），不再引入** **`tauri-plugin-store`** **/ settings.json，避免配置两处存放**。

