(*============================================================================
  PRG_InputAdapter —— 层 10 输入：硬接线 I/O 镜像 + HMI 命令解析（扫描链第 2 环）
  ----------------------------------------------------------------------------
  唯一写入：io* I/O 镜像、rPusherPosMm/bPusherPosValid（HC_Counter mm 位置）；
            trig*/axisPulse 脉冲位（局部 TRIG.R_TRIG.Q 转写，本扫有效）；
            电平镜像位（bPauseLevel/bResumeLevel/bFootSignal/bServiceAuthConfirm/
            bNoLoadConfirm/bRevalidateParams/axisEnableReq/axisJogPos/axisJogNeg/
            pushEnableReq/jogPushUp/jogPushDown）；
            HMI 脉冲命令位回清（消费后清零；电平位不清、同字反馈位不碰）。
  读入：  物理 I_Estop1/I_Estop2/I_SafeRelay/I_ResetBtn/I_PusherOrigin、
          HC_Counter（内联高速计数器，Axis_电推杆，Position 直接为 REAL，单位 mm）、
          HMI.Condition.Cmd.*、HMI.Sys.Cmd.*、三轴 Cmd、TailTilt.Cmd.*。
  命令语义：
    脉冲命令 = HMI 置位按钮 → 本程序 R_TRIG 锁存为内部 trig/axisPulse（单扫）
               → 下游环（4–10 环）消费 → 本扫末把 HMI 命令位清 FALSE 作应答
               （HMI 见到位回落即知 PLC 已受理）。
    电平命令 = 按住有效，直接镜像到内部电平位，HMI 松开后随镜像自然回落；
               任务离态时的残留由 CMD_PRECLEAR / 状态机门控兜底。
  轴数组下标（H5U base 0）：0=ChestImpact 冲击 / 1=SeatTwist 扭角 / 2=LegAngle 转角
             （按 HMI 主结构体块顺序；注意与 GVL_CONST AXIS_ID_* 协议码编号不同，
             故障上报须用 AXIS_ID_*，勿用本数组下标）。
==========================================================================*)
PROGRAM PRG_InputAdapter
VAR
    (* 推杆位置高速计数器：开关型电推杆无 AD，位置由 HC_Counter 内联指令读
       Axis_电推杆 计数轴，Position 直接为 REAL（单位 mm，H5U 高速计数器组态内
       标定为 mm）。HC_Counter 与 TONR 同属内联指令，不声明实例、直接调用。
       去抖 TONR 同为内联 TONR(IN:=,PT:=,Q=>布尔位)，其 Q=> 输出 BOOL（iaT*Db）、
       PT 时间常数 iaTDbTime 及 HC_Counter 的 Position/Valid/Error/ErrorID
       承接位均上移为 GVL_Internal 全局 ia* 简单变量。 *)

    (* 上升沿检测：H5U 类型为 TRIG.R_TRIG（功能块实例，仅局部 VAR 可声明），
       .Q 每扫转写全局 BOOL 脉冲位；全局 GVL 不支持功能块实例。
       实例逐个命名（与旧工程功能块实例表惯例一致，便于 CSV 导入）。 *)

    (* 调理区 Condition.Cmd（5 路） *)
    rTrigStart      : TRIG.R_TRIG;   (* S1 启动流程 *)
    rTrigChengJiao  : TRIG.R_TRIG;   (* S2 开始成角 *)
    rTrigAllow      : TRIG.R_TRIG;   (* S3 确认 *)
    rTrigStop       : TRIG.R_TRIG;   (* 停止 *)
    rTrigReset      : TRIG.R_TRIG;   (* 复位错误 *)
    rTrigSkipAngle  : TRIG.R_TRIG;   (* 跳过成角 v3.16 *)

    (* 系统区 Sys.Cmd（21 路脉冲） *)
    rTrigServiceMode     : TRIG.R_TRIG;   (* bServiceModeReq 进入维护 *)
    rTrigSysHoming       : TRIG.R_TRIG;   (* bHomingReq 回零 *)
    rTrigSysStop         : TRIG.R_TRIG;   (* bStopReq 停止 *)
    rTrigAutoStart       : TRIG.R_TRIG;   (* bAutoStartReq 自动启动 *)
    rTrigCalibrate       : TRIG.R_TRIG;   (* bCalibrateReq 标定 *)
    rTrigSysReset        : TRIG.R_TRIG;   (* bResetReq 复位 *)
    rTrigAckError        : TRIG.R_TRIG;   (* bAckErrorReq 确认错误 *)
    rTrigEmgStop         : TRIG.R_TRIG;   (* bEmergencyStopReq 软急停 *)
    rTrigInitialize      : TRIG.R_TRIG;   (* bInitializeReq 初始化 *)
    rTrigSvcMechHome     : TRIG.R_TRIG;   (* bServiceMechHomeReq 维护机械回零 *)
    rTrigSelfTestConfirm : TRIG.R_TRIG;   (* bSelfTestConfirm 自检安全确认 *)
    rTrigSelfTestSkip    : TRIG.R_TRIG;   (* bSelfTestSkip 自检跳过 *)
    rTrigAllPowerOff     : TRIG.R_TRIG;   (* bAllPowerOffReq 全轴断电 *)
    rTrigAllPowerOn      : TRIG.R_TRIG;   (* bAllPowerOnReq 全轴上电 *)
    rTrigStartSelfTest   : TRIG.R_TRIG;   (* bStartSelfTestReq 启动自检 *)
    rTrigServiceDone     : TRIG.R_TRIG;   (* bServiceDoneReq 维护完成 *)
    rTrigReadyCheck      : TRIG.R_TRIG;   (* bReadyCheckReq 就绪检查 *)
    rTrigQuickStart      : TRIG.R_TRIG;   (* bQuickStartReq 快速启动 *)
    rTrigForceSkipST     : TRIG.R_TRIG;   (* bForceSkipSelfTestReq 强制跳过自检 *)
    rTrigClearZeroRetain : TRIG.R_TRIG;   (* bClearZeroRetainReq 清建零 Retain *)
    rTrigLearnBias       : TRIG.R_TRIG;   (* bLearnImpactBiasReq 学习扭矩基线 *)

    (* 三轴 Servo Cmd（3 轴 × 8 路脉冲 = 24；轴序 1=Chest 2=Seat 3=Leg） *)
    rA1Reset : TRIG.R_TRIG;  rA2Reset : TRIG.R_TRIG;  rA3Reset : TRIG.R_TRIG;
    rA1Zero  : TRIG.R_TRIG;  rA2Zero  : TRIG.R_TRIG;  rA3Zero  : TRIG.R_TRIG;
    rA1Stop  : TRIG.R_TRIG;  rA2Stop  : TRIG.R_TRIG;  rA3Stop  : TRIG.R_TRIG;
    rA1Abs   : TRIG.R_TRIG;  rA2Abs   : TRIG.R_TRIG;  rA3Abs   : TRIG.R_TRIG;
    rA1Rel   : TRIG.R_TRIG;  rA2Rel   : TRIG.R_TRIG;  rA3Rel   : TRIG.R_TRIG;
    rA1Auto  : TRIG.R_TRIG;  rA2Auto  : TRIG.R_TRIG;  rA3Auto  : TRIG.R_TRIG;
    rA1Buf   : TRIG.R_TRIG;  rA2Buf   : TRIG.R_TRIG;  rA3Buf   : TRIG.R_TRIG;
    rA1Dis   : TRIG.R_TRIG;  rA2Dis   : TRIG.R_TRIG;  rA3Dis   : TRIG.R_TRIG;

    (* 电推杆 TailTilt.Cmd（7 路脉冲） *)
    rTrigPushStop       : TRIG.R_TRIG;   (* bStop *)
    rTrigPushReset      : TRIG.R_TRIG;   (* bReset *)
    rTrigPushCalibrate  : TRIG.R_TRIG;   (* bCalibrate *)
    rTrigPushAutoMove   : TRIG.R_TRIG;   (* bAutoMove *)
    rTrigPushHome       : TRIG.R_TRIG;   (* bHome *)
    rTrigPushPreset     : TRIG.R_TRIG;   (* bManualPreset *)
    rTrigPushResetError : TRIG.R_TRIG;   (* bResetError *)
