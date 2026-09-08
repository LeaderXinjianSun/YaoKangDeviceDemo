(*============================================================================
  PRG_Power —— 层 40 输出：伺服上下电管理（扫描链第 9 环），轴使能电平唯一写入者
  ----------------------------------------------------------------------------
  唯一写入：axisPowerEnable[0..2]（→ OUTPUT_ADAPTER 转写 Axis.bPowerOn）；
            HMI.Sys.Status.bPowerOn / bPoweringUp；
            上电失败故障 gFault*（1101，SRC_POWER，子码=AXIS_ID_*）。
  读入：  trigAllPowerOn/trigAllPowerOff（第 2 环脉冲）、axisEnableReq[0..2]
          （HMI 各轴 Cmd.bEnable 电平镜像）、axisPulse[.,AXCMD_REQ_DISABLE]（断使能
          脉冲，本程序第 9 环消费、第 1 环已不再清除轴脉冲外的锁存需求——脉冲仅本扫）、
          三轴 HMI.<Axis>.Status.Servo.bEnabled（OUTPUT_ADAPTER 上扫回填）、bHardEstop。
  规则：
    - 硬急停：立即断全部 axisPowerEnable，清上电流程；
    - 软急停：保持使能，由 OUTPUT_ADAPTER 走 bStop 受控减速；
    - 上电：trigAllPowerOn 锁存请求，按 PWR_STAGGER_SCAN 分时逐轴
            Chest(下标0)→Seat(下标1)→Leg(下标2) 使能，单轴 PWR_ENABLE_TIMEOUT 内未确认
            bEnabled → 1101 Critical 中止；三轴全确认后 bPowerOn:=TRUE；
    - 断电：trigAllPowerOff 或某轴 axisPulse[.,AXCMD_REQ_DISABLE]（单扫脉冲，
            本程序锁存为断轴请求）→ 对应轴 axisPowerEnable:=FALSE。
  时间基准：扫描周期按 10ms 计（diScanCount 推算，任务组态确认后统一修正）。
  说明：H5U 内联 TONR 为累计型且无复位端，分时计时直接用 diScanCount 差值，
        避免 TONR 跨步骤残留。
  下标约定：H5U 数组 base 0，轴内部下标 0/1/2；故障子码用协议轴号
            AXIS_ID_CHEST=1 / AXIS_ID_SEAT=3 / AXIS_ID_LEG=2（勿与内部下标混）。
==========================================================================*)
PROGRAM PRG_Power

(* 轴内部下标 0/1/2 → 故障轴号 AXIS_ID_CHEST=1 / AXIS_ID_SEAT=3 / AXIS_ID_LEG=2 *)

(*--- 1) 单轴断使能脉冲锁存（脉冲第 1 环清、本环第 9 环消费，先锁存再参与裁决） ---*)
IF axisPulse[0, AXCMD_REQ_DISABLE] THEN pwBDisReq[0] := TRUE; END_IF;
IF axisPulse[1, AXCMD_REQ_DISABLE] THEN pwBDisReq[1] := TRUE; END_IF;
IF axisPulse[2, AXCMD_REQ_DISABLE] THEN pwBDisReq[2] := TRUE; END_IF;

(*--- 2) 上电/断电请求锁存 ---*)
IF trigAllPowerOn THEN
    pwBPwrReq := TRUE;
END_IF;
IF trigAllPowerOff THEN
    pwBPwrReq  := FALSE;
    pwBDisReq[0] := TRUE; pwBDisReq[1] := TRUE; pwBDisReq[2] := TRUE;
END_IF;

(*--- 3) 硬急停：无条件全断（清流程后跳过时序逻辑） ---*)
IF bHardEstop THEN
    pwBPwrReq         := FALSE;
    pwIPwrStep        := 0;
    axisPowerEnable[0] := FALSE;
    axisPowerEnable[1] := FALSE;
    axisPowerEnable[2] := FALSE;
    HMI.Sys.Status.bPowerOn    := FALSE;
    HMI.Sys.Status.bPoweringUp := FALSE;
END_IF;

