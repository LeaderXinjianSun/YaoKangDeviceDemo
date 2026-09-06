(*============================================================================
  PRG_Power —— 层 40 输出：伺服上下电管理（扫描链第 9 环），轴 bEnable 唯一写入者
  ----------------------------------------------------------------------------
  唯一写入：三轴轴级使能请求（经 OUTPUT_ADAPTER 的 MC_Power 封装执行）；
            HMI.Sys.Status.bPowerOn/bPoweringUp。
  读入：  HMI.Sys.Cmd.bAllPowerOnReq/bAllPowerOffReq、iState、bHardEstop。
  规则：上电按 diPowerInterval 分时逐轴使能（防浪涌）；硬急停立即断全部
        使能；软急停保持使能走 MC_Stop 减速。
  P1：骨架 + 急停断使能逻辑位。
  P7：分时上电时序、bPoweringUp 上报、断使能请求（bRequestDisable）流程。
==========================================================================*)
PROGRAM PRG_Power
VAR
    iPowerStep  : INT;
    (* P7 分时上电延时：H5U 内联 TONR(IN:=,PT:=,Q=>tPowerDelay)，无需 TON 实例。 *)
    tPowerDelay : BOOL;   (* 上电间隔定时到（TONR Q=>tPowerDelay，P7 落地） *)
END_VAR

(*--- 硬急停：无条件断全部使能（OUTPUT_ADAPTER 据此 MC_Power.Enable=FALSE） ---*)
IF bHardEstop THEN
    iPowerStep := 0;
    HMI.Sys.Status.bPowerOn    := FALSE;
    HMI.Sys.Status.bPoweringUp := FALSE;
    (* TODO P7: 通知 OUTPUT_ADAPTER 三轴 MC_Power(FALSE) *)
ELSE
    (* TODO P7:
       - bAllPowerOnReq：按 diPowerInterval 分时 Chest→Seat→Leg 逐轴 MC_Power(TRUE)，
         期间 bPoweringUp:=TRUE，全轴 bEnabled 后 bPowerOn:=TRUE。
       - bAllPowerOffReq / bRequestDisable：按流程断使能。
       - iState=ST_STANDBY 前的上电资格（READY_CHECK 通过）。 *)
    ;
END_IF;
END_PROGRAM