END_VAR


(*==========================================================================
  1. 硬接线 I/O 去抖镜像
  ==========================================================================*)
(* 急停：双通道常闭（I_Estop1/I_Estop2=TRUE 正常）+ 安全继电器常开
   （I_SafeRelay=TRUE=拍下）。三者均去抖后合成 ioEstopOK：
   任一通道断开或安全继电器动作 → ioEstopOK=FALSE → SafetyManager 硬急停。 *)
TONR(IN := I_Estop1,    PT := iaTDbTime, Q => iaTEstop1Db);
TONR(IN := I_Estop2,    PT := iaTDbTime, Q => iaTEstop2Db);
TONR(IN := I_SafeRelay, PT := iaTDbTime, Q => iaTSafeRelayDb);
ioEstop1  := iaTEstop1Db;
ioEstop2  := iaTEstop2Db;
ioEstopOK := iaTEstop1Db AND iaTEstop2Db AND NOT iaTSafeRelayDb;
(* 双通道不一致（通道粘连/断路）诊断由 SAFETY_MANAGER 用 ioEstop1/ioEstop2 判定。 *)

TONR(IN := I_PusherOrigin, PT := iaTDbTime, Q => iaTOriginDb);
ioPusherOrigin := iaTOriginDb;

TONR(IN := I_ResetBtn, PT := iaTDbTime, Q => iaTResetDb);
ioResetBtn := iaTResetDb;

