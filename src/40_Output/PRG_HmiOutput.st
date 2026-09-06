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
VAR
END_VAR

(*--- 系统状态主字回填 ---*)
HMI.Sys.Status.iState       := iState;
HMI.Sys.Status.iPhase       := iPhase;
HMI.Sys.Status.iTaskPhase   := iPhase;
HMI.Sys.Status.iBlockReason := iBlockReason;
HMI.Sys.Status.iWorkMode    := iWorkMode;
HMI.Sys.Status.diUpTime     := diScanCount;   (* TODO P2: 换毫秒运行时钟 *)

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

(* TODO P6: diReadyCheckResult 六项资格掩码、bInitialized/bParamInitialized、
   bAutoProcessRunning/bNeedReset/bHealthCheckSkipped/bAllAxesReferenced/
   bAnyAxisAtLimit/bParamError/bAbsPositionValid/bSensitiveRunning/
   bSelfTestDone/bSkipSelfTestAllowed/bForceSkipSelfTestAllowed/iHealthLevel。
   TODO P11: Sys.Runtime 运行统计（diTotalCycles/diRunTime/iActCycles 等）。
   TODO P2: Condition.Status 17 个调理状态位由 TaskRunner/FBI_Cond 写过程值，
   本程序仅做系统级汇总，不重复写。 *)
END_PROGRAM
