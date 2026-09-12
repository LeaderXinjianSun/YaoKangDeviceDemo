//! P1：PLC 长连接、D210 心跳、按需订阅。

mod address;
pub(crate) mod alarms;
pub(crate) mod arrays;
mod codec;

pub(crate) mod client;
pub(crate) use client::{Plc, PlcConfig};