(*--- 推杆位置：HC_Counter 内联高速计数器读 mm（开关型电推杆无 AD；算法蓝本：推杆轴控制方式.txt）。
      HC_Counter 为内联指令（同 TONR，不声明实例，直接调用）；Enable 常使能；
      Axis 绑 H5U 高速计数器组态轴 Axis_电推杆；Invert 为 INT 方向取反（0=不取反）；
      Position 直接输出 REAL（单位 mm）；Velocity/Direction/CommandAborted 不用留空。 ---*)
HC_Counter(Enable := TRUE,
           Axis   := Axis_电推杆,
           Invert := 0,
           Valid  => iaBHscValid,
           Position => iaDiHscPos,
           Velocity => ,
           Direction => ,
           CommandAborted => ,
           Error  => iaBHscError,
           ErrorID => iaWHscErrId);
rPusherPosMm    := iaDiHscPos;   (* mm 位置镜像（HC_Counter.Position 即 REAL，直接赋值） *)
bPusherPosValid := iaBHscValid AND NOT iaBHscError;


(*==========================================================================
  2. 调理区 Condition.Cmd —— 脉冲边沿锁存
  ==========================================================================*)
rTrigStart(CLK      := HMI.Condition.Cmd.S1_StartProcess);
rTrigChengJiao(CLK  := HMI.Condition.Cmd.S2_StartChengJiao);
rTrigAllow(CLK      := HMI.Condition.Cmd.S3_AllowSignal);
rTrigStop(CLK       := HMI.Condition.Cmd.bStop);
rTrigReset(CLK      := HMI.Condition.Cmd.bReset);
rTrigSkipAngle(CLK  := HMI.Condition.Cmd.bSkipAngle);
trigStart     := rTrigStart.Q;
trigChengJiao := rTrigChengJiao.Q;
trigAllow     := rTrigAllow.Q;
trigStop      := rTrigStop.Q;
trigReset     := rTrigReset.Q;
trigSkipAngle := rTrigSkipAngle.Q;

(*--- 调理电平命令直接镜像（bPause/bResume 与系统区同名命令取"任一按下"） ---*)
bPauseLevel  := HMI.Condition.Cmd.bPause  OR HMI.Sys.Cmd.bPause;
bResumeLevel := HMI.Condition.Cmd.bResume OR HMI.Sys.Cmd.bResume;
bFootSignal  := HMI.Condition.Cmd.bSignal;   (* 脚踏无独立物理点（CSV 未定义），仅取 HMI 信号 *)

