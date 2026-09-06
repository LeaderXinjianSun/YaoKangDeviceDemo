(*============================================================================
  物理 I/O 映射（H5U A8）—— 以 old/变量表/GVL_IoMap.csv（硬件组态导出）为准
  ----------------------------------------------------------------------------
  本机 I/O（CSV 软元件地址）：
    急停双通道：I_Estop1=X2、I_Estop2=X3（均常闭，FALSE=拍下）
    安全继电器：I_SafeRelay=X4（常开，TRUE=拍下）
    复位按钮：I_ResetBtn=X7
    推杆原点：I_PusherOrigin=X5；推杆限位：正/负（未接线，预留无地址）
    推杆输出：Q_Pusher_Up=Y5（上行/正转）、Q_Pusher_Down=Y6（下行/反转）
    扩展 AD：IW_PusherAd（未接线，预留无地址）
  注：InoProShop 中 X0..X7 ↔ %IX0.0..%IX0.7、Y0..Y7 ↔ %QX0.0..%QX0.7，
      下载后须按硬件组态核对 X/Y 与 %IX/%QX 映射；以下 % 地址由 Xn/Yn 推出。
  EtherCAT：3× M900 伺服轴引用 Axis_胸背/臀盘/臀腿在 H5U 配置文件（设备树）
      中已定义为全局变量，CSV 变量表不含；此处保留声明供 MC 指令引用，
      组态轴名须与这三个标识符逐字一致。
==========================================================================*)
VAR_GLOBAL
    (*--- 数字量输入（去抖在 INPUT_ADAPTER 完成） ---*)
    I_Estop1       AT %IX0.2 : BOOL;   (* 物理急停通道1（X2，常闭：FALSE=拍下） *)
    I_Estop2       AT %IX0.3 : BOOL;   (* 物理急停通道2（X3，常闭：FALSE=拍下） *)
    I_SafeRelay    AT %IX0.4 : BOOL;   (* 安全继电器（X4，常开：TRUE=拍下） *)
    I_PusherOrigin AT %IX0.5 : BOOL;   (* 电推杆原点传感器（X5） *)
    I_ResetBtn     AT %IX0.7 : BOOL;   (* 复位按钮（X7） *)
    I_PusherPosLim           : BOOL;   (* 推杆正限位（未接线，预留） *)
    I_PusherNegLim           : BOOL;   (* 推杆负限位（未接线，预留） *)

    (*--- 数字量输出 ---*)
    Q_Pusher_Up    AT %QX0.5 : BOOL;   (* 推杆上行/正转（Y5），方向取反由 Config 决定 *)
    Q_Pusher_Down  AT %QX0.6 : BOOL;   (* 推杆下行/反转（Y6） *)

    (*--- 扩展 AD（尾板角度反馈；未接线，预留，原始值在 INPUT_ADAPTER 换算） ---*)
    IW_PusherAd             : INT;     (* AD 原始值，通道以组态为准（未接线，预留无地址） *)

    (*--- EtherCAT 总线：3× M900 伺服（CiA402）轴引用（H5U 配置文件已定义，此处保留） ---*)
    Axis_胸背      : AXIS_REF;         (* 冲击轴（ChestImpact） *)
    Axis_臀盘      : AXIS_REF;         (* 扭角轴（SeatTwist）  *)
    Axis_臀腿      : AXIS_REF;         (* 转角轴（LegAngle）   *)
END_VAR
