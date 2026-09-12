import { invoke } from "@tauri-apps/api/core";

/** 单个报警/操作提示点状态 */
export interface AlarmItem {
  /** M 软元件号（如 M300 为 300） */
  addr: number;
  name: string;
  on: boolean;
}

/** 当前报警/提示/动作步快照（plc::alarm_state 事件载荷、alarm_current 返回） */
export interface AlarmSnapshot {
  /** 全部报警点当前电平（顺序与后端点表一致） */
  alarms: AlarmItem[];
  /** 地址最大且 TRUE 的操作提示；无提示为 null */
  prompt: AlarmItem | null;
  /** D400 动作步索引；尚未读到为 null */
  stepIndex: number | null;
}

/** alarm_log 一条记录 */
export interface AlarmLogEntry {
  id: number;
  addr: number;
  name: string;
  /** raised=报警发生 / cleared=报警解除 */
  kind: "raised" | "cleared";
  /** 本地时间 "YYYY-MM-DD HH:MM:SS" */
  ts: string;
}

/** 全部报警点电平（变化时/重连首拍推送） */
export const PLC_ALARM_STATE_EVENT = "plc::alarm_state";
/** 最高地址 TRUE 操作提示（变化时推送，无提示为 null） */
export const PLC_PROMPT_EVENT = "plc::prompt";
/** D400 动作步（每拍推送） */
export const PLC_STEP_INDEX_EVENT = "plc::step_index";

/** 报警记录时段查询：begin/end 为本地时间字符串，传 null 表示该端不限 */
export function alarmLogs(
  begin: string | null,
  end: string | null,
  limit?: number
): Promise<AlarmLogEntry[]> {
  return invoke("alarm_logs", { begin, end, limit: limit ?? null });
}

/** 读 D300~D302 三轴故障码（原始 u16，前端按 4 位 HEX 显示） */
export function faultCodesRead(): Promise<number[]> {
  return invoke("fault_codes_read");
}

/** 首屏同步：后端内存中的当前报警/提示/动作步快照 */
export function alarmCurrent(): Promise<AlarmSnapshot> {
  return invoke("alarm_current");
}
