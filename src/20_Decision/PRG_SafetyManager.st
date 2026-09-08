(*============================================================================
  PRG_SafetyManager —— 层 20 决策：安全防护（扫描链第 5 环），独立常驻
  ----------------------------------------------------------------------------
  唯一写入：bHardEstop / bSoftEstop / bProtStop / bHardEstopLatch / bSafetyStop；
            致命保护故障经 gFaultSubmit 提交（ERROR_MANAGER 入队）。
  读入：  ioEstopOK / ioEstop1 / ioEstop2（物理急停，去抖）；
          trigEmgStop（软急停脉冲）/ trigSysReset（复位脉冲，INPUT_ADAPTER 锁存，
          HMI 命令位已回清不可直读）；
          三轴 Status.Servo（bEncoderFault/bPosLimit/bNegLimit）、Force
          （bOverForce/bOverForceLatched）——OUTPUT_ADAPTER 镜像；
          推杆 Status.bError（堵转/超时由 FB_PusherControl 提交，本块不重复）。
  优先级：硬急停 > 软急停 > 保护停机；任何 iState 下都生效，不依赖业务状态。
  P4 落地：
    - 硬急停：物理链断开 OR 软急停超时升级锁存；断使能（POWER 读 bHardEstop）。
    - 双通道不一致诊断：两通道去抖态分歧持续 → 1003 Critical。
    - 软急停：HMI 脉冲锁存 bSoftEstop（事件/状态，驱动上报与 ModeManager 转 110），
      受控减速停车电平 smBSoftStopActive（驱动 bSafetyStop）；停稳持续 diEmergencyCoastMs
      后停车电平自动解除，放行 iState=110 紧急回零 Jog（bSoftEstop 仍保持，需
      trigSysReset 转 RESET）；减速 500 扫(≈5s)未全静止 → 升级锁存硬急停。
    - 保护停机：超力锁存 / 编码器故障（绝对位置不可信）→ bProtStop 受控减速锁存，
      需 trigSysReset 且条件消失才解除。
    - 硬限位（伺服 OriginSwitch 外的 bPosLimit/bNegLimit）→ 保护停机，脱限 Jog 由
      OUTPUT_ADAPTER 门控（不锁存，脱限即解除）。
    说明：扭矩防夹(1204)/推杆堵转(5001)/步骤超时由各运动 FB/任务就近提交。
==========================================================================*)
PROGRAM PRG_SafetyManager
VAR
    (* 上升沿：H5U 类型 TRIG.R_TRIG，仅局部 VAR 可声明，读 .Q。 *)
    rTrigHard      : TRIG.R_TRIG;
    rTrigSoft      : TRIG.R_TRIG;
    rTrigMismatch  : TRIG.R_TRIG;
    rTrigTimeout   : TRIG.R_TRIG;
    rTrigEncoder   : TRIG.R_TRIG;
    rTrigHwLimit   : TRIG.R_TRIG;
    rTrigOverForce : TRIG.R_TRIG;
    rTrigWatchdog  : TRIG.R_TRIG;
END_VAR

(*------------------------------------------------------------
  1) 诊断信号聚合（每扫合成；轴序 1=Chest 2=Seat 3=Leg）
------------------------------------------------------------*)
smBChanMismatch  := ioEstop1 <> ioEstop2;
smBAnyEncoderFlt := HMI.ChestImpact.Status.Servo.bEncoderFault
               OR HMI.SeatTwist.Status.Servo.bEncoderFault
               OR HMI.LegAngle.Status.Servo.bEncoderFault;
smBAnyHwLimit    := HMI.ChestImpact.Status.Servo.bPosLimit
               OR HMI.ChestImpact.Status.Servo.bNegLimit
               OR HMI.SeatTwist.Status.Servo.bPosLimit
               OR HMI.SeatTwist.Status.Servo.bNegLimit
               OR HMI.LegAngle.Status.Servo.bPosLimit
               OR HMI.LegAngle.Status.Servo.bNegLimit;
smBAnyOverForce  := HMI.ChestImpact.Status.Force.bOverForceLatched
               OR HMI.ChestImpact.Status.Force.bOverForce
               OR HMI.SeatTwist.Status.Force.bOverForceLatched
               OR HMI.SeatTwist.Status.Force.bOverForce
               OR HMI.LegAngle.Status.Force.bOverForceLatched
               OR HMI.LegAngle.Status.Force.bOverForce;