(*--- 调理脉冲命令位消费后回清（S1 为电平型保持，不清；bSignal 脚踏不清） ---*)
HMI.Condition.Cmd.S2_StartChengJiao := FALSE;
HMI.Condition.Cmd.S3_AllowSignal    := FALSE;
HMI.Condition.Cmd.bStop             := FALSE;
HMI.Condition.Cmd.bReset            := FALSE;
HMI.Condition.Cmd.bSkipAngle        := FALSE;


(*==========================================================================
  3. 系统区 Sys.Cmd —— 21 路脉冲边沿锁存 + 电平镜像
  ==========================================================================*)
rTrigServiceMode(CLK     := HMI.Sys.Cmd.bServiceModeReq);
rTrigSysHoming(CLK       := HMI.Sys.Cmd.bHomingReq);
rTrigSysStop(CLK         := HMI.Sys.Cmd.bStopReq);
rTrigAutoStart(CLK       := HMI.Sys.Cmd.bAutoStartReq);
rTrigCalibrate(CLK       := HMI.Sys.Cmd.bCalibrateReq);
rTrigSysReset(CLK        := HMI.Sys.Cmd.bResetReq);
rTrigAckError(CLK        := HMI.Sys.Cmd.bAckErrorReq);
rTrigEmgStop(CLK         := HMI.Sys.Cmd.bEmergencyStopReq);
rTrigInitialize(CLK      := HMI.Sys.Cmd.bInitializeReq);
rTrigSvcMechHome(CLK     := HMI.Sys.Cmd.bServiceMechHomeReq);
rTrigSelfTestConfirm(CLK := HMI.Sys.Cmd.bSelfTestConfirm);
rTrigSelfTestSkip(CLK    := HMI.Sys.Cmd.bSelfTestSkip);
rTrigAllPowerOff(CLK     := HMI.Sys.Cmd.bAllPowerOffReq);
rTrigAllPowerOn(CLK      := HMI.Sys.Cmd.bAllPowerOnReq);
rTrigStartSelfTest(CLK   := HMI.Sys.Cmd.bStartSelfTestReq);
rTrigServiceDone(CLK     := HMI.Sys.Cmd.bServiceDoneReq);
rTrigReadyCheck(CLK      := HMI.Sys.Cmd.bReadyCheckReq);
rTrigQuickStart(CLK      := HMI.Sys.Cmd.bQuickStartReq);
rTrigForceSkipST(CLK     := HMI.Sys.Cmd.bForceSkipSelfTestReq);
rTrigClearZeroRetain(CLK := HMI.Sys.Cmd.bClearZeroRetainReq);
rTrigLearnBias(CLK       := HMI.Sys.Cmd.bLearnImpactBiasReq);

trigServiceMode     := rTrigServiceMode.Q;
trigSysHoming       := rTrigSysHoming.Q;
trigSysStop         := rTrigSysStop.Q;
trigAutoStart       := rTrigAutoStart.Q;
trigCalibrate       := rTrigCalibrate.Q;
trigSysReset        := rTrigSysReset.Q;
trigAckError        := rTrigAckError.Q;
trigEmgStop         := rTrigEmgStop.Q;
trigInitialize      := rTrigInitialize.Q;
trigSvcMechHome     := rTrigSvcMechHome.Q;
trigSelfTestConfirm := rTrigSelfTestConfirm.Q;
trigSelfTestSkip    := rTrigSelfTestSkip.Q;
trigAllPowerOff     := rTrigAllPowerOff.Q;
trigAllPowerOn      := rTrigAllPowerOn.Q;
trigStartSelfTest   := rTrigStartSelfTest.Q;
trigServiceDone     := rTrigServiceDone.Q;
trigReadyCheck      := rTrigReadyCheck.Q;
trigQuickStart      := rTrigQuickStart.Q;
trigForceSkipST     := rTrigForceSkipST.Q;
trigClearZeroRetain := rTrigClearZeroRetain.Q;
trigLearnBias       := rTrigLearnBias.Q;

