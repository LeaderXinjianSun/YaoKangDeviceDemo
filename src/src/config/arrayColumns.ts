/**
 * P4 运动数组列定义，顺序必须与后端 arrays.rs SEGMENTS 完全一致：
 * 3 列坐标 + 3 列速度 + 3 列加速度 + 3 列减速度 + 1 列运动间隔 = 13 列
 */
export interface ArrayColumn {
  /** 行数据下标（0~12） */
  key: number;
  /** 表头 */
  title: string;
  /** 单位 */
  unit: string;
  /** REAL(false) 或 DINT(true，仅运动间隔) */
  dint: boolean;
  /** 起始 D 号（便于排查地址） */
  start: number;
}

export const ARRAY_COLUMNS: ArrayColumn[] = [
  { key: 0, title: "胸背坐标", unit: "mm", dint: false, start: 2000 },
  { key: 1, title: "臀腿坐标", unit: "°", dint: false, start: 2032 },
  { key: 2, title: "臀盘坐标", unit: "°", dint: false, start: 2064 },
  { key: 3, title: "胸背速度", unit: "mm/s", dint: false, start: 2096 },
  { key: 4, title: "臀腿速度", unit: "°/s", dint: false, start: 2128 },
  { key: 5, title: "臀盘速度", unit: "°/s", dint: false, start: 2160 },
  { key: 6, title: "胸背加速度", unit: "mm/s²", dint: false, start: 2192 },
  { key: 7, title: "臀腿加速度", unit: "°/s²", dint: false, start: 2224 },
  { key: 8, title: "臀盘加速度", unit: "°/s²", dint: false, start: 2256 },
  { key: 9, title: "胸背减速度", unit: "mm/s²", dint: false, start: 2288 },
  { key: 10, title: "臀腿减速度", unit: "°/s²", dint: false, start: 2320 },
  { key: 11, title: "臀盘减速度", unit: "°/s²", dint: false, start: 2352 },
  { key: 12, title: "运动间隔", unit: "ms", dint: true, start: 2900 },
];

/** 最大步数（D1100） */
export const MAX_DEPTH = 16;

/** 运动模式（D1101）：1 调理 / 2 治疗 / 3 老化 */
export const MODE_OPTIONS = [
  { label: "调理", value: 1 },
  { label: "治疗", value: 2 },
  { label: "老化测试", value: 3 },
];