(*------------------------------------------------------------
  2) 急停链
------------------------------------------------------------*)
(* 2.1 双通道不一致：去抖 100ms 后判定（临界故障，拍急停安全侧，不单独驱动链） *)
TONR(IN := smBChanMismatch, PT := 100, Q => smTMismatch);  (* PT=DINT 毫秒：100ms *)

(* 2.2 软急停触发锁存：HMI 脉冲置位；trigSysReset（无硬急停/保护停机）解除。
       注意区分：bSoftEstop 是"发生过软急停"事件/状态锁存（驱动上报、ModeManager 转 110），
       smBSoftStopActive 是受控减速停车电平（驱动 bSafetyStop，使轴停止）。 *)
IF trigEmgStop AND NOT bHardEstop THEN
    bSoftEstop       := TRUE;
    smBSoftStopActive  := TRUE;   (* 停车电平同时置位 *)
ELSIF trigSysReset AND NOT (bHardEstop OR bProtStop) THEN
    bSoftEstop       := FALSE;
    smBSoftStopActive  := FALSE;
END_IF;

(* 2.3 软急停减速看门狗（500 扫 ≈ 5s）：停车电平有效但轴迟迟未全静止 → 升级锁存硬急停。
       计数仅在"减速中"（停车电平有效且未停稳）累加；停稳即清零（安全侧判据明确）。 *)
IF smBSoftStopActive AND NOT bAllAxesIdle AND NOT bHardEstopLatch THEN
    smDiSoftDecelCnt := smDiSoftDecelCnt + 1;
ELSE
    smDiSoftDecelCnt := 0;
END_IF;
IF smDiSoftDecelCnt >= 500 THEN
    bSoftEstop       := FALSE;   (* 软急停升级为硬急停，软态让位 *)
    smBSoftStopActive  := FALSE;
    bHardEstopLatch  := TRUE;
END_IF;

(* 2.3b 紧急回零放行（设计点①）：软急停受控减速停稳（bAllAxesIdle 持续
       diEmergencyCoastMs，默认 500ms=50 扫）后，自动解除减速停车电平，
       使 TASK_RUNNER 在 iState=110 内可发受控 Jog 回初始位。系统仍处软急停状态
       （bSoftEstop 保持，ModeManager 仍需 trigSysReset 转 RESET）；防夹由任务层
       rNetTorquePct 超阈兜底。再发 trigEmgStop 重新置位停车电平（立即二次减速）。 *)
IF smBSoftStopActive AND bAllAxesIdle THEN
    smDiCoastCnt := smDiCoastCnt + 1;
ELSE
    smDiCoastCnt := 0;
END_IF;
IF smBSoftStopActive AND (smDiCoastCnt >= runHoming.diEmergencyCoastMs / 10) THEN
    smBSoftStopActive := FALSE;   (* 停车电平解除，允许紧急 Jog；bSoftEstop 状态仍保持 *)
    smDiCoastCnt      := 0;
END_IF;

(* 2.4 硬急停：物理链断开（瞬时）OR 超时升级锁存。
       锁存解除：物理链恢复 + 复位脉冲（物理急停未恢复前禁止解除）。 *)
bHardEstop := (NOT ioEstopOK) OR bHardEstopLatch;
IF bHardEstopLatch AND ioEstopOK AND trigSysReset THEN
    bHardEstopLatch := FALSE;
END_IF;

(*------------------------------------------------------------
  3) 保护停机（受控减速后锁死，区别于硬急停断使能）
------------------------------------------------------------*)
(* 3.1 超力锁存：牵引力超阈持续（Force.bOverForceLatched 由 OUTPUT_ADAPTER 置位） *)
IF smBAnyOverForce THEN
    bProtStop := TRUE;
END_IF;
(* 3.2 编码器故障：绝对位置不可信，禁定位类动作，立即受控停机 *)
IF smBAnyEncoderFlt THEN
    bProtStop := TRUE;
END_IF;
(* 3.3 解除：复位脉冲 + 全部触发条件消失 *)
IF bProtStop AND trigSysReset AND NOT smBAnyOverForce AND NOT smBAnyEncoderFlt THEN
    bProtStop := FALSE;
END_IF;

