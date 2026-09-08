(*============================================================================
  FC_DefaultConditionParams —— 调理参数工厂默认（P5）
  ----------------------------------------------------------------------------
  返回一整套 Stru_CondParams 出厂值（三轴 16 段往复 + 全局）。
  ⚠ 默认值仅为安全可校验的保守占位，现场须由工程师按工艺调试后 Save。
  单位：位置 °（脉冲当量见轴 Config）、速度 °/s、加减速 °/s²、时间 ms。
==========================================================================*)
FUNCTION FC_DefaultConditionParams : Stru_CondParams

(*--- 扭腰 SeatTwist：默认单段 ±10°、2 °/s、1 循环 ---*)
FC_DefaultConditionParams.SeatTwist.rAcc             := 20.0;
FC_DefaultConditionParams.SeatTwist.rDec             := 20.0;
FC_DefaultConditionParams.SeatTwist.rInitialPosition := 0.0;
FC_DefaultConditionParams.SeatTwist.iVelocityMode    := 0;
FC_DefaultConditionParams.SeatTwist.iCycleModeLen    := 1;
FC_DefaultConditionParams.SeatTwist.iCycleCount      := -1;
FC_DefaultConditionParams.SeatTwist.iSignalMode      := -1;
FC_DefaultConditionParams.SeatTwist.iSegmentCount    := 1;
FC_DefaultConditionParams.SeatTwist.bEnabled         := TRUE;
FC_DefaultConditionParams.SeatTwist.bOneWay          := FALSE;
FC_DefaultConditionParams.SeatTwist.arPosition[0]    := 10.0;
FC_DefaultConditionParams.SeatTwist.arVelocity[0]    := 2.0;
FC_DefaultConditionParams.SeatTwist.abCycleMode[0]   := FALSE;

(*--- 摆腿 LegAngle：默认单段 +15° ---*)
FC_DefaultConditionParams.LegAngle.rAcc             := 20.0;
FC_DefaultConditionParams.LegAngle.rDec             := 20.0;
FC_DefaultConditionParams.LegAngle.rInitialPosition := 0.0;
FC_DefaultConditionParams.LegAngle.iVelocityMode    := 0;
FC_DefaultConditionParams.LegAngle.iCycleModeLen    := 1;
FC_DefaultConditionParams.LegAngle.iCycleCount      := -1;
FC_DefaultConditionParams.LegAngle.iSignalMode      := -1;
FC_DefaultConditionParams.LegAngle.iSegmentCount    := 1;
FC_DefaultConditionParams.LegAngle.bEnabled         := TRUE;
FC_DefaultConditionParams.LegAngle.bOneWay          := FALSE;
FC_DefaultConditionParams.LegAngle.arPosition[0]    := 15.0;
FC_DefaultConditionParams.LegAngle.arVelocity[0]    := 3.0;
FC_DefaultConditionParams.LegAngle.abCycleMode[0]   := FALSE;

(*--- 冲击 ChestImpact：默认单段 +5°、较快 5 °/s ---*)
FC_DefaultConditionParams.ChestImpact.rAcc             := 30.0;
FC_DefaultConditionParams.ChestImpact.rDec             := 30.0;
FC_DefaultConditionParams.ChestImpact.rInitialPosition := 0.0;
FC_DefaultConditionParams.ChestImpact.iVelocityMode    := 0;
FC_DefaultConditionParams.ChestImpact.iCycleModeLen    := 1;
FC_DefaultConditionParams.ChestImpact.iCycleCount      := -1;
FC_DefaultConditionParams.ChestImpact.iSignalMode      := -1;
FC_DefaultConditionParams.ChestImpact.iSegmentCount    := 1;
FC_DefaultConditionParams.ChestImpact.bEnabled         := TRUE;
FC_DefaultConditionParams.ChestImpact.bOneWay          := FALSE;
FC_DefaultConditionParams.ChestImpact.arPosition[0]    := 5.0;
FC_DefaultConditionParams.ChestImpact.arVelocity[0]    := 5.0;
FC_DefaultConditionParams.ChestImpact.abCycleMode[0]   := FALSE;

(*--- 全局 ---*)
FC_DefaultConditionParams.rPusherPos       := 0.0;      (* 成角目标 °（尾板） *)
FC_DefaultConditionParams.rPusherInitPos   := 0.0;
FC_DefaultConditionParams.diBatchCount     := 1;        (* 老化批次数 *)
FC_DefaultConditionParams.diBatchInterval  := 5000;     (* 批次间隔 ms *)
FC_DefaultConditionParams.diTotalTimeout   := 300000;   (* 总超时 5 min *)
FC_DefaultConditionParams.diConfirmTimeout := 30000;    (* 确认超时 30 s *)
FC_DefaultConditionParams.iCycleCount      := 1;        (* 全局循环次数 *)
FC_DefaultConditionParams.iSignalMode      := 0;        (* 0=脚踏 1=自动 *)

END_FUNCTION
