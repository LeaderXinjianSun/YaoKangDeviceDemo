(*============================================================================
  GVL_Params —— 参数三区模型（P5）
  ----------------------------------------------------------------------------
  三区：
    编辑缓冲 = HMI D 区（HMI.Condition.Param / 各轴 .Config / HomingParams.Params /
               TailTilt.Config），HMI 直接读写，Apply 前不影响运行。
    运行区   = 本 GVL 的 run*（非保持），任务/运动 FB 只读本区；Apply 校验通过后
               由编辑缓冲覆盖；上电从 Retain 区装载，Retain 无效则用工厂默认。
    Retain区 = 本 GVL 的 retain*（VAR_GLOBAL RETAIN，断电保持），Save 时由运行区
               写入；含建零标志 bZeroCommissioned。
  单写源：本 GVL 全部变量仅 PRG_ParamService 可写，其余程序只读 run*。
  轴数组下标与全局约定一致：1=ChestImpact 冲击 / 2=SeatTwist 扭角 / 3=LegAngle 转角。
==========================================================================*)
VAR_GLOBAL
    (*--- 运行区（生效值，任务读） ---*)
    runCond             : Stru_CondParams;          (* 调理参数运行区 *)
    runAxis             : Stru_AxisLimitConfig[1..3];(* 三轴限位/运动配置运行区 *)
    runHoming           : Stru_HomingParams;        (* 回零参数运行区 *)
    runPusher           : Stru_PusherLimitConfig;   (* 推杆配置运行区 *)
    bRunParamValid      : BOOL;                     (* 运行区参数已成功 Apply（快照有效） *)

    (*--- 上电初始化标志（非保持，每次下载/上电首扫 FALSE） ---*)
    bParamBootDone      : BOOL;
END_VAR

VAR_GLOBAL RETAIN
    (*--- Retain 区（断电保持，Save 时写入） ---*)
    retainValid         : BOOL;                     (* Retain 区有效标志（首板为 FALSE→装默认） *)
    retainCond          : Stru_CondParams;          (* 调理参数保持区 *)
    retainAxis          : Stru_AxisLimitConfig[1..3];(* 三轴配置保持区 *)
    retainHoming        : Stru_HomingParams;       (* 回零参数保持区 *)
    retainPusher        : Stru_PusherLimitConfig;   (* 推杆配置保持区 *)
    retainZeroComm      : BOOL[1..3];               (* 三轴建零标志 bZeroCommissioned（工厂建零后置位） *)
    retainTailZeroComm  : BOOL;                     (* 推杆参考/标定保持标志 bCalibrated *)
    retainDeviceNo      : DINT;                     (* 设备编号保持区（工厂烧录/维护 Apply 写入） *)
END_VAR
