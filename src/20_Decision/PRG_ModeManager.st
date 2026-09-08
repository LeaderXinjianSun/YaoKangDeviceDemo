(*============================================================================
  PRG_ModeManager —— 层 20 决策：系统状态机（扫描链第 6 环），iState 唯一写入者
  ----------------------------------------------------------------------------
  唯一写入：iState / iWorkMode / iUserRole / iBlockReason（全局）；
            Sys.Status 的 iState/iHealthLevel/diReadyCheckResult/bReady/
            bSafeToStart/bAutoProcessRunning/bIsEmergency/bNeedReset；
            离态残留电平命令（axisJogPos/axisJogNeg/jogPushUp/jogPushDown/pushEnableReq）。
  读入：  安全态 bHardEstop/bSoftEstop/bSafetyStop（最高优先级）；
          trig* 脉冲位（INPUT_ADAPTER 单扫锁存）、HMI.Sys.Cmd 的电平/INT 字段
          （iUserRole/iAuthCode/iWorkMode/bServiceAuthConfirm/bNoLoadConfirm）；
          资格位 bAllAxesIdle/Ref/AtInit、bParamBootDone/bRunParamValid；
          任务上报：Condition.Status.bDone/bError、HMI.Sys.Status.bSelfTestDone。
  规则：任务模块不直接切态，只上报 iPhase/iBlockReason 与任务状态位；切换须过门控
        （角色/权限码/资格/安全）；急停态无条件穿透；离态清残留电平命令。
  READY_CHECK：diReadyCheckResult 为位掩码（READY_BIT_*），0=全过；不齐时
        每 100 扫提交一次 7001 Warning，掩码值随 iVal1 上报。
==========================================================================*)
PROGRAM PRG_ModeManager

(*============================================================================
  0. 每扫公共计算：角色/工作模式镜像 + 六项资格掩码 + 汇总状态
  ==========================================================================*)
