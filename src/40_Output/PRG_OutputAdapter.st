(*============================================================================
  PRG_OutputAdapter —— 层 40 输出：执行器 + MC 指令唯一调用点（扫描链第 10 环）
  ----------------------------------------------------------------------------
  实例化：fbAxisChest / fbAxisSeat / fbAxisLeg : FB_AxisControl（三轴各一）；
          fbPusher : FB_PusherControl（电推杆，第 5 节调用）。
  唯一写入：
    - 三轴轴结构体命令字段（bPowerOn/bAbsPos/bJogP…，经 FB_AxisControl 内部直写）；
    - HMI.<Axis>.Status（stStatus 全量回填）；
    - 内部汇总位 bAllAxesIdle / bAllAxesRef / bAllAxesAtInit（MODE_MANAGER 读）；
    - 轴故障事件 gFault*（每扫至多 1 条序列化提交，ERROR_MANAGER 第 4 环消费）。
  读入：
    - axisPowerEnable[0..2]（POWER 第 9 环使能电平）、bSafetyStop（SAFETY）；
    - axisPulse[i,AXCMD_*]（脉冲命令）、axisJogPos/Neg[i]（点动电平）；
    - HMI.<Axis>.Motion（手动目标/速度/加减速）、runAxis[i]（限位/容差/初始位/超时）、
      runCond.<Axis>（16 段缓冲段表）、retainZeroComm[i]（建零标志）；
    - trigLearnBias（冲击轴扭矩基线学习，仅 Chest）。
  故障序列化：gFaultSubmit 同扫后写覆盖先写，故本环每扫至多提交 1 条：
    Critical(2) 优先于 Warning(1)；同级按轴序 Chest→Seat→Leg；
    gFaultSource 用故障轴号（AXIS_ID_CHEST=1 / LEG=2 / SEAT=3）。
  轴下标双轨：内部数组 base 0，下标 0=Chest冲击 / 1=Seat扭角 / 2=Leg转角；
    故障轴号 iAxisId：Chest→AXIS_ID_CHEST(1)、Seat→AXIS_ID_SEAT(3)、Leg→AXIS_ID_LEG(2)。
  推杆：第 5 节完整实现（FB 调用 + 状态回填 + Y5/Y6 输出，硬急停物理切断）。
==========================================================================*)
PROGRAM PRG_OutputAdapter
VAR
    fbAxisChest : FB_AxisControl;   (* 冲击轴（内部下标 0，Axis_胸背） *)
    fbAxisSeat  : FB_AxisControl;   (* 扭角轴（内部下标 1，Axis_臀盘） *)
    fbAxisLeg   : FB_AxisControl;   (* 转角轴（内部下标 2，Axis_臀腿） *)
    fbPusher    : FB_PusherControl; (* 尾板电推杆（开关型，Y5/Y6） *)
END_VAR

(*------------------------------------------------------------
  1) 三轴 FB 调用（参数接线；轴引用/使能/命令/限位/段表/建零/力估算）
------------------------------------------------------------*)
(* 1.1 冲击轴 Chest（内部下标 0）：扭矩基线学习仅本轴接 trigLearnBias *)
fbAxisChest(
    Axis            := Axis_胸背,
    iAxisId         := AXIS_ID_CHEST,
    bEnable         := axisPowerEnable[0],
    bReset          := axisPulse[0, AXCMD_RESET],
    bZeroComm       := axisPulse[0, AXCMD_ZERO_COMM],
    bStop           := axisPulse[0, AXCMD_STOP],
    bMoveAbs        := axisPulse[0, AXCMD_MOVEABS],
    bMoveRel        := axisPulse[0, AXCMD_MOVEREL],
    bJogPos         := axisJogPos[0],
    bJogNeg         := axisJogNeg[0],
    bMoveBuffer     := axisPulse[0, AXCMD_MOVEBUFFER],
    arSegPos        := runCond.ChestImpact.arPosition,
    arSegVel        := runCond.ChestImpact.arVelocity,
    iSegCount       := runCond.ChestImpact.iSegmentCount,
    rTargetPos      := HMI.ChestImpact.Motion.rTargetPos,
    rTargetVel      := HMI.ChestImpact.Motion.rTargetVel,
    rJogVel         := HMI.ChestImpact.Motion.rJogVel,
    rAcc            := HMI.ChestImpact.Motion.rAcc,
    rDec            := HMI.ChestImpact.Motion.rDec,
    rInitPos        := runAxis[0].rInitPos,
    rPosLimit       := runAxis[0].rPosLimit,
    rNegLimit       := runAxis[0].rNegLimit,
    rTolerance      := runAxis[0].rTolerance,
    diTimeout       := runAxis[0].diTimeout,
    bSafetyStop     := bSafetyStop,
    bZeroCommRetain := retainZeroComm[0],
    bLearnBias      := trigLearnBias,
    rForceScaleN    := FORCE_SCALE_N,
    rOverForceN     := OVERFORCE_N
);

