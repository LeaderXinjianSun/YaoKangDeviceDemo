//! P4 运动数组：D2000 起 16 步数据段布局、限值与写前校验。
//! 步内连续、每步占 2 个 D（REAL/DINT），段地址公式：reg = start + step * 2。
//! 前端每步行按本文件 SEGMENTS 同一顺序给出 13 个数值。

/// 数组深度寄存器（INT，1~16）
pub const DEPTH_D: u16 = 1100;
/// 运动模式寄存器（INT，1 调理 / 2 治疗 / 3 老化）；与深度连续，整体两寄存器读写，
/// 不单独寻址，故允许 dead_code（保留为布局事实源）
#[allow(dead_code)]
pub const MODE_D: u16 = 1101;

/// 最大步数
pub const MAX_DEPTH: usize = 16;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SegKind {
    /// REAL 占 2 个寄存器
    Real,
    /// DINT 占 2 个寄存器（仅运动间隔）
    Dint,
}

/// 一个数据段：起始 D 号、步容量、类型、上限（None=地址表未给限值）
#[derive(Debug, Clone, Copy)]
pub struct Segment {
    pub key: &'static str,
    pub start: u16,
    pub kind: SegKind,
    pub max: Option<f64>,
}

/// 13 个数据段，顺序即前端表格列/每步行数据顺序（见技术方案 3.4）
pub const SEGMENTS: [Segment; 13] = [
    Segment { key: "胸背坐标", start: 2000, kind: SegKind::Real, max: None },
    Segment { key: "臀腿坐标", start: 2032, kind: SegKind::Real, max: None },
    Segment { key: "臀盘坐标", start: 2064, kind: SegKind::Real, max: None },
    Segment { key: "胸背速度", start: 2096, kind: SegKind::Real, max: Some(500.0) },
    Segment { key: "臀腿速度", start: 2128, kind: SegKind::Real, max: Some(148.76) },
    Segment { key: "臀盘速度", start: 2160, kind: SegKind::Real, max: Some(148.76) },
    Segment { key: "胸背加速度", start: 2192, kind: SegKind::Real, max: Some(2500.0) },
    Segment { key: "臀腿加速度", start: 2224, kind: SegKind::Real, max: Some(743.8) },
    Segment { key: "臀盘加速度", start: 2256, kind: SegKind::Real, max: Some(743.8) },
    Segment { key: "胸背减速度", start: 2288, kind: SegKind::Real, max: Some(743.8) },
    Segment { key: "臀腿减速度", start: 2320, kind: SegKind::Real, max: Some(743.8) },
    Segment { key: "臀盘减速度", start: 2352, kind: SegKind::Real, max: Some(743.8) },
    Segment { key: "运动间隔", start: 2900, kind: SegKind::Dint, max: None },
];

/// 下发参数与写前校验
pub fn validate(depth: u16, mode: u16, rows: &[Vec<f64>]) -> Result<(), String> {
    if !(1..=MAX_DEPTH as u16).contains(&depth) {
        return Err(format!("数组深度须在 1~{} 之间（当前 {depth}）", MAX_DEPTH));
    }
    if !matches!(mode, 1 | 2 | 3) {
        return Err(format!("运动模式须为 1/2/3（当前 {mode}）"));
    }
    if rows.len() != depth as usize {
        return Err(format!("数据行数 {} 与深度 {depth} 不一致", rows.len()));
    }
    for (i, row) in rows.iter().enumerate() {
        if row.len() != SEGMENTS.len() {
            return Err(format!("第 {} 步数据列数为 {}，应为 {}", i + 1, row.len(), SEGMENTS.len()));
        }
        for (seg, v) in SEGMENTS.iter().zip(row) {
            if !v.is_finite() {
                return Err(format!("第 {} 步「{}」不是有效数字", i + 1, seg.key));
            }
            if matches!(seg.kind, SegKind::Dint) {
                if !(-2_147_483_648.0..=2_147_483_647.0).contains(v) {
                    return Err(format!("第 {} 步「{}」超出 DINT 范围", i + 1, seg.key));
                }
            }
            if let Some(max) = seg.max {
                if *v < 0.0 || *v > max {
                    return Err(format!("第 {} 步「{}」= {} 超出限值 0~{}", i + 1, seg.key, v, max));
                }
            }
        }
    }
    Ok(())
}
