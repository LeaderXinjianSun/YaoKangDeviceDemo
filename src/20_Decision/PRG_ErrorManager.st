(*============================================================================
  PRG_ErrorManager —— 层 20 决策：错误与诊断（扫描链第 4 环），错误唯一写入者
  ----------------------------------------------------------------------------
  唯一写入：HMI.Sys.Error（当前活动错误）、HMI.Sys.Warning（警告通道）、
            HMI.Sys.ErrorQueue（9 条环形历史队列）；消费应答 gFaultSubmit:=FALSE。
  读入：  全局故障提交区 gFault*（各任务模块置位 gFaultSubmit 提交，本程序消费）；
          trigAckError / trigSysReset（错误确认/复位脉冲，由 INPUT_ADAPTER 锁存）；
          bSafetyStop（安全链态，活动 Critical 错误在安全链恢复前禁止清除）。
  提交约定：任务模块填 gFaultLevel/Code/Source/SubCode/Val1/Val2 后置
            gFaultSubmit:=TRUE；本程序入队并在同扫描清 gFaultSubmit。
            级别：0=L0 Info 1=L1 Warning 2=L2 Critical。
  清除语义：
    - Critical(L2) 进 Sys.Error 锁存，bNeedReset=TRUE，须 trigAckError/trigSysReset
      且安全链恢复(bSafetyStop=FALSE)才清除；复位不丢历史队列。
    - Warning(L1) 进 Sys.Warning，trigAckError 立即清除，否则存活 10s 自动消退。
    - 队列仅滚动追加，不随复位删除；bOverflow 记录溢出。
  说明：HMI.Sys.Display 的 iErrorCode/iErrorLevel/iErrorSubCode/iErrorSource 由
        HMI_OUTPUT 从 Sys.Error 镜像（单写源：Display 归 HMI_OUTPUT）。
        时间戳为毫秒运行刻度 diMsTick（上电起 ms，MONITOR 每扫累加 SCAN_PERIOD_MS）；
        非日历时钟，日志若需年月日时分秒待现场引入 RTC 库 FB 后替换（见 GVL_Internal diMsTick TODO）。
==========================================================================*)
PROGRAM PRG_ErrorManager

(*------------------------------------------------------------
  1) 故障消费：入队 + 活动错误/警告通道
------------------------------------------------------------*)
IF gFaultSubmit THEN
    (*--- 入环形队列：9 条，iTail 推进、iCount 计数、溢出置位 ---*)
    HMI.Sys.ErrorQueue.aEntries[HMI.Sys.ErrorQueue.iTail].iLevel      := gFaultLevel;
    HMI.Sys.ErrorQueue.aEntries[HMI.Sys.ErrorQueue.iTail].iCode       := gFaultCode;
    HMI.Sys.ErrorQueue.aEntries[HMI.Sys.ErrorQueue.iTail].iSource     := gFaultSource;
    HMI.Sys.ErrorQueue.aEntries[HMI.Sys.ErrorQueue.iTail].iVal1       := gFaultVal1;
    HMI.Sys.ErrorQueue.aEntries[HMI.Sys.ErrorQueue.iTail].diTimestamp := diMsTick;  (* 事件毫秒刻度（上电起 ms）；日历 RTC 待现场引入库 FB，见 GVL_Internal diMsTick TODO *)

    HMI.Sys.ErrorQueue.iTail := HMI.Sys.ErrorQueue.iTail + 1;
    IF HMI.Sys.ErrorQueue.iTail >= 9 THEN
        HMI.Sys.ErrorQueue.iTail := 0;
    END_IF;

    IF HMI.Sys.ErrorQueue.iCount < 9 THEN
        HMI.Sys.ErrorQueue.iCount := HMI.Sys.ErrorQueue.iCount + 1;
    ELSE
        HMI.Sys.ErrorQueue.iHead := HMI.Sys.ErrorQueue.iHead + 1;  (* 滚动覆盖最旧 *)
        IF HMI.Sys.ErrorQueue.iHead >= 9 THEN
            HMI.Sys.ErrorQueue.iHead := 0;
        END_IF;
        HMI.Sys.ErrorQueue.bOverflow := TRUE;
    END_IF;

    (*--- 当前活动错误 / 警告通道（L2→Error 锁存，L1→Warning 通道，L0 仅入队） ---*)
    IF gFaultLevel >= 2 THEN
        HMI.Sys.Error.iLevel     := gFaultLevel;
        HMI.Sys.Error.iCode      := gFaultCode;
        HMI.Sys.Error.iSource    := gFaultSource;
        HMI.Sys.Error.iSubCode   := gFaultSubCode;
        HMI.Sys.Error.iVal1      := gFaultVal1;
        HMI.Sys.Error.iVal2      := gFaultVal2;
        HMI.Sys.Error.bActive    := TRUE;
        HMI.Sys.Error.bCritical  := TRUE;
        HMI.Sys.Error.bEscalated := (gFaultCode = ERR_SOFT_ESTOP_TOUT);  (* 软急停超时升级硬急停 *)
        HMI.Sys.Error.bNeedReset := TRUE;    (* Critical 一律需手动复位 *)
    ELSIF gFaultLevel = 1 THEN
        HMI.Sys.Warning.iCode   := gFaultCode;
        HMI.Sys.Warning.iSource := gFaultSource;
        HMI.Sys.Warning.iVal1   := gFaultVal1;
        HMI.Sys.Warning.bActive := TRUE;
    END_IF;

    gFaultSubmit := FALSE;   (* 消费应答 *)
END_IF;

(*------------------------------------------------------------
  2) 活动 Critical 错误清除：确认/复位脉冲 + 安全链已恢复
     （安全链未恢复时拒绝清除，防止带故障复位运行）
------------------------------------------------------------*)
IF HMI.Sys.Error.bActive AND HMI.Sys.Error.bNeedReset THEN
    IF (trigAckError OR trigSysReset) AND NOT bSafetyStop THEN
        HMI.Sys.Error.bActive    := FALSE;
        HMI.Sys.Error.bCritical  := FALSE;
        HMI.Sys.Error.bEscalated := FALSE;
        HMI.Sys.Error.bNeedReset := FALSE;
        HMI.Sys.Error.iLevel     := 0;
        HMI.Sys.Error.iCode      := 0;
        HMI.Sys.Error.iSource    := 0;
        HMI.Sys.Error.iSubCode   := 0;
        HMI.Sys.Error.iVal1      := 0;
        HMI.Sys.Error.iVal2      := 0;
    END_IF;
END_IF;

(*------------------------------------------------------------
  3) 警告通道：确认即清；否则存活 10s 自动消退（实时态类警告）
------------------------------------------------------------*)
TONR(IN := HMI.Sys.Warning.bActive, PT := T#10S, Q => emTWarnAge);
IF HMI.Sys.Warning.bActive THEN
    IF trigAckError OR emTWarnAge THEN
        HMI.Sys.Warning.bActive := FALSE;
        HMI.Sys.Warning.iCode   := 0;
        HMI.Sys.Warning.iSource := 0;
        HMI.Sys.Warning.iVal1   := 0;
    END_IF;
END_IF;

END_PROGRAM
