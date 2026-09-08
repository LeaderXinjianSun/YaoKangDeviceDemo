(*============================================================================
  FC_DefaultPusherConfig —— 电推杆（尾板）配置工厂默认（P5）
  ----------------------------------------------------------------------------
  返回 Stru_PusherLimitConfig 出厂值：开关型电推杆 + HC_Counter(mm) + 几何解算，
  全部角度阈值直接以 ° 为单位；堵转/超时/换向缓冲/软限位保留。
  ★ 结构体含 CSV 保留的 AD 字段（rPulsePerDeg/rAdOffset/rAdScale/rFitK0~K3/
    rAdJumpLimitDeg/diAdMin/diAdMax/diAdSampleMs/iReferenceMode）：本硬件无 AD，
    工厂默认一律不赋值（保持 0，iReferenceMode=0 即“脉冲+HC”模式），仅占布局。
  ⚠ 角度°阈值（rMinTravel/rInertiaUp/Down/rStallThreshold）为占位，
    必须现场调试后 Save；几何长度/补偿常量在 GVL_CONST（PUSHER_GEO_*）。
==========================================================================*)
FUNCTION FC_DefaultPusherConfig : Stru_PusherLimitConfig

FC_DefaultPusherConfig.rMaxDeg              := 80.0;     (* 正限位 ° *)
FC_DefaultPusherConfig.rMinDeg              := 0.0;      (* 负限位 ° *)
FC_DefaultPusherConfig.rTolerance           := 0.5;      (* 到位容差 ° *)
FC_DefaultPusherConfig.rInitialPosition     := 0.0;      (* 初始位置（回零目标）° *)
FC_DefaultPusherConfig.rMinTravel           := 2.0;      (* 堵转检测前最小行程 °（占位） *)
FC_DefaultPusherConfig.rHomePosition        := 0.0;      (* 原点位置 ° *)
FC_DefaultPusherConfig.rInertiaUp           := 1.0;      (* 角度增大向惯性补偿 °（占位） *)
FC_DefaultPusherConfig.rInertiaDown         := 1.0;      (* 角度减小向惯性补偿 °（占位） *)
FC_DefaultPusherConfig.rStallThreshold      := 0.5;      (* 堵转位移阈值 °（占位） *)
FC_DefaultPusherConfig.rStallSpeedThreshold := 0.5;      (* 堵转速度阈值 °/s（占位） *)
FC_DefaultPusherConfig.diStallTimeout       := 1000;     (* 堵转判定 1 s *)
FC_DefaultPusherConfig.diTimeout            := 30000;    (* 寻传感器/标定 30 s *)
FC_DefaultPusherConfig.diReverseDelay       := 500;      (* 换向缓冲 0.5 s *)
FC_DefaultPusherConfig.diStopCheck          := 500;      (* 停车滑行等待 0.5 s *)
FC_DefaultPusherConfig.iMaxRetries          := 3;        (* 最大修正次数 *)
FC_DefaultPusherConfig.bInvertPusherDirection := FALSE;  (* 输出方向不取反 *)

END_FUNCTION