(*--- 系统电平命令镜像（建零门控/参数重校验；按住有效，离态自动回落） ---*)
bServiceAuthConfirm := HMI.Sys.Cmd.bServiceAuthConfirm;
bNoLoadConfirm      := HMI.Sys.Cmd.bNoLoadConfirm;
bRevalidateParams   := HMI.Sys.Cmd.bRevalidateParams;
(* iWorkMode/iResetMode/iHomingMode/iUserRole/iAuthCode 为电平值，
   由 MODE_MANAGER(P6)/权限(P11) 在切换时直接读 HMI.Sys.Cmd，不在此镜像。 *)

(*--- 系统脉冲命令位消费后回清（电平位 bPause/bResume/bRevalidateParams/
     bServiceAuthConfirm/bNoLoadConfirm 不清） ---*)
HMI.Sys.Cmd.bServiceModeReq       := FALSE;
HMI.Sys.Cmd.bHomingReq            := FALSE;
HMI.Sys.Cmd.bStopReq              := FALSE;
HMI.Sys.Cmd.bAutoStartReq         := FALSE;
HMI.Sys.Cmd.bCalibrateReq         := FALSE;
HMI.Sys.Cmd.bResetReq             := FALSE;
HMI.Sys.Cmd.bAckErrorReq          := FALSE;
HMI.Sys.Cmd.bEmergencyStopReq     := FALSE;
HMI.Sys.Cmd.bInitializeReq        := FALSE;
HMI.Sys.Cmd.bServiceMechHomeReq   := FALSE;
HMI.Sys.Cmd.bSelfTestConfirm      := FALSE;
HMI.Sys.Cmd.bSelfTestSkip         := FALSE;
HMI.Sys.Cmd.bAllPowerOffReq       := FALSE;
HMI.Sys.Cmd.bAllPowerOnReq        := FALSE;
HMI.Sys.Cmd.bStartSelfTestReq     := FALSE;
HMI.Sys.Cmd.bServiceDoneReq       := FALSE;
HMI.Sys.Cmd.bReadyCheckReq        := FALSE;
HMI.Sys.Cmd.bQuickStartReq        := FALSE;
HMI.Sys.Cmd.bForceSkipSelfTestReq := FALSE;
HMI.Sys.Cmd.bClearZeroRetainReq   := FALSE;
HMI.Sys.Cmd.bLearnImpactBiasReq   := FALSE;


(*==========================================================================
  4. 三轴 Servo Cmd —— 轴序 1=ChestImpact 2=SeatTwist 3=LegAngle
  ==========================================================================*)
(*--- 轴 1 ChestImpact ---*)
rA1Reset(CLK := HMI.ChestImpact.Cmd.bReset);
rA1Zero(CLK  := HMI.ChestImpact.Cmd.bZeroCommission);
rA1Stop(CLK  := HMI.ChestImpact.Cmd.bStop);
rA1Abs(CLK   := HMI.ChestImpact.Cmd.bMoveAbs);
rA1Rel(CLK   := HMI.ChestImpact.Cmd.bMoveRel);
rA1Auto(CLK  := HMI.ChestImpact.Cmd.bAutoMove);
rA1Buf(CLK   := HMI.ChestImpact.Cmd.bMoveBuffer);
rA1Dis(CLK   := HMI.ChestImpact.Cmd.bRequestDisable);
axisPulse[0, AXCMD_RESET]       := rA1Reset.Q;
axisPulse[0, AXCMD_ZERO_COMM]   := rA1Zero.Q;
axisPulse[0, AXCMD_STOP]        := rA1Stop.Q;
axisPulse[0, AXCMD_MOVEABS]     := rA1Abs.Q;
axisPulse[0, AXCMD_MOVEREL]     := rA1Rel.Q;
axisPulse[0, AXCMD_AUTOMOVE]    := rA1Auto.Q;
axisPulse[0, AXCMD_MOVEBUFFER]  := rA1Buf.Q;
axisPulse[0, AXCMD_REQ_DISABLE] := rA1Dis.Q;
axisEnableReq[0] := HMI.ChestImpact.Cmd.bEnable;
axisJogPos[0]    := HMI.ChestImpact.Cmd.bJogPos;
axisJogNeg[0]    := HMI.ChestImpact.Cmd.bJogNeg;

