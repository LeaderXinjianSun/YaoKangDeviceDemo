(*============================================================================
  FC_DefaultAxisConfig —— 单轴限位/运动配置工厂默认（P5）
  ----------------------------------------------------------------------------
  返回 Stru_AxisLimitConfig 出厂值。三轴共用同一保守默认，现场按轴调试。
  ⚠ diPulsePerDeg 脉冲当量为占位，必须按 M900 电子齿轮/机械传动比核定后 Save。
==========================================================================*)
FUNCTION FC_DefaultAxisConfig : Stru_AxisLimitConfig

FC_DefaultAxisConfig.rPosLimit     := 90.0;     (* 正限位 ° *)
FC_DefaultAxisConfig.rNegLimit     := -90.0;    (* 负限位 ° *)
FC_DefaultAxisConfig.rInitPos      := 0.0;      (* 初始位置 ° *)
FC_DefaultAxisConfig.rTolerance    := 0.5;      (* 到位容差 ° *)
FC_DefaultAxisConfig.rMaxVel       := 50.0;     (* 最大速度 °/s *)
FC_DefaultAxisConfig.rMinVel       := 0.5;      (* 最小速度 °/s *)
FC_DefaultAxisConfig.rMaxAcc       := 100.0;    (* 最大加速度 °/s² *)
FC_DefaultAxisConfig.rMaxDec       := 100.0;    (* 最大减速度 °/s² *)
FC_DefaultAxisConfig.diPulsePerDeg := 10000;    (* 脉冲当量 Pulse/°（占位，待核定） *)
FC_DefaultAxisConfig.diTimeout     := 30000;    (* 定位超时 ms *)

END_FUNCTION
