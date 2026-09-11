import { invoke } from "@tauri-apps/api/core";

/** PLC 连接状态（与后端 StatusKind 对应） */
export type PlcStatus = "connecting" | "online" | "reconnecting" | "offline";

/** D200~D207 四个 REAL 轴坐标（telemetry 事件载荷） */
export interface PlcTelemetry {
  /** 胸背轴 mm */
  chestBack: number;
  /** 臀腿轴 ° */
  hipLeg: number;
  /** 臀盘轴 ° */
  hipDisc: number;
  /** 电推杆轴 ° */
  pushrod: number;
}

export const PLC_STATUS_EVENT = "plc::status";
export const PLC_TELEMETRY_EVENT = "plc::telemetry";

/** 手动连接/重连（后端先重读 SQLite 参数） */
export function plcConnect(): Promise<void> {
  return invoke("plc_connect");
}

/** 手动断开（停止自动重连） */
export function plcDisconnect(): Promise<void> {
  return invoke("plc_disconnect");
}

/** 订阅数据组（引用计数，可重复订阅） */
export function plcSubscribe(group: string): Promise<void> {
  return invoke("plc_subscribe", { group });
}

/** 退订数据组（引用归零时后端停止周期读） */
export function plcUnsubscribe(group: string): Promise<void> {
  return invoke("plc_unsubscribe", { group });
}

/** 查询当前状态（首屏同步用） */
export function plcStatus(): Promise<PlcStatus> {
  return invoke("plc_status");
}

/**
 * 点动脉冲线圈"按 1 松 0"。
 * @param m M 软元件号（如 M201 传 201，后端按 m_base 换算）
 * @param on true=按下写 ON，false=松开发 OFF（不设超时自动复位）
 */
export function coilSet(m: number, on: boolean): Promise<void> {
  return invoke("coil_set", { m, on });
}

/** 轴参数回读结果：enable=null 表示该轴无使能线圈（电推杆） */
export interface AxisSnapshot {
  enable: boolean | null;
  values: number[];
}

/**
 * 进入调试页/切换轴时回读某轴的使能线圈与各 D 参数（REAL，按 ds 顺序）。
 * enable 传 null 表示不读使能
 */
export function axisRead(
  enable: number | null,
  ds: number[]
): Promise<AxisSnapshot> {
  return invoke("axis_read", { enable, ds });
}

/**
 * 上升沿命令短脉冲（Inc+/Inc-/Abs/停止/运行/调试/退出/复位）。
 * 后端写 ON 后按 cmd_pulse_ms（默认 200ms）自动写 OFF
 */
export function coilPulse(m: number): Promise<void> {
  return invoke("coil_pulse", { m });
}

/** 保持型线圈取反（如调试使能 M200）：后端锁内读改写，返回取反后的新值 */
export function coilToggle(m: number): Promise<boolean> {
  return invoke("coil_toggle", { m });
}

/** 写 REAL 到 D 寄存器（占 D、D+1 两个寄存器，字节序按参数页配置） */
export function writeReal(d: number, v: number): Promise<void> {
  return invoke("write_real", { d, v });
}

/** 一键清零所有当前置位的点动线圈（切页/窗口失焦/停止按钮调用） */
export function coilClearAll(): Promise<void> {
  return invoke("coil_clear_all");
}

// ---------- P4：运动数组 ----------

/** 数组上读结果：深度/模式 + rows[步][列]，列顺序见 config/arrayColumns.ts */
export interface ArrayDump {
  depth: number;
  mode: number;
  rows: number[][];
}

/** 数组下发入参：ArrayDump + 可选关联配方 id（用于写 download_log） */
export interface ArrayUploadReq extends ArrayDump {
  /** 当前载入的配方 id；未关联配方（直接编辑下发）时为 null/省略 */
  arrayId?: number | null;
}

/**
 * 运动数组下发：按段 FC16 批量写 D2000 起 13 段数据，最后写 D1100/D1101。
 * 后端做范围校验，超限返回错误且不产生任何写入；每次调用均写一条下发记录
 */
export function arrayUpload(payload: ArrayUploadReq): Promise<void> {
  return invoke("array_upload", { req: payload });
}

/** 运动数组上读（点一次读一次，不轮询、不订阅） */
export function arrayDownload(): Promise<ArrayDump> {
  return invoke("array_download");
}
