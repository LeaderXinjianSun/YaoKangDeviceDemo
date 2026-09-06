(*============================================================================
  PRG_SafetyManager —— 层 20 决策：安全防护（扫描链第 5 环），独立常驻
  ----------------------------------------------------------------------------
  唯一写入：bHardEstop/bSoftEstop/bSafetyStop（安全态）；致命故障经
            gFaultSubmit 提交（ERROR_MANAGER 入队）。
  读入：  ioEstopOK（物理急停常闭）、HMI.Sys.Cmd.bEmergencyStopReq（软急停）、
          轴/推杆限位与状态、力估算、堵转诊断。
  优先级：硬急停 > 软急停 > 安全停止；任何 iState 下都生效，不依赖业务状态。
  P1：急停链（物理常闭 + 软急停按钮）。
  P4：停止超时升级硬急停、扭矩防夹、超力锁存、堵转、软/硬限位、编码器故障、
      原点传感器健康、任务步骤超时升级。
==========================================================================*)
PROGRAM PRG_SafetyManager
VAR
    (* 定时器：H5U 内联 TONR(IN:=,PT:=,Q=>布尔位)，无需 TON 实例；tSoftStop 即 Q=> 输出。 *)
    tSoftStop   : BOOL;        (* 软急停减速超时（TONR Q=>tSoftStop） *)
    (* 上升沿：H5U 类型 TRIG.R_TRIG，仅局部 VAR 可声明，读 .Q。 *)
    rTrigSoft   : TRIG.R_TRIG;
    rTrigHard   : TRIG.R_TRIG;
END_VAR

(*--- 硬急停：物理急停常闭断开（ioEstopOK=FALSE）无条件触发，断使能 ---*)
bHardEstop := NOT ioEstopOK;

(*--- 软急停：HMI 软急停按钮（P2 补 Sys.Cmd 边沿解析后可换 trig*） ---*)
bSoftEstop := HMI.Sys.Cmd.bEmergencyStopReq AND NOT bHardEstop;

(*--- 软急停减速超时（diSoftStopTime 待回零/系统参数落地，暂用 5s 占位） ---*)
TONR(IN := bSoftEstop, PT := T#5S, Q => tSoftStop);
IF tSoftStop THEN
    bSoftEstop := FALSE;
    bHardEstop := TRUE;    (* 减速超时升级硬急停 *)
END_IF;

(*--- 安全停止请求（急停链有效期间，供 POWER/OUTPUT_ADAPTER 执行停车） ---*)
bSafetyStop := bHardEstop OR bSoftEstop;

(*--- 急停事件上报（上升沿提交一次） ---*)
rTrigHard(CLK := bHardEstop);
rTrigSoft(CLK := bSoftEstop);
IF rTrigHard.Q THEN
    gFaultLevel  := 2;
    gFaultCode   := 1001;   (* TODO P3: 硬急停码值以码表为准 *)
    gFaultSource := 1;      (* 安全模块 *)
    gFaultSubCode:= 0;
    gFaultVal1   := 0;
    gFaultVal2   := 0;
    gFaultSubmit := TRUE;
ELSIF rTrigSoft.Q THEN
    gFaultLevel  := 2;
    gFaultCode   := 1002;   (* TODO P3: 软急停码值以码表为准 *)
    gFaultSource := 1;
    gFaultSubCode:= 0;
    gFaultVal1   := 0;
    gFaultVal2   := 0;
    gFaultSubmit := TRUE;
END_IF;

(* TODO P4:
   - 超力保护：Force.rForceFiltN 超阈持续 diOverForceET → 锁存 bOverForceLatched + 停机。
   - 扭矩防夹：Jog/紧急回零扭矩超阈 → 立即停 + 可控重试（12xx）。
   - 推杆堵转：电流/速度趋零持续 diStallTimeout → 停 + 换向缓冲重试（5001）。
   - 软/硬限位：bPosLimit/bNegLimit 禁越限运动，提供脱限 Jog。
   - 编码器故障 bEncoderFault → 绝对位置不可信，禁定位类动作。
   - 任务步骤超时 → 安全收口（STOPPING/ESTOP）。 *)
END_PROGRAM
