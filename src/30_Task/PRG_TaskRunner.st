(*============================================================================
  PRG_TaskRunner —— 层 30 任务：任务调度（扫描链第 7 环）
  ----------------------------------------------------------------------------
  扫描链：…→5 SafetyManager→6 ModeManager→【7 TaskRunner】→8 ParamService…
  唯一写入：iPhase（任务内阶段上报）；任务级 Cmd/Motion（HMI 各轴/推杆 Cmd 与
            Motion 参数块）；bZeroCommSetReq；故障经 gFaultSubmit。
  读入：  iState（MODE_MANAGER 单写）、trig* 命令边沿、内部运行区参数 run*、
          HMI.<Axis>.Status / HMI.TailTilt.Status。
  分派：按 iState 调度 SELFTEST(5)/HOMING(40)/CALIBRATE(45)/SOFT_ESTOP(110)
        /AUTORUN(20)/STOPPING(60)/RESET(50)；任务模块只写任务级命令与 Motion
        参数块，MC 指令由 OUTPUT_ADAPTER（环10）唯一执行；不直接切 iState。

  ── 运动命令通道时序（环序约束，务必遵守） ──────────────────────────────
  · 脉冲位（bMoveAbs/bMoveRel/bMoveBuffer/bStop/bReset/bZeroCommission/
    bAutoMove、推杆 bAutoMove/bHome/bCalibrate）：本环置 HMI.<X>.Cmd.bYyy:=TRUE
    【仅一个扫描周期】；下一扫环2 InputAdapter 的 R_TRIG 检出上升沿、锁存进
    axisPulse[i,AXCMD_*]/trigPush*，并同扫末把 HMI 脉冲位清 FALSE。故单次置位
    恰好产生 1 个内部脉冲（滞后 1 扫）。
  · 电平位（bJogPos/bJogNeg）：环2 InputAdapter 每扫直镜像 axisJogPos/Neg
    （不清）；按住期间本环须持续写 HMI.<Axis>.Cmd.bJogPos/Neg:=TRUE，放手写 FALSE。
    软急停(110) Jog 已由 ModeManager 离态清理放行（ST_SOFT_ESTOP 不清三轴 Jog）；
    但 FB 内 bSafetyStop 门控——软急停减速电平未释放前不进 Jog 分支。
  · 运动参数（电平）：环10 OutputAdapter 直读 HMI.<Axis>.Motion.rTargetPos/
    rTargetVel/rJogVel/rAcc/rDec 喂 FB；rInitPos/限位/超时接 runAxis[i]；段表
    arSegPos/arSegVel/iSegCount 由环10 从 runCond.<Axis> 接线；bZeroCommRetain
    接 retainZeroComm[i]。故 130 MoveBuffer 前须先把 rAcc/rDec 写入 HMI.Motion。
  · 故障上报：环10 OutputAdapter 也写 gFault*（同扫后写覆盖先写），故本环用
    trBFaultLat/trBFaultSent 锁存、仅在 gFaultSubmit 空闲时装填，每扫至多 1 条。

  ── 一次性动作时序（本版关键修正） ─────────────────────────────────────
  · trBStateEntry 仅在【iState 变化】那一扫为 TRUE，子步切换不置位。故所有
    "进入某子步只做一次"的动作（发脉冲/装快照/装载目标）一律放在【转换点】：
    在判据成立、置 trIStepXxx:=下一步 的【同一扫】内联执行，绝不依赖
    trBStateEntry 触发子步动作。
  · 状态进入沿 trBStateEntry 仅用于：清故障锁存、把该状态的子步复位到入口步
    （消除上轮残留子步）。

  H5U 约定：①定时器内联 TONR（本块不用，超时一律 diScanCount 快照差值×10ms）；
        ②TRIG.R_TRIG 边沿实例仅局部 VAR（rDoneEdge/rFootEdge）；③CASE 标签
        字面整数 + 行尾注释；④无过程调用，故障上报/三轴访问全部内联；简单
        工作变量全部用 GVL_Internal 的 tr* 全局（H5U 局部 VAR 不允许简单变量）。
  轴序：内部下标 i=1 Chest冲击(HMI.ChestImpact) / 2 Seat扭角(HMI.SeatTwist) /
        3 Leg转角(HMI.LegAngle)；故障轴号 AXIS_ID_CHEST=1/SEAT=3/LEG=2
        （Seat/Leg 故障号与内部下标互换）。
==========================================================================*)
PROGRAM PRG_TaskRunner
VAR
    rDoneEdge : TRIG.R_TRIG;   (* 推杆 bDone 单扫脉冲上升沿捕获（跨扫） *)
    rFootEdge : TRIG.R_TRIG;   (* 脚踏电平 bFootSignal 上升沿捕获 *)
END_VAR

(*============================================================================
  0) 公共：状态进入沿 + 跨扫边沿实例
==========================================================================*)
trBStateEntry := (iState <> trIPrevState);
trIPrevState  := iState;

(* 推杆 bDone 为 FB 每扫顶置 FALSE 的单扫脉冲，经环10 回填 HMI 后本环下扫捕获 *)
rDoneEdge(CLK := HMI.TailTilt.Status.bDone);
rFootEdge(CLK := bFootSignal);

(*============================================================================
  1) 公共：故障锁存提交（每扫至多 1 条；环10 同扫后写会覆盖，故仅空闲时装填）
     检测点内联置 trBFaultLat:=TRUE 并装填锁存字段；本段在 gFaultSubmit 空闲时
     把锁存故障送出。Critical 锁存保持至状态退出（trBStateEntry 清锁存）；
     Warning 送出即清。
==========================================================================*)
IF trBStateEntry THEN
    trBFaultLat   := FALSE;
    trBFaultSent  := FALSE;
    trILatSentCode:= 0;
END_IF;
IF trBFaultLat AND (NOT trBFaultSent) AND (NOT gFaultSubmit) THEN
    gFaultLevel   := trILatLevel;
    gFaultCode    := trILatCode;
    gFaultSource  := trILatSource;
    gFaultSubCode := trILatSub;
    gFaultVal1    := 0;
    gFaultVal2    := 0;
    gFaultSubmit  := TRUE;
    trBFaultSent  := TRUE;
    trILatSentCode:= trILatCode;
    IF trILatLevel = 1 THEN
        trBFaultLat := FALSE;   (* Warning 送出即释放，允许后续新故障 *)
    END_IF;
END_IF;
IF trBFaultSent AND (NOT gFaultSubmit) THEN
    trBFaultSent := FALSE;      (* 已被环4 消费，可送下一条（换码重发） *)
END_IF;

(*============================================================================
  2) 任务分派（CASE iState）
