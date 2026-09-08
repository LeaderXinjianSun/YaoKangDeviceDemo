(*============================================================================
  FC_DefaultHomingParams —— 回零参数工厂默认（P5）
  ----------------------------------------------------------------------------
  返回 Stru_HomingParams 出厂值（普通回零 + 紧急回零 Jog/防夹时序）。
  单位：速度 °/s、加减速 °/s²、扭矩 %、时间 ms。
==========================================================================*)
FUNCTION FC_DefaultHomingParams : Stru_HomingParams

(*--- 限位脱离 ---*)
FC_DefaultHomingParams.rLimitEscapeVel := 2.0;
(*--- 三轴 Jog 速度（内部轴序 1=Chest 2=Seat 3=Leg） ---*)
FC_DefaultHomingParams.rChestJogVel    := 5.0;
FC_DefaultHomingParams.rSeatJogVel     := 5.0;
FC_DefaultHomingParams.rLegJogVel      := 5.0;
(*--- 三轴接近微调（爬行）速度 ---*)
FC_DefaultHomingParams.rChestCrawlVel  := 0.5;
FC_DefaultHomingParams.rSeatCrawlVel   := 0.5;
FC_DefaultHomingParams.rLegCrawlVel    := 0.5;
(*--- 接近区（进入后切爬行） ---*)
FC_DefaultHomingParams.rChestApproachZone := 3.0;
FC_DefaultHomingParams.rSeatApproachZone  := 3.0;
FC_DefaultHomingParams.rLegApproachZone   := 3.0;
(*--- 到位迟滞窗口 ---*)
FC_DefaultHomingParams.rChestHysteresis := 0.3;
FC_DefaultHomingParams.rSeatHysteresis  := 0.3;
FC_DefaultHomingParams.rLegHysteresis   := 0.3;
(*--- Jog 加速度 ---*)
FC_DefaultHomingParams.rChestJogAcc := 20.0;
FC_DefaultHomingParams.rSeatJogAcc  := 20.0;
FC_DefaultHomingParams.rLegJogAcc   := 20.0;
(*--- 防夹扭矩限（净扭矩 %，紧急回零 Jog 超阈即停重试） ---*)
FC_DefaultHomingParams.rAntiPinchTorqueLimit := 40.0;
(*--- 超时/时序 ---*)
FC_DefaultHomingParams.diHomingTimeout         := 60000;   (* 普通回零全流程 60 s *)
FC_DefaultHomingParams.diEmergencyTimeout      := 30000;   (* 紧急回零 30 s *)
FC_DefaultHomingParams.diLimitEscapeTimeout    := 10000;   (* 限位脱离 10 s *)
FC_DefaultHomingParams.diStopReleaseTimeout    := 5000;    (* MC_Stop 释放等待 5 s *)
FC_DefaultHomingParams.diEmergencyCoastMs      := 500;     (* 停后滑行等待 *)
FC_DefaultHomingParams.diEmergencyStallTimeout := 2000;    (* 防夹堵转判定 2 s *)
(*--- 模式/重试 ---*)
FC_DefaultHomingParams.iHomingMode          := 0;         (* 0=顺序 1=并行（默认顺序） *)
FC_DefaultHomingParams.iMaxRetry            := 3;         (* 防夹重试上限 *)
FC_DefaultHomingParams.bEmergencyAllowCalib := FALSE;     (* 紧急回零默认不触发标定 *)

END_FUNCTION