(*--- 工程师双重门控：角色 + 权限码 16#5A ---*)
mmBEngineer := (HMI.Sys.Cmd.iUserRole = ROLE_ENGINEER)
         AND (HMI.Sys.Cmd.iAuthCode = AUTH_CODE_ENGINEER);
iUserRole := HMI.Sys.Cmd.iUserRole;   (* 角色镜像（操作员/工程师） *)

(*--- 六项资格掩码（位定义见 GVL_CONST READY_BIT_*） ---*)
mmDiMask := DINT#0;
IF NOT bAllAxesRef THEN
    mmDiMask := mmDiMask OR SHL(DINT#1, READY_BIT_REF);      (* bit5 参考无效 *)
END_IF;
IF NOT bRunParamValid OR NOT bParamBootDone THEN
    mmDiMask := mmDiMask OR SHL(DINT#1, READY_BIT_PARAM);   (* bit1 参数无效 *)
END_IF;
IF NOT HMI.Sys.Status.bPowerOn THEN
    mmDiMask := mmDiMask OR SHL(DINT#1, READY_BIT_HW);      (* bit2 硬件未上电 *)
END_IF;
IF HMI.Sys.Error.bActive THEN
    mmDiMask := mmDiMask OR SHL(DINT#1, READY_BIT_HEALTH);  (* bit3 活动 Critical *)
END_IF;
IF NOT bAllAxesAtInit THEN
    mmDiMask := mmDiMask OR SHL(DINT#1, READY_BIT_POS);     (* bit4 未在初始位 *)
END_IF;
IF NOT (retainZeroComm[1] AND retainZeroComm[2] AND retainZeroComm[3] AND retainTailZeroComm) THEN
    mmDiMask := mmDiMask OR SHL(DINT#1, READY_BIT_ZERO);    (* bit0 未建零 *)
END_IF;
mmBReadyAll := (mmDiMask = 0);

(*--- 汇总状态回填 Sys.Status ---*)
HMI.Sys.Status.iState             := iState;
HMI.Sys.Status.diReadyCheckResult := mmDiMask;
HMI.Sys.Status.bReady             := (iState = ST_STANDBY) AND mmBReadyAll;
HMI.Sys.Status.bSafeToStart       := mmBReadyAll AND (iState = ST_STANDBY)
                                AND NOT bSafetyStop AND NOT bHardEstop AND NOT bSoftEstop;
HMI.Sys.Status.bIsEmergency       := bHardEstop OR bSoftEstop OR bSafetyStop;
HMI.Sys.Status.bNeedReset         := HMI.Sys.Error.bNeedReset OR HMI.Sys.Error.bActive;
HMI.Sys.Status.bAutoProcessRunning:= (iState = ST_AUTORUN);
HMI.Sys.Status.iWorkMode          := iWorkMode;

(*--- 跳过自检资格位（P11） ---*)
(* 操作员快速启动：六项资格齐（含参考/建零），自检可安全省略；任何活动错误撤销资格 *)
HMI.Sys.Status.bSkipSelfTestAllowed := mmBReadyAll AND NOT HMI.Sys.Error.bActive;
(* 工程师强制跳过：需工程师双重门控（角色+权限码 16#5A），不受就绪位限制 *)
HMI.Sys.Status.bForceSkipSelfTestAllowed := mmBEngineer;

(*--- 健康等级 ---*)
IF HMI.Sys.Error.bActive THEN
    HMI.Sys.Status.iHealthLevel := HEALTH_FAULT;      (* 0 故障 *)
ELSIF HMI.Sys.Warning.bActive THEN
    HMI.Sys.Status.iHealthLevel := HEALTH_WARNING;    (* 2 警告 *)
ELSIF mmBReadyAll THEN
    HMI.Sys.Status.iHealthLevel := HEALTH_NORMAL;     (* 1 正常 *)
ELSE
    HMI.Sys.Status.iHealthLevel := HEALTH_UNKNOWN;    (* 3 未就绪 *)
END_IF;


(*============================================================================
  1. 急停最高优先级：任何状态无条件穿透
  ==========================================================================*)
IF bHardEstop THEN
    iState := ST_HARD_ESTOP;    (* 120 硬急停：断使能 *)
ELSIF bSoftEstop THEN
    iState := ST_SOFT_ESTOP;    (* 110 软急停：受控减速 *)
ELSE

    (* H5U：CASE 标签须用字面整数（具名常量按变量处理会报错），行尾注释码值 *)
    CASE iState OF

        (*---------- 0 上电初始化：参数首扫装载后转就绪检查 ----------*)
        0:
            IF bParamBootDone THEN
                iState := ST_READY_CHECK;    (* 3 *)
            END_IF;

        (*---------- 3 就绪检查：六项资格；齐→STANDBY，不齐节流报 7001 ----------*)
        3:
            IF trigReadyCheck OR mmBReadyAll THEN
                IF mmBReadyAll THEN
                    iState := ST_STANDBY;    (* 10 *)
                ELSE
                    mmIWarnDv := mmIWarnDv + 1;
                    IF mmIWarnDv >= 100 THEN
                        mmIWarnDv := 0;
                        gFaultLevel := 1;  gFaultCode := ERR_PRECHK_READY;
                        gFaultSource := SRC_MODE;  gFaultSubCode := 0;
                        gFaultVal1 := 0;  gFaultVal2 := 0;   (* 掩码见 Sys.Status.diReadyCheckResult *)
                        gFaultSubmit := TRUE;
                    END_IF;
                END_IF;
            END_IF;

        (*---------- 5 自检：任务完成→STANDBY；任务报错→STOPPING ----------*)
        5:
            IF trigSysStop THEN
                iState := ST_STOPPING;       (* 60 *)
            ELSIF HMI.Sys.Status.bSelfTestDone THEN
                iState := ST_STANDBY;        (* 10 *)
            END_IF;
            (* 自检失败由任务经 gFaultSubmit 提交 Critical，ErrorManager 置
               bNeedReset；本态检测到活动 Critical 即转 RESET 收口。 *)
            IF HMI.Sys.Error.bActive AND NOT HMI.Sys.Status.bSelfTestDone THEN
                iState := ST_RESET;          (* 50 *)
            END_IF;

        (*---------- 10 待机：全部门控入口 ----------*)
        10:
            (*--- 急停已在顶层穿透；停止/复位类 ---*)
            IF trigSysReset AND HMI.Sys.Error.bActive THEN
                iState := ST_RESET;          (* 50 *)
            (*--- 维护模式（工程师） ---*)
            ELSIF trigServiceMode AND mmBEngineer THEN
                iState := ST_SERVICE;        (* 30 *)
            (*--- 推杆标定（工程师） ---*)
            ELSIF trigCalibrate AND mmBEngineer THEN
                iState := ST_CALIBRATE;      (* 45 *)
            (*--- 回零（操作员/工程师均可；需硬件就绪） ---*)
            ELSIF trigSysHoming AND HMI.Sys.Status.bPowerOn THEN
                iState := ST_HOMING;         (* 40 *)
            (*--- 自检（工程师启动，或需强制跳过资格） ---*)
            ELSIF trigStartSelfTest AND mmBEngineer THEN
                iState := ST_SELFTEST;       (* 5 *)
            (*--- 自动流程：直接启动或快速启动（快速启动需资格位） ---*)
            ELSIF (trigAutoStart OR trigStart)
              AND (bSafeToStart OR (trigQuickStart AND HMI.Sys.Status.bSkipSelfTestAllowed)) THEN
                IF iWorkMode = 0 THEN
                    iWorkMode := HMI.Sys.Cmd.iWorkMode;   (* 锁存工作模式快照 *)
                END_IF;
                iState := ST_AUTORUN;        (* 20 *)
            END_IF;

        (*---------- 15 需要服务：仅工程师复位/维护可离开（保留态） ----------*)
        15:
            IF trigSysReset AND mmBEngineer THEN
                iState := ST_RESET;          (* 50 *)
            ELSIF trigServiceMode AND mmBEngineer THEN
                iState := ST_SERVICE;        (* 30 *)
            END_IF;

        (*---------- 20 自动流程运行：任务完成回 STANDBY；停止→STOPPING；急停顶层穿透 ----------*)
        20:
            IF trigSysStop OR trigStop THEN
                iState := ST_STOPPING;       (* 60 安全降落 *)
            ELSIF HMI.Condition.Status.bDone THEN
                iWorkMode := 0;
                iState := ST_STANDBY;        (* 10 完成 *)
            ELSIF HMI.Condition.Status.bEmergencyStop OR HMI.Condition.Status.bError THEN
                iState := ST_STOPPING;       (* 60 异常收口 *)
            END_IF;

        (*---------- 30 维护：维护完成回 STANDBY；可发起标定/回零（工程师） ----------*)
        30:
            IF trigServiceDone OR trigSysStop THEN
                iState := ST_STANDBY;        (* 10 *)
            ELSIF trigCalibrate THEN
                iState := ST_CALIBRATE;      (* 45 *)
            ELSIF trigSysHoming AND HMI.Sys.Status.bPowerOn THEN
                iState := ST_HOMING;         (* 40 *)
            END_IF;

        (*---------- 40 回零：回零完成→请求就绪检查；停止→STOPPING ----------*)
        40:
            IF trigSysStop THEN
                iState := ST_STOPPING;       (* 60 *)
            ELSIF bAllAxesRef AND bAllAxesAtInit AND bAllAxesIdle THEN
                (* 三轴参考有效且归初始位，维持 1s 稳定后由任务置 bHomeDone 收口；
                   此处仅以资格位判定完成，任务侧 iPhase=9 时回 STANDBY。 *)
                IF iPhase = COND_DONE THEN
                    iState := ST_STANDBY;    (* 10 *)
                END_IF;
            END_IF;
            IF HMI.Sys.Error.bActive THEN
                iState := ST_RESET;          (* 50 回零失败收口 *)
            END_IF;

        (*---------- 45 推杆标定：完成回原态（维护发起→SERVICE，待机发起→STANDBY） ----------*)
        45:
            IF trigSysStop THEN
                iState := ST_STOPPING;       (* 60 *)
            ELSIF HMI.TailTilt.Status.bCalibrated OR (iPhase = COND_DONE) THEN
                iState := ST_STANDBY;        (* 10（简化：标定完成回待机） *)
            END_IF;
            IF HMI.Sys.Error.bActive THEN
                iState := ST_RESET;          (* 50 标定失败收口 *)
            END_IF;

        (*---------- 50 复位收口：错误清除 + 轴复位后回 STANDBY ----------*)
        50:
            (* 复位任务（TaskRunner 50 分支）清 iPhase；待活动错误已被 ErrorManager
               清除且全轴静止，即回待机。残留 iState 写已从 TaskRunner 移除。 *)
            IF (NOT HMI.Sys.Error.bActive) AND bAllAxesIdle THEN
                iState := ST_STANDBY;        (* 10 *)
            END_IF;

        (*---------- 60 停止中：安全降落到初始位，停稳后回 STANDBY ----------*)
        60:
            IF bAllAxesIdle AND bAllAxesAtInit THEN
                iState := ST_STANDBY;        (* 10 *)
            END_IF;
            IF HMI.Sys.Error.bActive THEN
                iState := ST_RESET;          (* 50 停止中并发故障 *)
            END_IF;

        (*---------- 110 软急停：受控减速 + 紧急回零（任务）；解除+复位→RESET ----------*)
        110:
            IF (NOT bSafetyStop) AND trigSysReset THEN
                iState := ST_RESET;          (* 50 *)
            END_IF;

        (*---------- 120 硬急停：断使能；物理链恢复 + 复位→RESET ----------*)
        120:
            IF (NOT bSafetyStop) AND (NOT bHardEstopLatch) AND trigSysReset THEN
                iState := ST_RESET;          (* 50 *)
            END_IF;

        (*---------- 998 参数受限：保留（参数快照不一致等降级态），复位可回 STANDBY ----------*)
        998:

            IF trigSysReset AND mmBEngineer THEN
                iState := ST_RESET;          (* 50 *)
            END_IF;

    ELSE
        iState := ST_INIT;    (* 0 未定义态兜底回上电 *)
    END_CASE;
END_IF;


(*============================================================================
  2. 离态清残留电平命令（安全约定）
     运动/点动类电平仅在明确许可的任务态有效；离开待机/维护进入自动/自检/
     回零/急停等态时，强制清零点动与推杆使能，防止跨态残留驱动。
     INPUT_ADAPTER 每扫先写电平位，本环在其后执行，故此处清零本扫生效。
  ==========================================================================*)
IF NOT ((iState = ST_STANDBY) OR (iState = ST_SERVICE)) THEN
    axisJogPos[1] := FALSE;  axisJogPos[2] := FALSE;  axisJogPos[3] := FALSE;
    axisJogNeg[1] := FALSE;  axisJogNeg[2] := FALSE;  axisJogNeg[3] := FALSE;
    jogPushUp   := FALSE;
    jogPushDown := FALSE;
END_IF;
(* 推杆使能仅在待机/维护/标定/回零/自动（成角段）允许；急停/复位/停止中断 *)
IF (iState = ST_HARD_ESTOP) OR (iState = ST_SOFT_ESTOP)
   OR (iState = ST_RESET) OR (iState = ST_STOPPING) THEN
    pushEnableReq := FALSE;
END_IF;

END_PROGRAM
