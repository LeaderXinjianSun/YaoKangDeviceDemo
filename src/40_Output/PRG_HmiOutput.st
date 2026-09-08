(*============================================================================
  PRG_HmiOutput —— 层 40 输出：内部状态 → D 区回填（扫描链第 11 环，最末环）
  ----------------------------------------------------------------------------
  唯一写入：HMI.Sys.Status（系统显示状态）、HMI.Sys.Runtime（统计）；
            Condition.Status 业务状态位的汇总镜像（任务层写过程值，本程序
            只汇总系统级标志）。
  读入：  iState/iPhase/iBlockReason/iWorkMode、安全态、Error/Warning、
          轴/推杆状态、diScanCount。
  规则：命令位绝不回写（命令位归 HMI/InputAdapter）；只写状态/统计/镜像。
  P1：iState/iPhase/心跳/急停态/上电态回填。
  P2/P6/P11：22 个系统状态位、健康等级、READY_CHECK 掩码、运行统计。
==========================================================================*)
PROGRAM PRG_HmiOutput

(*--- 系统状态主字回填 ---*)
HMI.Sys.Status.iState       := iState;
HMI.Sys.Status.iPhase       := iPhase;
HMI.Sys.Status.iTaskPhase   := iPhase;
HMI.Sys.Status.iBlockReason := iBlockReason;
HMI.Sys.Status.iWorkMode    := iWorkMode;
HMI.Sys.Status.diUpTime     := diScanCount * 10;   (* 运行时长 ms（扫描周期 10ms） *)

(*--- 安全/急停态镜像 ---*)
HMI.Sys.Status.bIsEmergency := bHardEstop OR bSoftEstop;
HMI.Sys.Status.bBusy        := (iState = ST_AUTORUN) OR (iState = ST_SELFTEST)
                              OR (iState = ST_HOMING) OR (iState = ST_CALIBRATE);

(*--- 全轴汇总位（P7 轴 FB 状态齐备后填实） ---*)
HMI.Sys.Status.bAllAxesIdle   := bAllAxesIdle;
HMI.Sys.Status.bAllAxesHomed  := bAllAxesRef;
HMI.Sys.Status.bAllAxesAtInit := bAllAxesAtInit;
HMI.Sys.Status.bReady         := (iState = ST_STANDBY);
HMI.Sys.Status.bSafeToStart   := (iState = ST_STANDBY) AND NOT bSafetyStop
                                 AND bAllAxesRef AND bAllAxesAtInit;

(*--- 活动错误镜像到 Status 主字（ErrorManager 单写 Sys.Error，本程序只读镜像；
       无活动错误时清零，HMI 主窗口直接读 Status 即可） ---*)
HMI.Sys.Status.iErrorCode    := HMI.Sys.Error.iCode;
HMI.Sys.Status.iErrorLevel   := HMI.Sys.Error.iLevel;
HMI.Sys.Status.iErrorSubCode := HMI.Sys.Error.iSubCode;
HMI.Sys.Status.iErrorSource  := HMI.Sys.Error.iSource;

(*--- 初始化 / 参数态 ---*)
HMI.Sys.Status.bInitialized      := bParamBootDone;    (* 上电参数装载完成 *)
HMI.Sys.Status.bParamInitialized := bRunParamValid;    (* 运行快照有效 *)
HMI.Sys.Status.bParamError       := NOT bRunParamValid;

(*--- 轴汇总位（AllAxesIdle/Homed/AtInit/Ready/SafeToStart/Busy 已在上方填） ---*)
HMI.Sys.Status.bAllAxesReferenced := bAllAxesRef;
HMI.Sys.Status.bAnyAxisAtLimit := HMI.ChestImpact.Status.Servo.bPosLimit
                               OR HMI.ChestImpact.Status.Servo.bNegLimit
                               OR HMI.SeatTwist.Status.Servo.bPosLimit
                               OR HMI.SeatTwist.Status.Servo.bNegLimit
                               OR HMI.LegAngle.Status.Servo.bPosLimit
                               OR HMI.LegAngle.Status.Servo.bNegLimit;
(* 绝对位置有效：三轴均无编码器故障 *)
HMI.Sys.Status.bAbsPositionValid := NOT (HMI.ChestImpact.Status.Servo.bEncoderFault
                               OR HMI.SeatTwist.Status.Servo.bEncoderFault
                               OR HMI.LegAngle.Status.Servo.bEncoderFault);

(*--- 上电原点传感器态（推杆原点输入 X5 去抖镜像） ---*)
HMI.Sys.Status.bTailSensorAtBoot := ioPusherOrigin;

(*--- 敏感步运行：自动流程的成角/治疗执行段（110/130）人员须远离，HMI 高亮警示 ---*)
HMI.Sys.Status.bSensitiveRunning := (iState = ST_AUTORUN)
    AND ((HMI.Condition.Status.iStep = CONDSEQ_ANGLE)
         OR (HMI.Condition.Status.iStep = CONDSEQ_RUN));

(* 以下各位单写源不在本程序，不重复写：
   diReadyCheckResult/bNeedReset/bAutoProcessRunning/iHealthLevel → ModeManager；
   bSkipSelfTestAllowed/bForceSkipSelfTestAllowed → ModeManager；
   bPowerOn/bPoweringUp → Power；
   bSelfTestDone/bHealthCheckSkipped → TaskRunner（自检完成/跳过完成）。
   未用/待契约：iInitErrorCode/iPadInt/rTailDriftPulse；
   通信心跳 1006（ERR_COMM_LOST）需 HMI 心跳寄存器契约，地址表未定义，暂留。 *)

(*--- 运行统计（P11）：自动流程运行时长（ms，暂停不计）+ 累计计数回填 ---*)
IF (iState = ST_AUTORUN) AND (HMI.Condition.Status.iStep = CONDSEQ_RUN)
   AND (NOT HMI.Condition.Status.bPaused) THEN
    diStatRunTime := diStatRunTime + 10;       (* 每扫 10ms，暂停/非运行步不计时 *)
END_IF;
HMI.Sys.Runtime.diAgingCycleCount := diStatAgingCycles;
HMI.Sys.Runtime.diTotalCycles     := diStatTotalCycles;
HMI.Sys.Runtime.diRunTime         := diStatRunTime;
HMI.Sys.Runtime.iCurrentStep      := HMI.Condition.Status.iStep;
HMI.Sys.Runtime.iActCycles        := HMI.Condition.Status.iCurrentCycle;
HMI.Sys.Runtime.bBatchDone        := HMI.Condition.Status.bBatchDone;

(* 调理过程状态位：Condition.Status 各过程值由 TaskRunner/FB_Condition 直接写入，
   本程序仅做系统级汇总（iCurrentStep/iActCycles/bBatchDone 见上），不重复写。 *)
END_PROGRAM