(* 硬限位不锁存：OUTPUT_ADAPTER 禁越限运动并提供脱限 Jog；脱限即自然解除。
   软限位(2004 警告)由运动 FB 判定提交，不在此驱动停机。 *)

(*------------------------------------------------------------
  4) 安全停止合成（POWER 断使能判 bHardEstop；OUTPUT_ADAPTER 减速判 bSafetyStop）
------------------------------------------------------------*)
bSafetyStop := bHardEstop OR smBSoftStopActive OR bProtStop OR smBAnyHwLimit;

(*------------------------------------------------------------
  5) 事件上报（上升沿提交一次；每扫至多一条，优先级按安全严重度）
------------------------------------------------------------*)
smBHardPhysical := NOT ioEstopOK;     (* 物理链断开（不含锁存升级） *)
rTrigHard(CLK     := smBHardPhysical);
rTrigMismatch(CLK := smTMismatch);
rTrigTimeout(CLK  := bHardEstopLatch);
rTrigSoft(CLK     := bSoftEstop);
rTrigEncoder(CLK  := smBAnyEncoderFlt);
rTrigHwLimit(CLK  := smBAnyHwLimit);
rTrigOverForce(CLK := smBAnyOverForce);
rTrigWatchdog(CLK := mnTScanWatchdog);

(* 扫描看门狗 1007：本位预留，正常不置位（真实看门狗为 H5U 任务组态/硬件，
   超时由控制器停机/进安全态；详见 PRG_Main 注释）。一旦被系统变量置位，
   作为最高优先级 Critical 上报一次，交 ModeManager 转 RESET 收口。处置策略待现场确认。 *)
IF rTrigWatchdog.Q THEN
    gFaultLevel := 2; gFaultCode := ERR_SCAN_WATCHDOG; gFaultSource := SRC_SAFETY;
    gFaultSubCode := 0; gFaultVal1 := 0; gFaultVal2 := 0;
    gFaultSubmit := TRUE;
ELSIF rTrigHard.Q THEN
    gFaultLevel := 2; gFaultCode := ERR_HARD_ESTOP; gFaultSource := SRC_SAFETY;
    gFaultSubCode := 0; gFaultVal1 := 0; gFaultVal2 := 0;
    gFaultSubmit := TRUE;
ELSIF smTMismatch AND rTrigMismatch.Q THEN
    gFaultLevel := 2; gFaultCode := ERR_ESTOP_MISMATCH; gFaultSource := SRC_SAFETY;
    gFaultSubCode := 0; gFaultVal1 := BOOL_TO_INT(ioEstop1); gFaultVal2 := BOOL_TO_INT(ioEstop2);
    gFaultSubmit := TRUE;
ELSIF rTrigTimeout.Q THEN
    gFaultLevel := 2; gFaultCode := ERR_SOFT_ESTOP_TOUT; gFaultSource := SRC_SAFETY;
    gFaultSubCode := 0; gFaultVal1 := 0; gFaultVal2 := 0;
    gFaultSubmit := TRUE;
ELSIF rTrigSoft.Q THEN
    gFaultLevel := 2; gFaultCode := ERR_SOFT_ESTOP; gFaultSource := SRC_SAFETY;
    gFaultSubCode := 0; gFaultVal1 := 0; gFaultVal2 := 0;
    gFaultSubmit := TRUE;
ELSIF rTrigOverForce.Q THEN
    gFaultLevel := 2; gFaultCode := ERR_OVERFORCE; gFaultSource := SRC_SAFETY;
    gFaultSubCode := 0; gFaultVal1 := 0; gFaultVal2 := 0;
    gFaultSubmit := TRUE;
ELSIF rTrigEncoder.Q THEN
    gFaultLevel := 2; gFaultCode := ERR_AXIS_ENCODER; gFaultSource := SRC_SAFETY;
    gFaultSubCode := 0; gFaultVal1 := BOOL_TO_INT(smBAnyEncoderFlt); gFaultVal2 := 0;
    gFaultSubmit := TRUE;
ELSIF rTrigHwLimit.Q THEN
    gFaultLevel := 2; gFaultCode := ERR_AXIS_HWLIMIT; gFaultSource := SRC_SAFETY;
    gFaultSubCode := 0; gFaultVal1 := 0; gFaultVal2 := 0;
    gFaultSubmit := TRUE;
END_IF;

END_PROGRAM
