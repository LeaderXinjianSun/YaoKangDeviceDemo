//! Modbus REAL（f32）四字序解码。
//! Modbus 连续两个保持寄存器构成 4 个字节，按寄存器先后记为 [a, b, c, d]：
//! ABCD=[a,b,c,d]（大端）、CDAB=[c,d,a,b]（字交换）、BADC=[b,a,d,c]（字节交换）、DCBA=[d,c,b,a]（小端）

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ByteOrder {
    Abcd,
    Cdab,
    Badc,
    Dcba,
}

impl ByteOrder {
    /// 解析参数页配置，未知值按信捷常用字序 CDAB 处理
    pub fn parse(s: &str) -> Self {
        match s.trim().to_ascii_uppercase().as_str() {
            "ABCD" => Self::Abcd,
            "BADC" => Self::Badc,
            "DCBA" => Self::Dcba,
            _ => Self::Cdab,
        }
    }
}

/// 两个保持寄存器 -> f32
pub fn decode_real(regs: [u16; 2], order: ByteOrder) -> f32 {
    let [hi, lo] = regs;
    let (a, b, c, d) = (hi >> 8, hi & 0xff, lo >> 8, lo & 0xff);
    let bytes: [u8; 4] = match order {
        ByteOrder::Abcd => [a as u8, b as u8, c as u8, d as u8],
        ByteOrder::Cdab => [c as u8, d as u8, a as u8, b as u8],
        ByteOrder::Badc => [b as u8, a as u8, d as u8, c as u8],
        ByteOrder::Dcba => [d as u8, c as u8, b as u8, a as u8],
    };
    f32::from_be_bytes(bytes)
}
