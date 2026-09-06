(*============================================================================
  PRG_ErrorManager —— 层 20 决策：错误与诊断（扫描链第 4 环），错误唯一写入者
  ----------------------------------------------------------------------------
  唯一写入：HMI.Sys.Error（当前活动错误）、HMI.Sys.Warning（警告通道）、
            HMI.Sys.ErrorQueue（9 条环形历史队列）；faultSubmit 应答清零。
  读入：  全局故障提交区 gFault*（各任务模块置位 faultSubmit 提交，本程序消费）。
  提交约定：任务模块填 gFaultLevel/Code/Source/SubCode/Val1/Val2 后置
            gFaultSubmit:=TRUE；本程序入队并在同扫描清 gFaultSubmit。
            级别：0=L0 Info 1=L1 Warning 2=L2 Critical。
  P3 落地：码表归类、Critical 升级、需手动复位位、队列环形滚动、时间戳。
==========================================================================*)
PROGRAM PRG_ErrorManager
VAR
    iPos    : INT;
END_VAR

IF gFaultSubmit THEN
    (*--- 入环形队列：9 条，iTail 推进、iCount 计数、溢出置位 ---*)
    HMI.Sys.ErrorQueue.aEntries[HMI.Sys.ErrorQueue.iTail].iLevel      := gFaultLevel;
    HMI.Sys.ErrorQueue.aEntries[HMI.Sys.ErrorQueue.iTail].iCode       := gFaultCode;
    HMI.Sys.ErrorQueue.aEntries[HMI.Sys.ErrorQueue.iTail].iSource     := gFaultSource;
    HMI.Sys.ErrorQueue.aEntries[HMI.Sys.ErrorQueue.iTail].iVal1       := gFaultVal1;
    HMI.Sys.ErrorQueue.aEntries[HMI.Sys.ErrorQueue.iTail].diTimestamp := diScanCount;  (* TODO P3: 换毫秒时钟 *)

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

    (*--- 当前活动错误 / 警告通道（L2→Error，L1→Warning） ---*)
    IF gFaultLevel >= 2 THEN
        HMI.Sys.Error.iLevel     := gFaultLevel;
        HMI.Sys.Error.iCode      := gFaultCode;
        HMI.Sys.Error.iSource    := gFaultSource;
        HMI.Sys.Error.iSubCode   := gFaultSubCode;
        HMI.Sys.Error.iVal1      := gFaultVal1;
        HMI.Sys.Error.iVal2      := gFaultVal2;
        HMI.Sys.Error.bActive    := TRUE;
        HMI.Sys.Error.bCritical  := TRUE;
        HMI.Sys.Error.bNeedReset := TRUE;   (* TODO P3: 按码表区分是否需手动复位 *)
    ELSIF gFaultLevel = 1 THEN
        HMI.Sys.Warning.iCode   := gFaultCode;
        HMI.Sys.Warning.iSource := gFaultSource;
        HMI.Sys.Warning.iVal1   := gFaultVal1;
        HMI.Sys.Warning.bActive := TRUE;
    END_IF;

    gFaultSubmit := FALSE;   (* 消费应答 *)
END_IF;

(* TODO P3:
   - 错误码常量库段位归类（1xxx/2xxx/3xxx/4xxx/5xxx/7xxx），子码映射轴 9xxx/驱动器 Er.xxx。
   - trigReset/bAckErrorReq 清除活动错误（bNeedReset 未置位的 L0/L1 可自动清除）。
   - Condition.Status.iErrorCode/iErrorLevel 与 Sys.Error 镜像策略。
   - 警告自动消退条件（如超力实时态消失）。 *)
END_PROGRAM
