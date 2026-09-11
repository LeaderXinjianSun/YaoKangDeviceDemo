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
