(*============================================================================
  HMI 寄存器映射全局变量（D 区 / %MW）
  ----------------------------------------------------------------------------
  变量名 : 结构体类型           地址          范围           方向
    HMI                      Stru_HMI                     AT %MW200   D200–D940    双向
    HMI_DeviceIdentity       Stru_HMI_DeviceInfo          AT %MW1000  D1000–D1004  PLC→HMI 只读
    HMI_DeviceIdentityWrite  Stru_HMI_DeviceIdentityWrite AT %MW1010  D1010–D1013  双向

  注：变量名与类型名同名（用户指定）。
  HMI 为旧工程导出的主结构体，nBitLen=11856 bit = 741 字，下载后须核对
  InoProShop 变量表中 HMI 长度与基址与旧工程一致。
==========================================================================*)
VAR_GLOBAL
    HMI                     : Stru_HMI                     AT %MW200;   (* D200–D940  *)
    HMI_DeviceIdentity      : Stru_HMI_DeviceInfo          AT %MW1000;  (* D1000–D1004 *)
    HMI_DeviceIdentityWrite : Stru_HMI_DeviceIdentityWrite AT %MW1010;  (* D1010–D1013 *)
END_VAR