(*--- 轴 2 SeatTwist ---*)
rA2Reset(CLK := HMI.SeatTwist.Cmd.bReset);
rA2Zero(CLK  := HMI.SeatTwist.Cmd.bZeroCommission);
rA2Stop(CLK  := HMI.SeatTwist.Cmd.bStop);
rA2Abs(CLK   := HMI.SeatTwist.Cmd.bMoveAbs);
rA2Rel(CLK   := HMI.SeatTwist.Cmd.bMoveRel);
rA2Auto(CLK  := HMI.SeatTwist.Cmd.bAutoMove);
rA2Buf(CLK   := HMI.SeatTwist.Cmd.bMoveBuffer);
rA2Dis(CLK   := HMI.SeatTwist.Cmd.bRequestDisable);
axisPulse[1, AXCMD_RESET]       := rA2Reset.Q;
axisPulse[1, AXCMD_ZERO_COMM]   := rA2Zero.Q;
axisPulse[1, AXCMD_STOP]        := rA2Stop.Q;
axisPulse[1, AXCMD_MOVEABS]     := rA2Abs.Q;
axisPulse[1, AXCMD_MOVEREL]     := rA2Rel.Q;
axisPulse[1, AXCMD_AUTOMOVE]    := rA2Auto.Q;
axisPulse[1, AXCMD_MOVEBUFFER]  := rA2Buf.Q;
axisPulse[1, AXCMD_REQ_DISABLE] := rA2Dis.Q;
axisEnableReq[1] := HMI.SeatTwist.Cmd.bEnable;
axisJogPos[1]    := HMI.SeatTwist.Cmd.bJogPos;
axisJogNeg[1]    := HMI.SeatTwist.Cmd.bJogNeg;

(*--- 轴 3 LegAngle ---*)
rA3Reset(CLK := HMI.LegAngle.Cmd.bReset);
rA3Zero(CLK  := HMI.LegAngle.Cmd.bZeroCommission);
rA3Stop(CLK  := HMI.LegAngle.Cmd.bStop);
rA3Abs(CLK   := HMI.LegAngle.Cmd.bMoveAbs);
rA3Rel(CLK   := HMI.LegAngle.Cmd.bMoveRel);
rA3Auto(CLK  := HMI.LegAngle.Cmd.bAutoMove);
rA3Buf(CLK   := HMI.LegAngle.Cmd.bMoveBuffer);
rA3Dis(CLK   := HMI.LegAngle.Cmd.bRequestDisable);
axisPulse[2, AXCMD_RESET]       := rA3Reset.Q;
axisPulse[2, AXCMD_ZERO_COMM]   := rA3Zero.Q;
axisPulse[2, AXCMD_STOP]        := rA3Stop.Q;
axisPulse[2, AXCMD_MOVEABS]     := rA3Abs.Q;
axisPulse[2, AXCMD_MOVEREL]     := rA3Rel.Q;
axisPulse[2, AXCMD_AUTOMOVE]    := rA3Auto.Q;
axisPulse[2, AXCMD_MOVEBUFFER]  := rA3Buf.Q;
axisPulse[2, AXCMD_REQ_DISABLE] := rA3Dis.Q;
axisEnableReq[2] := HMI.LegAngle.Cmd.bEnable;
axisJogPos[2]    := HMI.LegAngle.Cmd.bJogPos;
axisJogNeg[2]    := HMI.LegAngle.Cmd.bJogNeg;