(*--- 4) 分时上电状态机（硬急停扫跳过；pwIPwrStep 为状态机步号 0..6，非数组下标） ---*)
IF NOT bHardEstop THEN
CASE pwIPwrStep OF
    0:  (* 全断：等待上电请求（各轴 HMI 使能电平需先置位） *)
        axisPowerEnable[0] := FALSE;
        axisPowerEnable[1] := FALSE;
        axisPowerEnable[2] := FALSE;
        IF pwBPwrReq AND axisEnableReq[0] AND axisEnableReq[1] AND axisEnableReq[2] THEN
            pwIPwrStep   := 1;
            pwDiStepSnap := diScanCount;
        END_IF;

    1:  (* Chest 轴使能（内部下标 0 = 冲击轴） *)
        axisPowerEnable[0] := TRUE;
        IF HMI.ChestImpact.Status.Servo.bEnabled THEN
            pwIPwrStep   := 2;
            pwDiStepSnap := diScanCount;
        ELSIF (diScanCount - pwDiStepSnap) >= PWR_ENABLE_TIMEOUT THEN
            gFaultSubmit := TRUE; gFaultLevel := 2; gFaultCode := ERR_INIT_POWER;
            gFaultSource := SRC_POWER; gFaultSubCode := AXIS_ID_CHEST;
            pwBPwrReq := FALSE; pwIPwrStep := 0; axisPowerEnable[0] := FALSE;
        END_IF;

    2:  (* Chest→Seat 间隔（防浪涌） *)
        IF (diScanCount - pwDiStepSnap) >= PWR_STAGGER_SCAN THEN
            pwIPwrStep   := 3;
            pwDiStepSnap := diScanCount;
        END_IF;

    3:  (* Seat 轴使能（内部下标 1 = 扭角轴，故障轴号 AXIS_ID_SEAT=3） *)
        axisPowerEnable[1] := TRUE;
        IF HMI.SeatTwist.Status.Servo.bEnabled THEN
            pwIPwrStep   := 4;
            pwDiStepSnap := diScanCount;
        ELSIF (diScanCount - pwDiStepSnap) >= PWR_ENABLE_TIMEOUT THEN
            gFaultSubmit := TRUE; gFaultLevel := 2; gFaultCode := ERR_INIT_POWER;
            gFaultSource := SRC_POWER; gFaultSubCode := AXIS_ID_SEAT;
            pwBPwrReq := FALSE; pwIPwrStep := 0;
            axisPowerEnable[0] := FALSE; axisPowerEnable[1] := FALSE;
        END_IF;

    4:  (* Seat→Leg 间隔 *)
        IF (diScanCount - pwDiStepSnap) >= PWR_STAGGER_SCAN THEN
            pwIPwrStep   := 5;
            pwDiStepSnap := diScanCount;
        END_IF;

    5:  (* Leg 轴使能（内部下标 2 = 转角轴，故障轴号 AXIS_ID_LEG=2） *)
        axisPowerEnable[2] := TRUE;
        IF HMI.LegAngle.Status.Servo.bEnabled THEN
            pwIPwrStep := 6;
        ELSIF (diScanCount - pwDiStepSnap) >= PWR_ENABLE_TIMEOUT THEN
            gFaultSubmit := TRUE; gFaultLevel := 2; gFaultCode := ERR_INIT_POWER;
            gFaultSource := SRC_POWER; gFaultSubCode := AXIS_ID_LEG;
            pwBPwrReq := FALSE; pwIPwrStep := 0;
            axisPowerEnable[0] := FALSE; axisPowerEnable[1] := FALSE; axisPowerEnable[2] := FALSE;
        END_IF;

    6:  (* 全轴上电完成 *)
        ;
ELSE
    pwIPwrStep := 0;
END_CASE;

(*--- 5) 单轴断使能请求：立即断对应轴（HMI 使能电平回落亦断），并退回流程起点 ---*)
IF pwBDisReq[0] OR NOT axisEnableReq[0] THEN
    axisPowerEnable[0] := FALSE; pwBDisReq[0] := FALSE;
    IF pwIPwrStep > 0 THEN pwIPwrStep := 0; pwBPwrReq := FALSE; END_IF;
END_IF;
IF pwBDisReq[1] OR NOT axisEnableReq[1] THEN
    axisPowerEnable[1] := FALSE; pwBDisReq[1] := FALSE;
    IF pwIPwrStep > 0 THEN pwIPwrStep := 0; pwBPwrReq := FALSE; END_IF;
END_IF;
IF pwBDisReq[2] OR NOT axisEnableReq[2] THEN
    axisPowerEnable[2] := FALSE; pwBDisReq[2] := FALSE;
    IF pwIPwrStep > 0 THEN pwIPwrStep := 0; pwBPwrReq := FALSE; END_IF;
END_IF;
END_IF;  (* IF NOT bHardEstop *)

(*--- 6) 上电状态上报（READY_CHECK HW 位依赖 bPowerOn） ---*)
HMI.Sys.Status.bPowerOn := (pwIPwrStep = 6)
    AND HMI.ChestImpact.Status.Servo.bEnabled
    AND HMI.SeatTwist.Status.Servo.bEnabled
    AND HMI.LegAngle.Status.Servo.bEnabled;
HMI.Sys.Status.bPoweringUp := (pwIPwrStep >= 1) AND (pwIPwrStep <= 5);

END_PROGRAM