(* 1.2 扭角轴 Seat（内部下标 1，故障轴号 AXIS_ID_SEAT=3） *)
fbAxisSeat(
    Axis            := Axis_臀盘,
    iAxisId         := AXIS_ID_SEAT,
    bEnable         := axisPowerEnable[1],
    bReset          := axisPulse[1, AXCMD_RESET],
    bZeroComm       := axisPulse[1, AXCMD_ZERO_COMM],
    bStop           := axisPulse[1, AXCMD_STOP],
    bMoveAbs        := axisPulse[1, AXCMD_MOVEABS],
    bMoveRel        := axisPulse[1, AXCMD_MOVEREL],
    bJogPos         := axisJogPos[1],
    bJogNeg         := axisJogNeg[1],
    bMoveBuffer     := axisPulse[1, AXCMD_MOVEBUFFER],
    arSegPos        := runCond.SeatTwist.arPosition,
    arSegVel        := runCond.SeatTwist.arVelocity,
    iSegCount       := runCond.SeatTwist.iSegmentCount,
    rTargetPos      := HMI.SeatTwist.Motion.rTargetPos,
    rTargetVel      := HMI.SeatTwist.Motion.rTargetVel,
    rJogVel         := HMI.SeatTwist.Motion.rJogVel,
    rAcc            := HMI.SeatTwist.Motion.rAcc,
    rDec            := HMI.SeatTwist.Motion.rDec,
    rInitPos        := runAxis[1].rInitPos,
    rPosLimit       := runAxis[1].rPosLimit,
    rNegLimit       := runAxis[1].rNegLimit,
    rTolerance      := runAxis[1].rTolerance,
    diTimeout       := runAxis[1].diTimeout,
    bSafetyStop     := bSafetyStop,
    bZeroCommRetain := retainZeroComm[1],
    bLearnBias      := FALSE,
    rForceScaleN    := FORCE_SCALE_N,
    rOverForceN     := OVERFORCE_N
);

(* 1.3 转角轴 Leg（内部下标 2，故障轴号 AXIS_ID_LEG=2） *)
fbAxisLeg(
    Axis            := Axis_臀腿,
    iAxisId         := AXIS_ID_LEG,
    bEnable         := axisPowerEnable[2],
    bReset          := axisPulse[2, AXCMD_RESET],
    bZeroComm       := axisPulse[2, AXCMD_ZERO_COMM],
    bStop           := axisPulse[2, AXCMD_STOP],
    bMoveAbs        := axisPulse[2, AXCMD_MOVEABS],
    bMoveRel        := axisPulse[2, AXCMD_MOVEREL],
    bJogPos         := axisJogPos[2],
    bJogNeg         := axisJogNeg[2],
    bMoveBuffer     := axisPulse[2, AXCMD_MOVEBUFFER],
    arSegPos        := runCond.LegAngle.arPosition,
    arSegVel        := runCond.LegAngle.arVelocity,
    iSegCount       := runCond.LegAngle.iSegmentCount,
    rTargetPos      := HMI.LegAngle.Motion.rTargetPos,
    rTargetVel      := HMI.LegAngle.Motion.rTargetVel,
    rJogVel         := HMI.LegAngle.Motion.rJogVel,
    rAcc            := HMI.LegAngle.Motion.rAcc,
    rDec            := HMI.LegAngle.Motion.rDec,
    rInitPos        := runAxis[2].rInitPos,
    rPosLimit       := runAxis[2].rPosLimit,
    rNegLimit       := runAxis[2].rNegLimit,
    rTolerance      := runAxis[2].rTolerance,
    diTimeout       := runAxis[2].diTimeout,
    bSafetyStop     := bSafetyStop,
    bZeroCommRetain := retainZeroComm[2],
    bLearnBias      := FALSE,
    rForceScaleN    := FORCE_SCALE_N,
    rOverForceN     := OVERFORCE_N
);

(*------------------------------------------------------------
  2) 状态回填 HMI（结构体直传；推杆 stStatus 见第 5 节调用后回填）
------------------------------------------------------------*)
HMI.ChestImpact.Status := fbAxisChest.stStatus;
HMI.SeatTwist.Status   := fbAxisSeat.stStatus;
HMI.LegAngle.Status    := fbAxisLeg.stStatus;

(*------------------------------------------------------------
  3) 故障事件序列化提交（每扫至多 1 条：Critical(2) 优先于 Warning(1)；
     同级按源序 Chest→Seat→Leg→Pusher；源号用 AXIS_ID_* / SRC_PUSHER）
------------------------------------------------------------*)
oaISel := 0;
IF fbAxisChest.bFaultEvent AND (fbAxisChest.iFaultLevel = 2) THEN
    oaISel := 1;
ELSIF fbAxisSeat.bFaultEvent AND (fbAxisSeat.iFaultLevel = 2) THEN
    oaISel := 2;
ELSIF fbAxisLeg.bFaultEvent AND (fbAxisLeg.iFaultLevel = 2) THEN
    oaISel := 3;
ELSIF fbPusher.bFaultEvent AND (fbPusher.iFaultLevel = 2) THEN
    oaISel := 4;
ELSIF fbAxisChest.bFaultEvent THEN
    oaISel := 1;
