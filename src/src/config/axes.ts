/**
 * 四轴配置表（技术方案 3.1/3.3）：
 * - 胸背 M200~M205 / D1000~D1004；臀腿 M206~M211 / D1006~D1010；
 * - 臀盘 M212~M217 / D1012~D1016；电推杆仅 Jog±(M219/M220)+Abs(M221) / D1018。
 * 页面只按此表驱动，不复制四份控件。
 */

export interface AxisParam {
  /** D 软元件号（REAL，占两个寄存器） */
  d: number;
  label: string;
  unit: string;
}

export interface AxisConfig {
  key: string;
  name: string;
  /** 坐标单位（胸背 mm，其余 °） */
  unit: string;
  /** 调试使能（保持型）；电推杆无 */
  enable?: number;
  jogPlus: number;
  jogMinus: number;
  /** Inc+ / Inc-（按 1 松 0）；电推杆无 */
  incPlus?: number;
  incMinus?: number;
  /** Abs 定位（上升沿短脉冲） */
  abs?: number;
  /** 调试参数：速度 / Inc 距离 / Abs 目标，按轴能力裁剪 */
  params: AxisParam[];
}

export const AXES: AxisConfig[] = [
  {
    key: "chestBack",
    name: "胸背轴",
    unit: "mm",
    enable: 200,
    jogPlus: 201,
    jogMinus: 202,
    incPlus: 203,
    incMinus: 204,
    abs: 205,
    params: [
      { d: 1000, label: "调试速度", unit: "mm/s" },
      { d: 1002, label: "点动(Inc)距离", unit: "mm" },
      { d: 1004, label: "目标位置(Abs)", unit: "mm" },
    ],
  },
  {
    key: "hipLeg",
    name: "臀腿轴",
    unit: "°",
    enable: 206,
    jogPlus: 207,
    jogMinus: 208,
    incPlus: 209,
    incMinus: 210,
    abs: 211,
    params: [
      { d: 1006, label: "调试速度", unit: "°/s" },
      { d: 1008, label: "点动(Inc)距离", unit: "°" },
      { d: 1010, label: "目标位置(Abs)", unit: "°" },
    ],
  },
  {
    key: "hipDisc",
    name: "臀盘轴",
    unit: "°",
    enable: 212,
    jogPlus: 213,
    jogMinus: 214,
    incPlus: 215,
    incMinus: 216,
    abs: 217,
    params: [
      { d: 1012, label: "调试速度", unit: "°/s" },
      { d: 1014, label: "点动(Inc)距离", unit: "°" },
      { d: 1016, label: "目标位置(Abs)", unit: "°" },
    ],
  },
  {
    key: "pushrod",
    name: "电推杆",
    unit: "°",
    jogPlus: 219,
    jogMinus: 220,
    abs: 221,
    params: [{ d: 1018, label: "目标位置(Abs)", unit: "°" }],
  },
];

/** 全局控制线圈（与当前轴无关） */
export const M_RUN = 110;
export const M_DEBUG = 111;
export const M_EXIT_DEBUG = 120;
export const M_RESET = 102;
export const M_DEBUG_STOP = 218;
export const M_STOP = 101;
