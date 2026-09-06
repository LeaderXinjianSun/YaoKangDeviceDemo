(*============================================================================
  FB_AxisControl —— 单轴伺服控制（M900，CiA402 / PLCopen MC），三轴各实例化一个
  ----------------------------------------------------------------------------
  职责：封装单轴使能/复位/回零/点动/绝对/相对/缓冲段运动与状态回读；
        软限位、到位判定、步骤计时；MC 指令的实际调用点在 OUTPUT_ADAPTER，
        本 FB 持有轴级状态机与参数（P7 落地接线）。
  实例化：ChestImpact / SeatTwist / LegAngle 各一（三轴同构复用）。
  线结构体：HMI.<Axis>.Status/Cmd/Motion/Config/ConfigCmd（字段见 ST_StruHMI.st）。
  P1：接口骨架。P7：运动状态机 + 力估算接口（Force 块）+ 限位。
==========================================================================*)
FUNCTION_BLOCK FB_AxisControl
VAR_INPUT
    Axis        : AXIS_REF;          (* EtherCAT 轴引用（Axis_胸背/臀盘/臀腿） *)
    bEnable     : BOOL;              (* 使能（源：POWER 分时上电） *)
    bReset      : BOOL;              (* 复位轴错误（脉冲） *)
    bHome       : BOOL;              (* 原点标定 MC_Home（仅工厂建零，脉冲） *)
    bStop       : BOOL;              (* 立即减速停车 *)
    bMoveAbs    : BOOL;              (* 绝对定位（脉冲） *)
    bMoveRel    : BOOL;              (* 相对定位（脉冲） *)
    bJogPos     : BOOL;              (* 正向点动（电平） *)
    bJogNeg     : BOOL;              (* 负向点动（电平） *)
    rTargetPos  : REAL;              (* 目标位置 *)
    rTargetVel  : REAL;              (* 目标速度 *)
    rJogVel     : REAL;              (* 点动速度 *)
    rAcc        : REAL;
    rDec        : REAL;
    bSafetyStop : BOOL;              (* 安全链停车（硬/软急停） *)
END_VAR
VAR_OUTPUT
    bEnabled    : BOOL;              (* 已使能 *)
    bStandStill : BOOL;              (* 静止 *)
    bInPosition : BOOL;              (* 到位 *)
    bAtInit     : BOOL;              (* 在初始位容差内 *)
    bError      : BOOL;              (* 轴错误 *)
    iErrorCode  : INT;               (* 轴错误码（9xxx） *)
    rActPos     : REAL;              (* 实际位置 *)
END_VAR
VAR
    iStep       : INT;
    (* H5U 定时器为内联指令 TONR(IN:=,PT:=,Q=>布尔位)，无需 TON 实例：
       tStepTimer 即 TONR 的 Q=> 输出 BOOL（步骤定时到标志）。 *)
    tStepTimer  : BOOL;  (* 步骤超时标志（P7：TONR Q=>tStepTimer） *)
END_VAR

(* TODO P7:
   - 运动状态机：IDLE → ENABLING → READY → (JOG | MOVE_ABS | MOVE_REL | HOMING) → DONE/ERROR。
   - 软限位：rPosLimit/rNegLimit 越限拒绝并提交故障（2xxx）。
   - 到位判定：|ActPos - Target| <= rTolerance → bInPosition/bAtInit。
   - MC 指令经 OUTPUT_ADAPTER 统一调用（单写源），本 FB 输出轴级请求位。
   - 步骤超时 diTimeout → gFaultSubmit。
   - 力估算（Force 块）：扭矩基线学习、净扭矩、牵引力 N、超力锁存（P7/P4）。
   - bZeroCommissioned 建零标志镜像与 Retain（P9 建零门控）。 *)
END_FUNCTION_BLOCK
