//! 信捷软元件（D/M）到 Modbus 地址的换算。
//! 基址可按现场在参数页配置（m_base/d_base），默认 0。

/// 软元件映射基址：Modbus 地址 = 软元件号 - 软元件基址 + Modbus 基址
#[derive(Debug, Clone, Copy)]
pub struct PlcMap {
    /// D 寄存器对应的 Modbus 保持寄存器基址（信捷默认 0）
    pub d_base: u16,
    /// M 线圈对应的 Modbus 线圈基址
    pub m_base: u16,
}

impl PlcMap {
    /// Dn -> Modbus 保持寄存器地址
    pub fn d_reg(&self, d: u16) -> u16 {
        self.d_base + d
    }

    /// Mn -> Modbus 线圈地址
    pub fn m_coil(&self, m: u16) -> u16 {
        self.m_base + m
    }
}
