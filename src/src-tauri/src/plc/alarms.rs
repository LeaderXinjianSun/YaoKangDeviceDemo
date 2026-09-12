//! P6 报警/操作提示点表与事件载荷。
//!
//! 报警 M300~M399、操作提示 M400~M499（实际使用点见下）；故障码 D300~D302；动作步 D400。

use serde::Serialize;

/// FC01 一次读 M300~M401 共 102 个连续线圈（M323~M399 等空洞按下标忽略）
pub(crate) const WATCH_M_START: u16 = 300;
pub(crate) const WATCH_M_CNT: u16 = 102;

/// M300~M399 报警点（程序实际使用的 10 点，按地址升序）
/// 第三列 log=false 表示只显示、不做边沿落库：
/// M320「暂停」是其他报警的必然结果（其他报警是其触发条件），记日志无额外信息。
pub(crate) const ALARM_POINTS: &[(u16, &str, bool)] = &[
    (300, "胸背轴报警", true),
    (301, "臀腿轴报警", true),
    (302, "臀盘轴报警", true),
    (303, "推杆轴堵转", true),
    (310, "急停按钮1按下", true),
    (311, "急停按钮2按下", true),
    (312, "安全继电器报警", true),
    (320, "暂停", false),
    (321, "停止按钮按下", true),
    (322, "上位机失联", true),
];

/// M400~M499 操作提示点
pub(crate) const PROMPT_POINTS: &[(u16, &str)] = &[(400, "请按复位按钮"), (401, "请按脚踏")];

/// D400 当前动作步索引（INT16）
pub(crate) const STEP_D: u16 = 400;

/// D300~D302 胸背/臀腿/臀盘轴故障码（原始 u16，前端按 4 位 HEX 显示）
pub(crate) const FAULT_D: u16 = 300;
pub(crate) const FAULT_CNT: u16 = 3;

/// 单个报警/提示点状态（plc::alarm_state 元素、plc::prompt 事件载荷）
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub(crate) struct AlarmItem {
    pub addr: u16,
    pub name: String,
    pub on: bool,
}

/// 当前报警/提示/动作步快照（alarm_current 命令返回，首屏同步用）
#[derive(Debug, Clone, Serialize, Default)]
pub(crate) struct AlarmSnapshot {
    /// 全部报警点当前电平（顺序同 ALARM_POINTS）
    pub alarms: Vec<AlarmItem>,
    /// 地址最大且 TRUE 的操作提示；无提示时为 None
    pub prompt: Option<AlarmItem>,
    /// D400 动作步索引（INT16）；尚未读到时为 None
    #[serde(rename = "stepIndex")]
    pub step_index: Option<i16>,
}