==========================================================================*)
CASE iState OF

    (*===== 10 ST_STANDBY：就绪态，任务层空闲 =====*)
    10:
        iPhase := 0;
        HMI.Condition.Status.iStep := 0;

    (*===== 20 ST_AUTORUN：调理/治疗/老化（P10） =====*)
    20:
        (* 状态进入：子步复位到门控（一次性动作在各转换点内联执行） *)
        IF trBStateEntry THEN
            trIStepCond := 105;
        END_IF;

        CASE trIStepCond OF
            105: // CONDSEQ_GATE 启动前检查
                HMI.Condition.Status.iStep := 105;
                (* 门控：急停/就绪/参考/初始位/使能静止/参数（7001-7005）。
                   判据成立的同一扫内联装载计数/快照并转 108。 *)
                IF bSafetyStop OR bHardEstop THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_PRECHK_READY;
                    trILatSource := SRC_COND; trILatSub := 0;
                    trIStepCond := 900;
                ELSIF NOT bRunParamValid THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_PRECHK_PARAM;
                    trILatSource := SRC_COND; trILatSub := 0;
                    trIStepCond := 900;
                ELSIF NOT bAllAxesRef THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_PRECHK_ZERO;
                    trILatSource := SRC_COND; trILatSub := 0;
                    trIStepCond := 900;
                ELSIF NOT (HMI.ChestImpact.Status.Servo.bEnabled
                       AND HMI.SeatTwist.Status.Servo.bEnabled
                       AND HMI.LegAngle.Status.Servo.bEnabled)
                   OR NOT bAllAxesIdle THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_PRECHK_AXIS;
                    trILatSource := SRC_COND; trILatSub := 0;
                    trIStepCond := 900;
                ELSIF NOT bAllAxesAtInit THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_PRECHK_POS;
                    trILatSource := SRC_COND; trILatSub := 0;
                    trIStepCond := 900;
                ELSE
                    (* 转换点：装载本批运行上下文 *)
                    trBCondRunStart := FALSE;
                    trBCondPaused   := FALSE;
                    trBCondCnfTout  := FALSE;
                    trBCondAngleSkip:= FALSE;
                    trBAgingAuto    := (iWorkMode = WORKMODE_AGING);
                    trICondCycle    := 1;
                    trICondTarget   := runCond.iCycleCount;
                    trDiCondBatch   := 1;
                    HMI.Condition.Status.bError         := FALSE;
                    HMI.Condition.Status.bEmergencyStop := FALSE;
                    trDiConfirmSnap := diScanCount;
                    trIStepCond     := 108;   // CONDSEQ_WAIT_PREP
                END_IF;

            108: // CONDSEQ_WAIT_PREP 等待人员准备（S2 成角 / 跳过成角）
                HMI.Condition.Status.iStep         := 108;
                HMI.Condition.Status.bWaitingAngle := TRUE;
                IF trigSkipAngle THEN
                    (* 转换点：跳过成角，直接等开始信号 *)
                    trBCondAngleSkip := TRUE;
                    HMI.Condition.Status.bWaitingAngle := FALSE;
                    trDiConfirmSnap := diScanCount;
                    trBAutoSignal   := FALSE;
                    trIStepCond     := 120;
                ELSIF trigChengJiao THEN
                    (* 转换点：发推杆成角 AutoMove 脉冲（单扫），装推杆快照，转 110 *)
                    HMI.Condition.Status.bWaitingAngle := FALSE;
                    HMI.TailTilt.Motion.rTargetAngle := runCond.rPusherPos;
                    HMI.TailTilt.Cmd.bAutoMove := TRUE;
                    trDiPushSnap := diScanCount;
                    trIStepCond  := 110;   // CONDSEQ_ANGLE
                END_IF;
                (* 准备确认超时（Warning，7007；<=0 禁用） *)
                IF (runCond.diConfirmTimeout > 0)
                   AND ((diScanCount - trDiConfirmSnap) * 10 >= runCond.diConfirmTimeout)
                   AND NOT trBCondCnfTout THEN
                    trBCondCnfTout := TRUE;
                    trBFaultLat := TRUE; trILatLevel := 1; trILatCode := ERR_COND_CONFIRM_TOUT;
                    trILatSource := SRC_COND; trILatSub := 0;
                END_IF;

            110: // CONDSEQ_ANGLE 成角定位（推杆 AutoMove → rPusherPos）
                HMI.Condition.Status.iStep     := 110;
                HMI.Condition.Status.bAngleDone := FALSE;
                IF rDoneEdge.Q THEN
                    (* 转换点：成角到位，装等信号快照转 120 *)
                    HMI.Condition.Status.bAngleDone := TRUE;
                    trDiConfirmSnap := diScanCount;
                    trBAutoSignal   := FALSE;
                    trIStepCond     := 120;   // CONDSEQ_WAIT_SIGNAL
                ELSIF HMI.TailTilt.Status.bError THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := HMI.TailTilt.Status.iErrorCode;
                    trILatSource := SRC_PUSHER; trILatSub := 0;
                    trIStepCond := 900;
                ELSIF (diScanCount - trDiPushSnap) >= ST_PUSHER_TOUT_SCAN THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_SELFTEST_PUSHER;
                    trILatSource := SRC_PUSHER; trILatSub := 0;
                    trIStepCond := 900;
                END_IF;

            120: // CONDSEQ_WAIT_SIGNAL 等待开始确认（S3/脚踏；信号模式=1 自动放行）
                HMI.Condition.Status.iStep          := 120;
                HMI.Condition.Status.bWaitingSignal := TRUE;
                (* 老化或信号模式=自动：内部自动产生开始信号（无需脚踏） *)
                IF trBAgingAuto OR (runCond.iSignalMode = 1) THEN
                    trBAutoSignal := TRUE;
                END_IF;
                IF trigAllow OR rFootEdge.Q OR trBAutoSignal THEN
                    (* 转换点：装运行快照/计数，转 130 发段表 *)
                    HMI.Condition.Status.bWaitingSignal := FALSE;
                    trDiCondSnap    := diScanCount;
                    trBCondRunStart := FALSE;
                    trDiCondDoneSnap:= 0;
                    trICondCycle    := 1;
                    trIStepCond     := 130;   // CONDSEQ_RUN
                END_IF;
                IF (runCond.diConfirmTimeout > 0)
                   AND ((diScanCount - trDiConfirmSnap) * 10 >= runCond.diConfirmTimeout)
                   AND NOT trBCondCnfTout THEN
                    trBCondCnfTout := TRUE;
                    trBFaultLat := TRUE; trILatLevel := 1; trILatCode := ERR_COND_CONFIRM_TOUT;
                    trILatSource := SRC_COND; trILatSub := 0;
                END_IF;

            130: // CONDSEQ_RUN 三轴 16 段轨迹 × 循环联动（暂停/恢复贯穿）
                HMI.Condition.Status.iStep        := 130;
                HMI.Condition.Status.bRunning     := TRUE;
                HMI.Condition.Status.bMoving      := TRUE;
                HMI.Condition.Status.iCurrentCycle:= trICondCycle;
                HMI.Condition.Status.iTargetCycles:= trICondTarget;

                (* 暂停/恢复（电平）：暂停期间不发启动脉冲；FB 段表保持，恢复续跑 *)
                IF bPauseLevel AND NOT bResumeLevel THEN
                    trBCondPaused := TRUE;
                ELSIF bResumeLevel THEN
                    trBCondPaused := FALSE;
                END_IF;
                HMI.Condition.Status.bPaused := trBCondPaused;

                IF NOT trBCondRunStart THEN
                    (* 尚未启动本循环：非暂停时发一次 MoveBuffer（段表由环10 接线，
                       rAcc/rDec 须先写 HMI.Motion；脉冲单扫，环2 锁存 MOVEBUFFER） *)
                    IF NOT trBCondPaused THEN
                        HMI.ChestImpact.Motion.rAcc := runCond.ChestImpact.rAcc;
                        HMI.ChestImpact.Motion.rDec := runCond.ChestImpact.rDec;
                        HMI.SeatTwist.Motion.rAcc   := runCond.SeatTwist.rAcc;
                        HMI.SeatTwist.Motion.rDec   := runCond.SeatTwist.rDec;
                        HMI.LegAngle.Motion.rAcc    := runCond.LegAngle.rAcc;
                        HMI.LegAngle.Motion.rDec    := runCond.LegAngle.rDec;
                        HMI.ChestImpact.Cmd.bMoveBuffer := TRUE;
                        HMI.SeatTwist.Cmd.bMoveBuffer   := TRUE;
                        HMI.LegAngle.Cmd.bMoveBuffer    := TRUE;
                        trBCondRunStart := TRUE;
                        trDiCondDoneSnap:= 0;   (* 0=尚未见运动 *)
                    END_IF;
                ELSE
                    (* 本循环已启动：须先见到轴离开静止（FB 受理段表），再等回到
                       静止（段表跑完）才判本循环完成——消除启动滞后 1-2 扫内
                       bAllAxesIdle 仍真导致的重复发令/循环数误增。 *)
                    IF NOT bAllAxesIdle THEN
                        trDiCondDoneSnap := diScanCount;   (* 非 0=已见运动，记录时刻 *)
                    ELSIF trDiCondDoneSnap <> 0 THEN
                        (* 已见运动且现已回静止：本循环段表跑完 *)
                        IF trICondCycle >= trICondTarget THEN
                            HMI.Condition.Status.bMoving  := FALSE;
                            HMI.Condition.Status.bRunning := FALSE;
                            (* 转换点：发推杆回零 bHome 脉冲（单扫），装快照转 140 *)
                            HMI.TailTilt.Cmd.bHome := TRUE;
                            trDiPushSnap := diScanCount;
                            trIStepCond  := 140;   // CONDSEQ_LAND
                        ELSE
                            (* 下一循环：清启动锁存，下扫重发 MoveBuffer（此时轴已
                               静止，FB 可受理新段表） *)
                            trICondCycle  := trICondCycle + 1;
                            diStatTotalCycles := diStatTotalCycles + 1;
                            trBCondRunStart := FALSE;
                            trDiCondDoneSnap:= 0;
                        END_IF;
                    END_IF;
                END_IF;
                (* 总超时（单批 diTotalTimeout，7006 Critical） *)
                IF (runCond.diTotalTimeout > 0)
                   AND ((diScanCount - trDiCondSnap) * 10 >= runCond.diTotalTimeout) THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_COND_RUN_TIMEOUT;
                    trILatSource := SRC_COND; trILatSub := 0;
                    trIStepCond := 900;
                END_IF;
                (* 急停收口兜底（ModeManager 主判 bError/急停转 STOPPING/RESET） *)
                IF HMI.Condition.Status.bEmergencyStop THEN
                    trIStepCond := 900;
                END_IF;

            140: // CONDSEQ_LAND 安全降落（推杆回 rPusherInitPos）
                HMI.Condition.Status.iStep     := 140;
                HMI.Condition.Status.bHomeDone := FALSE;
                IF rDoneEdge.Q THEN
                    HMI.Condition.Status.bHomeDone := TRUE;
                    IF trBAgingAuto AND (trDiCondBatch < runCond.diBatchCount) THEN
                        (* 转换点：老化批间等待，装批间快照转 145 *)
                        trDiBatchSnap := diScanCount;
                        trIStepCond   := 145;   // CONDSEQ_BATCH_WAIT
                    ELSE
                        trIStepCond := 800;   // CONDSEQ_DONE
                    END_IF;
                ELSIF HMI.TailTilt.Status.bError THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := HMI.TailTilt.Status.iErrorCode;
                    trILatSource := SRC_PUSHER; trILatSub := 0;
                    trIStepCond := 900;
                ELSIF (diScanCount - trDiPushSnap) >= ST_PUSHER_TOUT_SCAN THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_SELFTEST_PUSHER;
                    trILatSource := SRC_PUSHER; trILatSub := 0;
                    trIStepCond := 900;
                END_IF;

            145: // CONDSEQ_BATCH_WAIT 老化批间等待（diBatchInterval）
                HMI.Condition.Status.iStep             := 145;
                HMI.Condition.Status.diBatchCurrent    := trDiCondBatch;
                HMI.Condition.Status.diBatchTarget     := runCond.diBatchCount;
                HMI.Condition.Status.diBatchRemainTime := runCond.diBatchInterval
                                                          - (diScanCount - trDiBatchSnap) * 10;
                IF (diScanCount - trDiBatchSnap) * 10 >= runCond.diBatchInterval THEN
                    (* 转换点：批次+1，统计老化循环，回到准备 108 *)
                    trDiCondBatch := trDiCondBatch + 1;
                    diStatAgingCycles := diStatAgingCycles + trICondTarget;
                    HMI.Condition.Status.bBatchDone := (trDiCondBatch > runCond.diBatchCount);
                    trICondCycle    := 1;
                    trBCondRunStart := FALSE;
                    trDiConfirmSnap := diScanCount;
                    trIStepCond     := 108;   (* 下一批从准备开始 *)
                END_IF;

            800: // CONDSEQ_DONE 完成
                HMI.Condition.Status.iStep   := 800;
                HMI.Condition.Status.bDone   := TRUE;
                HMI.Condition.Status.bRunning:= FALSE;
                HMI.Condition.Status.bMoving := FALSE;
                iPhase := COND_DONE;         (* 9：ModeManager 见 bDone 收口回 STANDBY *)

            900: // CONDSEQ_FAIL 异常收口
                HMI.Condition.Status.iStep   := 900;
                HMI.Condition.Status.bError  := TRUE;
                HMI.Condition.Status.bRunning:= FALSE;
                HMI.Condition.Status.bMoving := FALSE;
                iPhase := 0;
                (* Critical 锁存保持，ModeManager 见 Error.bActive 转 RESET/STOPPING *)

        END_CASE;

    (*===== 5 ST_SELFTEST：动态自检（P9） =====*)
    5:
        IF trBStateEntry THEN
            trIStepSt := 10;
        END_IF;

        CASE trIStepSt OF
            10: // ST_GATE 门禁断言（1301）
                (* 转换点：装全局快照/清脏标记；三轴已使能才准摆动，否则 1301 *)
                IF NOT (HMI.ChestImpact.Status.Servo.bEnabled
                    AND HMI.SeatTwist.Status.Servo.bEnabled
                    AND HMI.LegAngle.Status.Servo.bEnabled) THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_SELFTEST_ENTRY;
                    trILatSource := SRC_SELFTEST; trILatSub := 0;
                    trIStepSt := 200;
                ELSE
                    trDiStGlobalSnap  := diScanCount;
                    trBSelfTestSkipped:= FALSE;
                    trBDirtyAxis      := FALSE;
                    trBDirtyForce     := FALSE;
                    trBDirtyPusher    := FALSE;
                    trBDirtyParam     := FALSE;
                    trIStepSt         := 20;
                END_IF;

            20: // ST_WAIT_CONFIRM 等安全确认（可跳过/工程师强跳）
                IF trigSelfTestConfirm THEN
                    (* 转换点：进推杆参考检查；无参考则同扫发 bCalibrate 脉冲 *)
                    trDiPushSnap := diScanCount;
                    IF NOT HMI.TailTilt.Status.bReferenceValid THEN
                        HMI.TailTilt.Cmd.bCalibrate := TRUE;   (* 单扫脉冲 *)
                    END_IF;
                    trIStepSt := 30;
                ELSIF trigSelfTestSkip OR trigForceSkipST THEN
                    trBSelfTestSkipped := TRUE;
                    HMI.Sys.Status.bHealthCheckSkipped := TRUE;
                    trIStepSt := 100;   (* 跳过直接判完成 *)
                END_IF;

            30: // ST_PUSHER_CALIB 推杆参考检查 + 校准（1303，30s）
                IF HMI.TailTilt.Status.bReferenceValid THEN
                    (* 转换点：发推杆成角 AutoMove 到自检角，装快照转 40 *)
                    HMI.TailTilt.Motion.rTargetAngle := ST_ANGLE_DEG;
                    HMI.TailTilt.Cmd.bAutoMove := TRUE;
                    trDiPushSnap := diScanCount;
                    trIStepSt    := 40;
                ELSIF HMI.TailTilt.Status.bError THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_SELFTEST_PUSHER;
                    trILatSource := SRC_SELFTEST; trILatSub := HMI.TailTilt.Status.iErrorCode;
                    trIStepSt := 200;
                ELSIF (diScanCount - trDiPushSnap) >= ST_PUSHER_TOUT_SCAN THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_SELFTEST_PUSHER;
                    trILatSource := SRC_SELFTEST; trILatSub := 0;
                    trIStepSt := 200;
                END_IF;

            40: // ST_ANGLE 成角（推杆自动定位到自检角 ST_ANGLE_DEG）
                IF rDoneEdge.Q THEN
                    (* 转换点：初始化三轴摆动（轴1 相位0），装轴快照转 50 *)
                    trIStAxis  := 1;
                    trIStPhase := 0;
                    trDiStSnap := diScanCount;
                    trIStepSt  := 50;
                ELSIF HMI.TailTilt.Status.bError THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_SELFTEST_PUSHER;
                    trILatSource := SRC_SELFTEST; trILatSub := HMI.TailTilt.Status.iErrorCode;
                    trIStepSt := 200;
                ELSIF (diScanCount - trDiPushSnap) >= ST_PUSHER_TOUT_SCAN THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_SELFTEST_PUSHER;
                    trILatSource := SRC_SELFTEST; trILatSub := 0;
                    trIStepSt := 200;
                END_IF;

            50: // ST_AXIS_CYCLE 三轴 ±2° 单循环（1304，8s/轴；MoveRel 不查 retain）
                (* 相位握手 trIStPhase：偶数(0/2/4/6)=轴静止待发；奇数=运动中。
                   偶数相：静止则写参数发 MoveRel（单扫）→相位+1；
                   奇数相：见离开静止→相位+1（不落令）；见回静止→相位+1（回落偶数，
                   下扫发下一段）。由此保证"发令→离静止→回静止"才推进，杜绝叠令。
                   每轴 3 段相对位移：+2° / -4° / +2°（净回原位）。 *)
                IF trIStAxis = 1 THEN
                    IF (trIStPhase MOD 2) = 0 THEN
                        (* 待发：轴静止才发本段 MoveRel *)
                        IF HMI.ChestImpact.Status.Servo.bStandStill THEN
                            HMI.ChestImpact.Motion.rTargetVel := runAxis[1].rMaxVel * 0.5;
                            HMI.ChestImpact.Motion.rAcc       := runAxis[1].rMaxAcc;
                            HMI.ChestImpact.Motion.rDec       := runAxis[1].rMaxDec;
                            IF (trIStPhase = 0) OR (trIStPhase = 4) THEN
                                HMI.ChestImpact.Motion.rTargetPos := ST_SWING_DEG;
                            ELSE
                                HMI.ChestImpact.Motion.rTargetPos := -2.0 * ST_SWING_DEG;
                            END_IF;
                            HMI.ChestImpact.Cmd.bMoveRel := TRUE;   (* 单扫脉冲 *)
                            trDiStSnap  := diScanCount;
                            trIStPhase  := trIStPhase + 1;
                        END_IF;
                    ELSE
                        (* 运动中：离开静止→再等回静止，逐拍推进 *)
                        IF NOT HMI.ChestImpact.Status.Servo.bStandStill THEN
                            trIStPhase := trIStPhase + 1;
                        ELSIF trIStPhase >= 3 THEN
                            (* 已离过静止且现回静止（相位≥3 的奇数拍） *)
                            trIStPhase := trIStPhase + 1;
                        END_IF;
                    END_IF;
                    IF trIStPhase >= 6 THEN
                        trIStAxis  := 2;
                        trIStPhase := 0;
                    END_IF;
                    IF HMI.ChestImpact.Status.bError THEN
                        trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_SELFTEST_AXIS;
                        trILatSource := SRC_SELFTEST; trILatSub := AXIS_ID_CHEST;
                        trIStepSt := 200;
                    END_IF;

                ELSIF trIStAxis = 2 THEN
                    IF (trIStPhase MOD 2) = 0 THEN
                        IF HMI.SeatTwist.Status.Servo.bStandStill THEN
                            HMI.SeatTwist.Motion.rTargetVel := runAxis[2].rMaxVel * 0.5;
                            HMI.SeatTwist.Motion.rAcc       := runAxis[2].rMaxAcc;
                            HMI.SeatTwist.Motion.rDec       := runAxis[2].rMaxDec;
                            IF (trIStPhase = 0) OR (trIStPhase = 4) THEN
                                HMI.SeatTwist.Motion.rTargetPos := ST_SWING_DEG;
                            ELSE
                                HMI.SeatTwist.Motion.rTargetPos := -2.0 * ST_SWING_DEG;
                            END_IF;
                            HMI.SeatTwist.Cmd.bMoveRel := TRUE;
                            trDiStSnap  := diScanCount;
                            trIStPhase  := trIStPhase + 1;
                        END_IF;
                    ELSE
                        IF NOT HMI.SeatTwist.Status.Servo.bStandStill THEN
                            trIStPhase := trIStPhase + 1;
                        ELSIF trIStPhase >= 3 THEN
                            trIStPhase := trIStPhase + 1;
                        END_IF;
                    END_IF;
                    IF trIStPhase >= 6 THEN
                        trIStAxis  := 3;
                        trIStPhase := 0;
                    END_IF;
                    IF HMI.SeatTwist.Status.bError THEN
                        trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_SELFTEST_AXIS;
                        trILatSource := SRC_SELFTEST; trILatSub := AXIS_ID_SEAT;
                        trIStepSt := 200;
                    END_IF;

                ELSIF trIStAxis = 3 THEN
                    IF (trIStPhase MOD 2) = 0 THEN
                        IF HMI.LegAngle.Status.Servo.bStandStill THEN
                            HMI.LegAngle.Motion.rTargetVel := runAxis[3].rMaxVel * 0.5;
                            HMI.LegAngle.Motion.rAcc       := runAxis[3].rMaxAcc;
                            HMI.LegAngle.Motion.rDec       := runAxis[3].rMaxDec;
                            IF (trIStPhase = 0) OR (trIStPhase = 4) THEN
                                HMI.LegAngle.Motion.rTargetPos := ST_SWING_DEG;
                            ELSE
                                HMI.LegAngle.Motion.rTargetPos := -2.0 * ST_SWING_DEG;
                            END_IF;
                            HMI.LegAngle.Cmd.bMoveRel := TRUE;
                            trDiStSnap  := diScanCount;
                            trIStPhase  := trIStPhase + 1;
                        END_IF;
                    ELSE
                        IF NOT HMI.LegAngle.Status.Servo.bStandStill THEN
                            trIStPhase := trIStPhase + 1;
                        ELSIF trIStPhase >= 3 THEN
                            trIStPhase := trIStPhase + 1;
                        END_IF;
                    END_IF;
                    IF trIStPhase >= 6 THEN
                        (* 转换点：三轴摆动完成，发推杆回零 bHome，装快照转 60 *)
                        HMI.TailTilt.Cmd.bHome := TRUE;
                        trDiPushSnap := diScanCount;
                        trIStepSt    := 60;
                    END_IF;
                    IF HMI.LegAngle.Status.bError THEN
                        trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_SELFTEST_AXIS;
                        trILatSource := SRC_SELFTEST; trILatSub := AXIS_ID_LEG;
                        trIStepSt := 200;
                    END_IF;
                END_IF;
                (* 单轴单循环超时 800 扫 ≈ 8s *)
                IF (diScanCount - trDiStSnap) >= ST_AXIS_TOUT_SCAN THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_SELFTEST_AXIS;
                    trILatSource := SRC_SELFTEST; trILatSub := trIStAxis;
                    trIStepSt := 200;
                END_IF;

            60: // ST_ANGLE_RETURN 成角回零（推杆回零/回初始角）
                IF rDoneEdge.Q THEN
                    trIStepSt := 70;
                ELSIF HMI.TailTilt.Status.bError THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_SELFTEST_PUSHER;
                    trILatSource := SRC_SELFTEST; trILatSub := HMI.TailTilt.Status.iErrorCode;
                    trIStepSt := 200;
                ELSIF (diScanCount - trDiPushSnap) >= ST_PUSHER_TOUT_SCAN THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_SELFTEST_PUSHER;
                    trILatSource := SRC_SELFTEST; trILatSub := 0;
                    trIStepSt := 200;
                END_IF;

            70: // ST_DIRTY_CHECK 清/核四个脏标记（1305）
                trBDirtyAxis := HMI.ChestImpact.Status.bError
                             OR HMI.SeatTwist.Status.bError
                             OR HMI.LegAngle.Status.bError;
                trBDirtyForce := HMI.ChestImpact.Status.Force.bOverForceLatched
                              OR HMI.SeatTwist.Status.Force.bOverForceLatched
                              OR HMI.LegAngle.Status.Force.bOverForceLatched
                              OR bProtStop;
                trBDirtyPusher := HMI.TailTilt.Status.bError
                              OR (NOT HMI.TailTilt.Status.bHomeSensorHealthy);
                trBDirtyParam  := NOT bRunParamValid;
                IF trBDirtyAxis OR trBDirtyForce OR trBDirtyPusher OR trBDirtyParam THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_SELFTEST_DIRTY;
                    trILatSource := SRC_SELFTEST;
                    trILatSub := 0;
                    trIStepSt := 200;
                ELSE
                    trIStepSt := 100;
                END_IF;

            100: // ST_STEP_DONE 自检成功
                HMI.Sys.Status.bSelfTestDone := TRUE;
                IF trBSelfTestSkipped THEN
                    HMI.Sys.Status.bHealthCheckSkipped := TRUE;
                END_IF;
                iPhase := COND_DONE;   (* 9：ModeManager 见 bSelfTestDone 收口回 STANDBY *)

            200: // ST_STEP_FAIL 自检失败（Critical 已锁存，等复位）
                iPhase := 0;
                (* ModeManager 见 HMI.Sys.Error.bActive 转 RESET 收口 *)

        END_CASE;
        (* 自检全局超时 12000 扫 ≈ 120s（1302）；终态不计 *)
        IF (trIStepSt <> 100) AND (trIStepSt <> 200)
           AND ((diScanCount - trDiStGlobalSnap) >= ST_GLOBAL_TOUT_SCAN) THEN
            trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_SELFTEST_TIMEOUT;
            trILatSource := SRC_SELFTEST; trILatSub := 0;
            trIStepSt := 200;
        END_IF;

    (*===== 40 ST_HOMING：普通回零（P9，三轴 MoveAbs 回 rInitPos） =====*)
    40:
        IF trBStateEntry THEN
            trIStepHom := 4000;
        END_IF;

        CASE trIStepHom OF
            4000: // HOMSEQ_START 入口：装载目标/启动快照 + 参考前置判定
                (* 转换点：装载初始位/清完成标志/装快照。未建零（retain 无效）时
                   MoveAbs 会被 FB 以 2006 拒，故先判参考：无效直接 4002 失败。 *)
                trDiSnap := diScanCount;
                trRInit[1] := runAxis[1].rInitPos;
                trRInit[2] := runAxis[2].rInitPos;
                trRInit[3] := runAxis[3].rInitPos;
                trBAxisDone[1] := FALSE; trBAxisDone[2] := FALSE; trBAxisDone[3] := FALSE;
                IF NOT bAllAxesRef THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_HOME_REFUSE;
                    trILatSource := SRC_HOMING; trILatSub := 0;
                    trIStepHom := 4020;   (* 进 WAIT 由失败收口（不发运动） *)
                ELSE
                    trIStepHom := 4010;
                END_IF;

            4010: // HOMSEQ_MOVE 发 MoveAbs（并行模式全发；顺序模式首发轴1）
                IF runHoming.iHomingMode = HOM_MODE_PARALLEL THEN
                    (* 并行：三轴同扫各发 1 个 MoveAbs 脉冲，转 WAIT *)
                    HMI.ChestImpact.Motion.rTargetPos := trRInit[1];
                    HMI.ChestImpact.Motion.rTargetVel := runHoming.rChestJogVel;
                    HMI.ChestImpact.Cmd.bMoveAbs := TRUE;
                    HMI.SeatTwist.Motion.rTargetPos := trRInit[2];
                    HMI.SeatTwist.Motion.rTargetVel := runHoming.rSeatJogVel;
                    HMI.SeatTwist.Cmd.bMoveAbs := TRUE;
                    HMI.LegAngle.Motion.rTargetPos := trRInit[3];
                    HMI.LegAngle.Motion.rTargetVel := runHoming.rLegJogVel;
                    HMI.LegAngle.Cmd.bMoveAbs := TRUE;
                    trIAxis    := 4;   (* 并行无活动轴 *)
                    trIStepHom := 4020;
                ELSE
                    (* 顺序：首发轴1 Chest，转 WAIT 逐轴补发 *)
                    HMI.ChestImpact.Motion.rTargetPos := trRInit[1];
                    HMI.ChestImpact.Motion.rTargetVel := runHoming.rChestJogVel;
                    HMI.ChestImpact.Cmd.bMoveAbs := TRUE;
                    trIAxis    := 1;
                    trIStepHom := 4020;
                END_IF;

            4020: // HOMSEQ_WAIT 等待全轴到位（4001 超时 / 4003 轴失败）
                (* 顺序模式：活动轴到位静止后补发下一轴（转换点内联发脉冲） *)
                IF (runHoming.iHomingMode = HOM_MODE_SEQUENTIAL) AND (trIAxis = 1) THEN
                    IF HMI.ChestImpact.Status.bAtInit AND HMI.ChestImpact.Status.Servo.bStandStill THEN
                        trBAxisDone[1] := TRUE;
                        HMI.SeatTwist.Motion.rTargetPos := trRInit[2];
                        HMI.SeatTwist.Motion.rTargetVel := runHoming.rSeatJogVel;
                        HMI.SeatTwist.Cmd.bMoveAbs := TRUE;
                        trIAxis := 2;
                    END_IF;
                ELSIF (runHoming.iHomingMode = HOM_MODE_SEQUENTIAL) AND (trIAxis = 2) THEN
                    IF HMI.SeatTwist.Status.bAtInit AND HMI.SeatTwist.Status.Servo.bStandStill THEN
                        trBAxisDone[2] := TRUE;
                        HMI.LegAngle.Motion.rTargetPos := trRInit[3];
                        HMI.LegAngle.Motion.rTargetVel := runHoming.rLegJogVel;
                        HMI.LegAngle.Cmd.bMoveAbs := TRUE;
                        trIAxis := 3;
                    END_IF;
                ELSIF (runHoming.iHomingMode = HOM_MODE_SEQUENTIAL) AND (trIAxis = 3) THEN
                    IF HMI.LegAngle.Status.bAtInit AND HMI.LegAngle.Status.Servo.bStandStill THEN
                        trBAxisDone[3] := TRUE;
                        trIAxis := 4;
                    END_IF;
                END_IF;

                (* 轴失败：任一轴 bError（2005 超时/驱动故障），子码=故障轴号；
                   锁存 Critical 并停留本步（不进 DONE），ModeManager 见 Error 转 RESET。 *)
                IF HMI.ChestImpact.Status.bError AND NOT trBAxisDone[1] THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_HOME_AXIS;
                    trILatSource := SRC_HOMING; trILatSub := AXIS_ID_CHEST;
                    iPhase := 0;
                ELSIF HMI.SeatTwist.Status.bError AND NOT trBAxisDone[2] THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_HOME_AXIS;
                    trILatSource := SRC_HOMING; trILatSub := AXIS_ID_SEAT;
                    iPhase := 0;
                ELSIF HMI.LegAngle.Status.bError AND NOT trBAxisDone[3] THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_HOME_AXIS;
                    trILatSource := SRC_HOMING; trILatSub := AXIS_ID_LEG;
                    iPhase := 0;
                END_IF;

                (* 完成判定：全轴在初始位且静止（无活动故障时） *)
                IF bAllAxesAtInit AND bAllAxesIdle
                   AND NOT (HMI.ChestImpact.Status.bError
                         OR HMI.SeatTwist.Status.bError
                         OR HMI.LegAngle.Status.bError) THEN
                    trIStepHom := 4090;
                END_IF;

                (* 全流程超时 diHomingTimeout（ms）→ 4001（已完成则不计） *)
                IF (runHoming.diHomingTimeout > 0)
                   AND ((diScanCount - trDiSnap) * 10 >= runHoming.diHomingTimeout)
                   AND NOT (bAllAxesAtInit AND bAllAxesIdle) THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_HOME_TIMEOUT;
                    trILatSource := SRC_HOMING; trILatSub := 0;
                    iPhase := 0;
                END_IF;

            4090: // HOMSEQ_DONE 完成
                iPhase := COND_DONE;   (* 9：ModeManager 见 bAllAxesRef&AtInit&Idle 收口 *)

        END_CASE;

    (*===== 45 ST_CALIBRATE：维护建零（P9，6 重门控 + Retain 握手） =====*)
    45:
        IF trBStateEntry THEN
            trIStepCal := 5000;
        END_IF;

        CASE trIStepCal OF
            5000: // CAL_GATE 6 重门控断言
                (* 门控：工程师角色+权限码 / 授权确认电平 / 空载确认电平 /
                   全轴静止 / 非安全停车。任一不满足停留 5000（不报错，等操作）。
                   判据成立的同一扫内联发三轴建零+推杆标定脉冲并转 5020。 *)
                IF (HMI.Sys.Cmd.iUserRole = ROLE_ENGINEER)
                   AND (HMI.Sys.Cmd.iAuthCode = AUTH_CODE_ENGINEER)
                   AND bServiceAuthConfirm
                   AND bNoLoadConfirm
                   AND bAllAxesIdle
                   AND (NOT bSafetyStop) THEN
                    (* 三轴建零：HMI 脉冲单扫置位，环2 锁存 axisPulse[*,ZERO_COMM]，
                       FB 已使能则发 MC_Home；同时置 Retain 握手请求 bZeroCommSetReq，
                       环8 ParamService 消费写 retainZeroComm[i]。 *)
                    HMI.ChestImpact.Cmd.bZeroCommission := TRUE;
                    HMI.SeatTwist.Cmd.bZeroCommission   := TRUE;
                    HMI.LegAngle.Cmd.bZeroCommission    := TRUE;
                    bZeroCommSetReq[1] := TRUE;
                    bZeroCommSetReq[2] := TRUE;
                    bZeroCommSetReq[3] := TRUE;
                    (* 推杆标定（无参考时）：HMI 脉冲→trigPushCalibrate；
                       标定完成由环10 置 bPushCalibDoneLatch，环8 写 retainTailZeroComm *)
                    IF NOT HMI.TailTilt.Status.bReferenceValid THEN
                        HMI.TailTilt.Cmd.bCalibrate := TRUE;
                    END_IF;
                    trDiCalSnap := diScanCount;
                    trIStepCal  := 5020;
                END_IF;

            5020: // CAL_CONFIRM 等 Retain 握手回读
                (* 三轴建零回读：FB bZeroCommissioned（=retainZeroComm，环8 写入后生效）；
                   推杆：参考有效 / 标定完成锁存 / Retain 任一成立即可。 *)
                IF HMI.ChestImpact.Status.Servo.bZeroCommissioned
                   AND HMI.SeatTwist.Status.Servo.bZeroCommissioned
                   AND HMI.LegAngle.Status.Servo.bZeroCommissioned
                   AND (HMI.TailTilt.Status.bReferenceValid
                        OR bPushCalibDoneLatch
                        OR retainTailZeroComm) THEN
                    trIStepCal := 5090;
                END_IF;
                (* 推杆标定故障（沿用推杆错误码）；Critical 锁存等复位 *)
                IF HMI.TailTilt.Status.bError THEN
                    trBFaultLat := TRUE; trILatLevel := 2;
                    trILatCode := HMI.TailTilt.Status.iErrorCode;
                    trILatSource := SRC_PUSHER; trILatSub := 0;
                    iPhase := 0;
                END_IF;

            5090: // CAL_DONE 建零完成
                iPhase := COND_DONE;   (* 9：ModeManager 见参考有效收口回 STANDBY *)

        END_CASE;

    (*===== 50 ST_RESET：故障复位收口（清错/回初始位由 ModeManager/STOP 流程处理） =====*)
    50:
        iPhase := 0;
        (* 复位收口条件（NOT Error.bActive AND bAllAxesIdle）由 ModeManager 判定切 STANDBY；
           本态不发运动，避免与复位按钮/STOP 流程竞争。 *)

    (*===== 60 ST_STOPPING：停止安全降落（P10，三轴 STOP 后 MoveAbs 回初始位） =====*)
    60:
        IF trBStateEntry THEN
            trIStepStop := 6000;
            trDiSnap    := diScanCount;
        END_IF;

        CASE trIStepStop OF
            6000: // STOPSEQ_HALT 发三轴 STOP 脉冲至全轴静止
                (* bStop 为脉冲：未静止每扫置位（环2 锁存 axisPulse[*,STOP]，
                   FB 见 bStop 减速停车；持续置位确保中断缓冲运动）；
                   全轴静止的同一扫内联发回程 MoveAbs 脉冲并转 6010。 *)
                IF NOT bAllAxesIdle THEN
                    HMI.ChestImpact.Cmd.bStop := TRUE;
                    HMI.SeatTwist.Cmd.bStop   := TRUE;
                    HMI.LegAngle.Cmd.bStop    := TRUE;
                ELSE
                    HMI.ChestImpact.Motion.rTargetPos := runAxis[1].rInitPos;
                    HMI.ChestImpact.Motion.rTargetVel := runHoming.rChestJogVel;
                    HMI.SeatTwist.Motion.rTargetPos   := runAxis[2].rInitPos;
                    HMI.SeatTwist.Motion.rTargetVel   := runHoming.rSeatJogVel;
                    HMI.LegAngle.Motion.rTargetPos    := runAxis[3].rInitPos;
                    HMI.LegAngle.Motion.rTargetVel    := runHoming.rLegJogVel;
                    HMI.ChestImpact.Cmd.bMoveAbs := TRUE;
                    HMI.SeatTwist.Cmd.bMoveAbs   := TRUE;
                    HMI.LegAngle.Cmd.bMoveAbs    := TRUE;
                    trIStepStop := 6010;
                END_IF;

            6010: // STOPSEQ_RETURN 三轴并行 MoveAbs 回初始位
                ;   (* 到位后 ModeManager 见 bAllAxesIdle AND bAllAxesAtInit 自动回 STANDBY；
                       本环不切态、不置 iPhase。未建零(retain 无效)时 MoveAbs 被 2006 拒，
                       轴保持静止，ModeManager 仍按 bAllAxesIdle 收口（位置不可信需重新建零）。 *)

        END_CASE;

    (*===== 110 ST_SOFT_ESTOP：紧急回零（P9，Jog 回初始位 + 防夹，全内联无过程调用） =====*)
    110:
        IF trBStateEntry THEN
            trIStepEmh := 1100;
        END_IF;

        CASE trIStepEmh OF
            1100: // EMH_WAIT_RELEASE 等 MC_Stop 释放/停稳（1201 diStopReleaseTimeout）
                (* 转换点：装载三轴初始位/速度/接近区/迟滞、清重试与防夹，转 1110。
                   装载仅在进入状态首扫做一次（trBStateEntry 已复位子步到 1100）。 *)
                IF trBStateEntry THEN
                    trIEmhAxis    := 1;
                    trIRetry[1]   := 0; trIRetry[2]   := 0; trIRetry[3]   := 0;
                    trBEmhPinch   := FALSE;
                    trDiSnap      := diScanCount;   (* 释放超时基准，防陈旧快照误触发 *)
                    trRInit[1]    := runAxis[1].rInitPos;
                    trRInit[2]    := runAxis[2].rInitPos;
                    trRInit[3]    := runAxis[3].rInitPos;
                    trRJogV[1]    := runHoming.rChestJogVel;
                    trRJogV[2]    := runHoming.rSeatJogVel;
                    trRJogV[3]    := runHoming.rLegJogVel;
                    trRCrawlV[1]  := runHoming.rChestCrawlVel;
                    trRCrawlV[2]  := runHoming.rSeatCrawlVel;
                    trRCrawlV[3]  := runHoming.rLegCrawlVel;
                    trRApproach[1]:= runHoming.rChestApproachZone;
                    trRApproach[2]:= runHoming.rSeatApproachZone;
                    trRApproach[3]:= runHoming.rLegApproachZone;
                    trRHyst[1]    := runHoming.rChestHysteresis;
                    trRHyst[2]    := runHoming.rSeatHysteresis;
                    trRHyst[3]    := runHoming.rLegHysteresis;
                END_IF;
                (* 等软急停减速电平释放（SafetyManager 停稳滑行后自动清 smBSoftStopActive，
                   使 bSafetyStop 软急停成分变 FALSE）；FB 此时才接受 Jog。 *)
                IF NOT bSafetyStop THEN
                    trDiSnap    := diScanCount;
                    trIStepEmh  := 1110;
                ELSIF (runHoming.diStopReleaseTimeout > 0)
                      AND ((diScanCount - trDiSnap) * 10 >= runHoming.diStopReleaseTimeout) THEN
                    trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_EMGHOME_RELEASE;
                    trILatSource := SRC_HOMING; trILatSub := 0;
                    (* 释放超时：停留 1100 等用户 trigSysReset，不自动 Jog *)
                END_IF;

            1110: // EMH_JOG_MAIN 主速/爬行 Jog 回初始位（迟滞到位判停 + 防夹）
                IF trIEmhAxis > 3 THEN
                    trIStepEmh := 1190;
                ELSIF (trBFaultLat AND (trILatLevel = 2))
                   OR ((runHoming.diEmergencyTimeout > 0)
                       AND ((diScanCount - trDiSnap) * 10 >= runHoming.diEmergencyTimeout)
                       AND (trIEmhAxis <= 3)) THEN
                    (* Critical 已锁存（前轮遗留）或本扫单轴超时已到：不进 Jog 驱动，
                       三轴撤力；超时锁存由下方超时块同扫置位上报，等 ModeManager
                       见 Critical 转 RESET（1190 亦撤力，安全） *)
                    HMI.ChestImpact.Cmd.bJogPos := FALSE;
                    HMI.ChestImpact.Cmd.bJogNeg := FALSE;
                    HMI.SeatTwist.Cmd.bJogPos   := FALSE;
                    HMI.SeatTwist.Cmd.bJogNeg   := FALSE;
                    HMI.LegAngle.Cmd.bJogPos    := FALSE;
                    HMI.LegAngle.Cmd.bJogNeg    := FALSE;
                ELSE
                    IF trIEmhAxis = 1 THEN
                        (* 到位（迟滞窗口内）：撤力，下一轴 *)
                        IF ABS(HMI.ChestImpact.Status.Servo.rActPosition - trRInit[1]) <= trRHyst[1] THEN
                            HMI.ChestImpact.Cmd.bJogPos := FALSE;
                            HMI.ChestImpact.Cmd.bJogNeg := FALSE;
                            trIEmhAxis := 2;
                            trDiSnap   := diScanCount;
                        ELSIF HMI.ChestImpact.Status.Force.rNetTorquePct > runHoming.rAntiPinchTorqueLimit THEN
                            (* 防夹：净扭矩超阈→撤力进 PINCH_WAIT（基线无效净力为 0 不触发） *)
                            HMI.ChestImpact.Cmd.bJogPos := FALSE;
                            HMI.ChestImpact.Cmd.bJogNeg := FALSE;
                            trBEmhPinch  := TRUE;
                            trDiPinchSnap:= diScanCount;
                            trIStepEmh   := 1140;
                        ELSIF HMI.ChestImpact.Status.bError THEN
                            HMI.ChestImpact.Cmd.bJogPos := FALSE;
                            HMI.ChestImpact.Cmd.bJogNeg := FALSE;
                            trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_HOME_AXIS;
                            trILatSource := SRC_HOMING; trILatSub := AXIS_ID_CHEST;
                        ELSE
                            (* 方向：rActPos<rInit 需增→JogPos；> 需减→JogNeg。
                               接近区内用爬行速，区外用主速。电平每扫持续写。 *)
                            IF ABS(HMI.ChestImpact.Status.Servo.rActPosition - trRInit[1]) <= trRApproach[1] THEN
                                HMI.ChestImpact.Motion.rJogVel := trRCrawlV[1];
                            ELSE
                                HMI.ChestImpact.Motion.rJogVel := trRJogV[1];
                            END_IF;
                            IF HMI.ChestImpact.Status.Servo.rActPosition < trRInit[1] THEN
                                HMI.ChestImpact.Cmd.bJogPos := TRUE;
                                HMI.ChestImpact.Cmd.bJogNeg := FALSE;
                            ELSE
                                HMI.ChestImpact.Cmd.bJogPos := FALSE;
                                HMI.ChestImpact.Cmd.bJogNeg := TRUE;
                            END_IF;
                        END_IF;

                    ELSIF trIEmhAxis = 2 THEN
                        IF ABS(HMI.SeatTwist.Status.Servo.rActPosition - trRInit[2]) <= trRHyst[2] THEN
                            HMI.SeatTwist.Cmd.bJogPos := FALSE;
                            HMI.SeatTwist.Cmd.bJogNeg := FALSE;
                            trIEmhAxis := 3;
                            trDiSnap   := diScanCount;
                        ELSIF HMI.SeatTwist.Status.Force.rNetTorquePct > runHoming.rAntiPinchTorqueLimit THEN
                            HMI.SeatTwist.Cmd.bJogPos := FALSE;
                            HMI.SeatTwist.Cmd.bJogNeg := FALSE;
                            trBEmhPinch  := TRUE;
                            trDiPinchSnap:= diScanCount;
                            trIStepEmh   := 1140;
                        ELSIF HMI.SeatTwist.Status.bError THEN
                            HMI.SeatTwist.Cmd.bJogPos := FALSE;
                            HMI.SeatTwist.Cmd.bJogNeg := FALSE;
                            trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_HOME_AXIS;
                            trILatSource := SRC_HOMING; trILatSub := AXIS_ID_SEAT;
                        ELSE
                            IF ABS(HMI.SeatTwist.Status.Servo.rActPosition - trRInit[2]) <= trRApproach[2] THEN
                                HMI.SeatTwist.Motion.rJogVel := trRCrawlV[2];
                            ELSE
                                HMI.SeatTwist.Motion.rJogVel := trRJogV[2];
                            END_IF;
                            IF HMI.SeatTwist.Status.Servo.rActPosition < trRInit[2] THEN
                                HMI.SeatTwist.Cmd.bJogPos := TRUE;
                                HMI.SeatTwist.Cmd.bJogNeg := FALSE;
                            ELSE
                                HMI.SeatTwist.Cmd.bJogPos := FALSE;
                                HMI.SeatTwist.Cmd.bJogNeg := TRUE;
                            END_IF;
                        END_IF;

                    ELSIF trIEmhAxis = 3 THEN
                        IF ABS(HMI.LegAngle.Status.Servo.rActPosition - trRInit[3]) <= trRHyst[3] THEN
                            HMI.LegAngle.Cmd.bJogPos := FALSE;
                            HMI.LegAngle.Cmd.bJogNeg := FALSE;
                            trIEmhAxis := 4;
                            trDiSnap   := diScanCount;
                        ELSIF HMI.LegAngle.Status.Force.rNetTorquePct > runHoming.rAntiPinchTorqueLimit THEN
                            HMI.LegAngle.Cmd.bJogPos := FALSE;
                            HMI.LegAngle.Cmd.bJogNeg := FALSE;
                            trBEmhPinch  := TRUE;
                            trDiPinchSnap:= diScanCount;
                            trIStepEmh   := 1140;
                        ELSIF HMI.LegAngle.Status.bError THEN
                            HMI.LegAngle.Cmd.bJogPos := FALSE;
                            HMI.LegAngle.Cmd.bJogNeg := FALSE;
                            trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_HOME_AXIS;
                            trILatSource := SRC_HOMING; trILatSub := AXIS_ID_LEG;
                        ELSE
                            IF ABS(HMI.LegAngle.Status.Servo.rActPosition - trRInit[3]) <= trRApproach[3] THEN
                                HMI.LegAngle.Motion.rJogVel := trRCrawlV[3];
                            ELSE
                                HMI.LegAngle.Motion.rJogVel := trRJogV[3];
                            END_IF;
                            IF HMI.LegAngle.Status.Servo.rActPosition < trRInit[3] THEN
                                HMI.LegAngle.Cmd.bJogPos := TRUE;
                                HMI.LegAngle.Cmd.bJogNeg := FALSE;
                            ELSE
                                HMI.LegAngle.Cmd.bJogPos := FALSE;
                                HMI.LegAngle.Cmd.bJogNeg := TRUE;
                            END_IF;
                        END_IF;
                    END_IF;

                    (* 单轴紧急回零超时 diEmergencyTimeout（ms）→ 1203 兜底（撤力停留等复位） *)
                    IF (runHoming.diEmergencyTimeout > 0)
                       AND ((diScanCount - trDiSnap) * 10 >= runHoming.diEmergencyTimeout)
                       AND (trIEmhAxis <= 3) THEN
                        IF trIEmhAxis = 1 THEN
                            HMI.ChestImpact.Cmd.bJogPos := FALSE;
                            HMI.ChestImpact.Cmd.bJogNeg := FALSE;
                        ELSIF trIEmhAxis = 2 THEN
                            HMI.SeatTwist.Cmd.bJogPos := FALSE;
                            HMI.SeatTwist.Cmd.bJogNeg := FALSE;
                        ELSE
                            HMI.LegAngle.Cmd.bJogPos := FALSE;
                            HMI.LegAngle.Cmd.bJogNeg := FALSE;
                        END_IF;
                        trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_EMGHOME_RETRY;
                        trILatSource := SRC_HOMING; trILatSub := trIEmhAxis;
                    END_IF;
                END_IF;

            1140: // EMH_PINCH_WAIT 防夹触发后撤力等待（1202，重试计数）
                (* 撤力等待 500ms（50 扫）后重试；重试超 iMaxRetry → 1203 Critical 中止。
                   等待期间三轴 Jog 电平均撤（防夹轴已在 1110 撤，余轴本就未驱动）。 *)
                HMI.ChestImpact.Cmd.bJogPos := FALSE;
                HMI.ChestImpact.Cmd.bJogNeg := FALSE;
                HMI.SeatTwist.Cmd.bJogPos   := FALSE;
                HMI.SeatTwist.Cmd.bJogNeg   := FALSE;
                HMI.LegAngle.Cmd.bJogPos    := FALSE;
                HMI.LegAngle.Cmd.bJogNeg    := FALSE;
                IF (diScanCount - trDiPinchSnap) >= 50 THEN
                    trIRetry[trIEmhAxis] := trIRetry[trIEmhAxis] + 1;
                    IF trIRetry[trIEmhAxis] > runHoming.iMaxRetry THEN
                        trBFaultLat := TRUE; trILatLevel := 2; trILatCode := ERR_EMGHOME_RETRY;
                        trILatSource := SRC_HOMING; trILatSub := trIEmhAxis;
                        (* 中止：停留 1140 等用户 trigSysReset *)
                    ELSE
                        (* 防夹事件 Warning（1202，每次触发上报，送出即释放） *)
                        trBFaultLat := TRUE; trILatLevel := 1; trILatCode := ERR_EMGHOME_TORQUE;
                        trILatSource := SRC_HOMING; trILatSub := trIEmhAxis;
                        trBEmhPinch := FALSE;
                        trDiSnap    := diScanCount;
                        trIStepEmh  := 1110;
                    END_IF;
                END_IF;

            1190: // EMH_DONE 紧急回零完成（停车电平保持，等 trigSysReset）
                HMI.ChestImpact.Cmd.bJogPos := FALSE;
                HMI.ChestImpact.Cmd.bJogNeg := FALSE;
                HMI.SeatTwist.Cmd.bJogPos   := FALSE;
                HMI.SeatTwist.Cmd.bJogNeg   := FALSE;
                HMI.LegAngle.Cmd.bJogPos    := FALSE;
                HMI.LegAngle.Cmd.bJogNeg    := FALSE;
                (* 不切态：ModeManager 态110 收口条件 (NOT bSafetyStop) AND trigSysReset → RESET。
                   回零完成后全轴在初始位静止，等用户复位。 *)

        END_CASE;

    (*===== 120 ST_HARD_ESTOP：硬急停断使能，任务层不动作（等物理链恢复+复位） =====*)
    120:
        ;

ELSE
    (* 0 INIT / 3 READY_CHECK / 30 SERVICE / 15 SERVICE_REQUIRED / 998 PARAM_LIMITED：任务层空闲 *)
    ;
END_CASE;

END_PROGRAM