(*--- 三轴脉冲命令位消费后回清（bEnable/bJogPos/bJogNeg 电平不清） ---*)
HMI.ChestImpact.Cmd.bReset           := FALSE;
HMI.ChestImpact.Cmd.bZeroCommission  := FALSE;
HMI.ChestImpact.Cmd.bStop            := FALSE;
HMI.ChestImpact.Cmd.bMoveAbs         := FALSE;
HMI.ChestImpact.Cmd.bMoveRel         := FALSE;
HMI.ChestImpact.Cmd.bAutoMove        := FALSE;
HMI.ChestImpact.Cmd.bMoveBuffer      := FALSE;
HMI.ChestImpact.Cmd.bRequestDisable  := FALSE;
HMI.SeatTwist.Cmd.bReset             := FALSE;
HMI.SeatTwist.Cmd.bZeroCommission    := FALSE;
HMI.SeatTwist.Cmd.bStop              := FALSE;
HMI.SeatTwist.Cmd.bMoveAbs           := FALSE;
HMI.SeatTwist.Cmd.bMoveRel           := FALSE;
HMI.SeatTwist.Cmd.bAutoMove          := FALSE;
HMI.SeatTwist.Cmd.bMoveBuffer        := FALSE;
HMI.SeatTwist.Cmd.bRequestDisable    := FALSE;
HMI.LegAngle.Cmd.bReset              := FALSE;
HMI.LegAngle.Cmd.bZeroCommission     := FALSE;
HMI.LegAngle.Cmd.bStop               := FALSE;
HMI.LegAngle.Cmd.bMoveAbs            := FALSE;
HMI.LegAngle.Cmd.bMoveRel            := FALSE;
HMI.LegAngle.Cmd.bAutoMove           := FALSE;
HMI.LegAngle.Cmd.bMoveBuffer         := FALSE;
HMI.LegAngle.Cmd.bRequestDisable     := FALSE;


(*==========================================================================
  5. 电推杆 TailTilt.Cmd —— 7 路脉冲 + 3 路电平
  ==========================================================================*)
rTrigPushStop(CLK       := HMI.TailTilt.Cmd.bStop);
rTrigPushReset(CLK      := HMI.TailTilt.Cmd.bReset);
rTrigPushCalibrate(CLK  := HMI.TailTilt.Cmd.bCalibrate);
rTrigPushAutoMove(CLK   := HMI.TailTilt.Cmd.bAutoMove);
rTrigPushHome(CLK       := HMI.TailTilt.Cmd.bHome);
rTrigPushPreset(CLK     := HMI.TailTilt.Cmd.bManualPreset);
rTrigPushResetError(CLK := HMI.TailTilt.Cmd.bResetError);
trigPushStop       := rTrigPushStop.Q;
trigPushReset      := rTrigPushReset.Q;
trigPushCalibrate  := rTrigPushCalibrate.Q;
trigPushAutoMove   := rTrigPushAutoMove.Q;
trigPushHome       := rTrigPushHome.Q;
trigPushPreset     := rTrigPushPreset.Q;
trigPushResetError := rTrigPushResetError.Q;

pushEnableReq := HMI.TailTilt.Cmd.bEnable;
jogPushUp     := HMI.TailTilt.Cmd.bJogUp;
jogPushDown   := HMI.TailTilt.Cmd.bJogDown;

(*--- 推杆脉冲命令位消费后回清（bEnable/bJogUp/bJogDown 电平不清） ---*)
HMI.TailTilt.Cmd.bStop         := FALSE;
HMI.TailTilt.Cmd.bReset        := FALSE;
HMI.TailTilt.Cmd.bCalibrate    := FALSE;
HMI.TailTilt.Cmd.bAutoMove     := FALSE;
HMI.TailTilt.Cmd.bHome         := FALSE;
HMI.TailTilt.Cmd.bManualPreset := FALSE;
HMI.TailTilt.Cmd.bResetError   := FALSE;

(* 六处 ConfigCmd（Condition.ParamCmd / TailTilt.ConfigCmd /
   三轴 ConfigCmd / HomingParams.Cmd）的 bLoad/bApply/bSave/bResetDefault
   脉冲由 PARAM_SERVICE 自行 R_TRIG 锁存并回清（与参数三区操作同块，避免
   本程序再增 24 路边沿实例）；设备身份 D1010 Load/Apply 归 P11。 *)
END_PROGRAM