ELSIF fbAxisSeat.bFaultEvent THEN
    oaISel := 2;
ELSIF fbAxisLeg.bFaultEvent THEN
    oaISel := 3;
ELSIF fbPusher.bFaultEvent THEN
    oaISel := 4;
END_IF;

CASE oaISel OF
    1:  gFaultSubmit := TRUE; gFaultLevel := fbAxisChest.iFaultLevel;
        gFaultCode := fbAxisChest.iFaultCode; gFaultSource := AXIS_ID_CHEST;
        gFaultSubCode := fbAxisChest.iFaultSub; gFaultVal1 := 0; gFaultVal2 := 0;
    2:  gFaultSubmit := TRUE; gFaultLevel := fbAxisSeat.iFaultLevel;
        gFaultCode := fbAxisSeat.iFaultCode; gFaultSource := AXIS_ID_SEAT;
        gFaultSubCode := fbAxisSeat.iFaultSub; gFaultVal1 := 0; gFaultVal2 := 0;
    3:  gFaultSubmit := TRUE; gFaultLevel := fbAxisLeg.iFaultLevel;
        gFaultCode := fbAxisLeg.iFaultCode; gFaultSource := AXIS_ID_LEG;
        gFaultSubCode := fbAxisLeg.iFaultSub; gFaultVal1 := 0; gFaultVal2 := 0;
    4:  gFaultSubmit := TRUE; gFaultLevel := fbPusher.iFaultLevel;
        gFaultCode := fbPusher.iErrorCode; gFaultSource := SRC_PUSHER;
        gFaultSubCode := 0; gFaultVal1 := 0; gFaultVal2 := 0;
ELSE
    ;
END_CASE;

(*------------------------------------------------------------
  4) 全轴汇总位（MODE_MANAGER READY_CHECK / 状态显示读）
------------------------------------------------------------*)
bAllAxesIdle := HMI.ChestImpact.Status.Servo.bStandStill
            AND HMI.SeatTwist.Status.Servo.bStandStill
            AND HMI.LegAngle.Status.Servo.bStandStill;
bAllAxesRef  := HMI.ChestImpact.Status.Servo.bZeroCommissioned
            AND HMI.SeatTwist.Status.Servo.bZeroCommissioned
            AND HMI.LegAngle.Status.Servo.bZeroCommissioned;
bAllAxesAtInit := HMI.ChestImpact.Status.bAtInit
            AND HMI.SeatTwist.Status.bAtInit
            AND HMI.LegAngle.Status.bAtInit;

(*------------------------------------------------------------
  5) 电推杆（P8 完整实现）
------------------------------------------------------------*)
(* 5.1 fbPusher 调用：命令位/原点传感器/HSC mm 位置/参数/Retain 接线；
       安全停车 bSafetyStop（含软急停/保护停机）与失能由 FB 内部断输出回空闲；
       硬急停在此处再物理切断 Y5/Y6（双保险，FB 不再驱动）。 *)
fbPusher(
    bEnable        := pushEnableReq,
    bJogUp         := jogPushUp,
    bJogDown       := jogPushDown,
    bHome          := trigPushHome,
    bCalibrate     := trigPushCalibrate,
    bAutoMove      := trigPushAutoMove,
    bManualPreset  := trigPushPreset,
    bResetError    := trigPushResetError,
    bStop          := trigPushStop,
    rTargetAngle   := HMI.TailTilt.Motion.rTargetAngle,
    bHomeSwitch    := ioPusherOrigin,
    rPosMm         := rPusherPosMm,
    bPosValid      := bPusherPosValid,
    bSafetyStop    := bSafetyStop OR bHardEstop,
    stConfig       := runPusher,
    stMotion       := HMI.TailTilt.Motion,
    bCalibRetain   := retainTailZeroComm
);

(* 5.2 状态回填 HMI；标定完成单扫脉冲 bCalibDone 转跨环锁存 bPushCalibDoneLatch
       （环10 置、环8 ParamService 消费写 retainTailZeroComm；不入 CmdPreclear 清扫表） *)
HMI.TailTilt.Status := fbPusher.stStatus;
(* 几何解算角度回填 D936 窗口（mm/有效位由环3 Monitor 镜像，角度本环 fbPusher 才算出） *)
HMI.TailTiltAdFeedback.rAngle := fbPusher.rCurrAngle;
IF fbPusher.bCalibDone THEN
    bPushCalibDoneLatch := TRUE;
END_IF;

(* 5.3 请求位转写物理输出：bInvertPusherDirection 交换两输出；硬急停物理切断 *)
IF bHardEstop THEN
    Q_Pusher_Up   := FALSE;
    Q_Pusher_Down := FALSE;
ELSIF runPusher.bInvertPusherDirection THEN
    Q_Pusher_Up   := fbPusher.bRunDown;
    Q_Pusher_Down := fbPusher.bRunUp;
ELSE
    Q_Pusher_Up   := fbPusher.bRunUp;
    Q_Pusher_Down := fbPusher.bRunDown;
END_IF;

END_PROGRAM
