(*============================================================================
  FB_AxisControl —— 单轴伺服控制（M900，EtherCAT / CiA402），三轴各实例化一个
  ----------------------------------------------------------------------------
  平台事实（汇川 H5U / InoProShop，旧工程变量表导出佐证）：
    EtherCAT 轴引用 AXIS_REF（底层 _sMCAXIS_INFO）为结构体，直接写字段即下发命令：
      bPowerOn 使能 | bReset 复位 | bStop 停止 | bHome 原点回归 | bSetPos 设当前位
      bJogP/bJogN 点动± | bAbsPos 绝对定位 | bRelPos 相对定位 | bRevPos 往复
      fJogVelocity 点动速度 | fTarPosition1/fTarVelocity1/fTarAcceleration1/
      fTarDecelaration1/wCurveType1 目标位置/速度/加减速/曲线
    直接读字段取状态：
      bPowerState 已使能 | bMotionState 运动中 | bphlimit/bnhlimit 硬件±限位
      bpslimit/bnslimit 软件±限位 | bhomestate 原点开关 | wPLCOpenState PLCopen 状态
      fActPosition/fActVelocity/fActTorque 实际位置/速度/力矩
      wServoError 驱动器故障 | wAxisError 轴故障 | fFollowPos 跟随误差
  职责（P7）：
    - 运动状态机：IDLE/ENABLING/READY/JOG/MOVE/BUFFER/ERROR；
    - 点动（电平，限位方向禁动）、绝对/相对定位（脉冲触发，软限位校验）、
      16 段缓冲（MoveBuffer，逐段绝对定位，P10 调理联动用）；
    - 到位/在初始位/静止判定；步骤超时（2005）；驱动器故障（2001，子码=Er.xxx）；
      未使能/未参考定位拒绝（2006）；软限位拒绝（2004）；
    - 力估算：静止扭矩基线学习、净扭矩、牵引力 N（低通）、超力实时态/锁存
      （锁存供 SAFETY 保护停机，事件 1206 由 SAFETY_MANAGER 统一提交，本 FB 不报）。
  单写源：本 FB 仅在 PRG_OutputAdapter（扫描链第 10 环）内实例化调用，
          是轴命令字段与轴 Status 镜像的唯一写入点。
  时间基准：扫描周期按 10ms 计（任务组态确认后统一修正），超时/持续用 diScanCount 推算。
  ----------------------------------------------------------------------------
  变量表导入说明（汇川 InoProShop）：
  接口表 FB_AxisControl_new.csv 已含全部 66 个引脚（含 Axis / stStatus），文件编码必须为
  UTF-16 LE + BOM（汇川原生导出格式；UTF-8 会导入失败），可直接导入、无需手动新建引脚。
  结构体/轴引用引脚均按单行写法（不展开子字段），已验证可正常导入。导入后仅需：
    ① Axis : AXIS_REF（VAR_INPUT）—— 引脚随 CSV 自动创建；在【实例化调用处】把本输入
       绑定到轴组态对应轴：Axis_胸背 / Axis_臀盘 / Axis_臀腿。
    ② stStatus : Stru_AxisStatus（VAR_OUTPUT）—— 自定义结构体（UDT），导入前须先把类型
       定义加入工程（src\00_Globals\ST_StruHMI.st：Stru_AxisStatus L479，成员
       Servo:Stru_ServoAxisStatus L429 / Force:Stru_AxisForceStatus L461）。
==========================================================================*)
FUNCTION_BLOCK FB_AxisControl
VAR_INPUT
    (* 轴引用引脚：随 FB_AxisControl_new.csv（UTF-16 LE）导入自动创建，无需手动新建；
       实例化调用时把本输入绑定到轴组态对应轴：Axis_胸背/臀盘/臀腿（底层 _sMCAXIS_INFO） *)
    Axis            : AXIS_REF;         (* EtherCAT 轴引用（Axis_胸背/臀盘/臀腿） *)
    iAxisId         : INT;              (* 轴编号（AXIS_ID_CHEST/SEAT/LEG，故障定位） *)
    bEnable         : BOOL;             (* 使能电平（源：POWER 分时上电 axisPowerEnable） *)
    bReset          : BOOL;             (* 复位轴错误（脉冲） *)
    bZeroComm       : BOOL;             (* 原点标定（脉冲，仅工厂建零，MC_Home） *)
    bStop           : BOOL;             (* 立即减速停车（电平，含安全链） *)
    bMoveAbs        : BOOL;             (* 绝对定位（脉冲） *)
    bMoveRel        : BOOL;             (* 相对定位（脉冲） *)
    bJogPos         : BOOL;             (* 正向点动（电平） *)
    bJogNeg         : BOOL;             (* 负向点动（电平） *)
    bMoveBuffer     : BOOL;             (* 16 段缓冲启动（脉冲，P10 联动） *)
    arSegPos        : REAL[16];         (* 缓冲段目标位置表 *)
    arSegVel        : REAL[16];         (* 缓冲段目标速度表 *)
    iSegCount       : INT;              (* 缓冲段数（1..16） *)
    rTargetPos      : REAL;             (* 单段目标位置 *)
    rTargetVel      : REAL;             (* 单段目标速度 *)
    rJogVel         : REAL;             (* 点动速度 *)
    rAcc            : REAL;             (* 加速度 *)
    rDec            : REAL;             (* 减速度 *)
    rInitPos        : REAL;             (* 初始位置（bAtInit 判定基准） *)
    rPosLimit       : REAL;             (* 正软限位 *)
    rNegLimit       : REAL;             (* 负软限位 *)
    rTolerance      : REAL;             (* 到位/在初始位容差 *)
    diTimeout       : DINT;             (* 单段定位超时 (ms) *)
    bSafetyStop     : BOOL;             (* 安全链停车（硬/软急停/保护停机/硬限位） *)
    bZeroCommRetain : BOOL;             (* 建零标志镜像（retainZeroComm[i]，P9 写） *)
    bLearnBias      : BOOL;             (* 学习静止扭矩基线（脉冲） *)
    rForceScaleN    : REAL;             (* 净扭矩%→牵引力 N 换算系数（台架标定） *)
    rOverForceN     : REAL;             (* 超力阈值 (N，低通后) *)
END_VAR
VAR_OUTPUT
    (* 结构体引脚：随 FB_AxisControl_new.csv（UTF-16 LE）导入自动创建，无需手动新建；
       导入前须先把类型 Stru_AxisStatus 加入工程（ST_StruHMI.st L479，
       成员 Servo:Stru_ServoAxisStatus L429 / Force:Stru_AxisForceStatus L461） *)
    stStatus        : Stru_AxisStatus;  (* 轴状态全量镜像（→ HMI.<Axis>.Status） *)
    bFaultEvent     : BOOL;             (* 本扫新故障事件脉冲（→ OUTPUT_ADAPTER 序列化提交） *)
    iFaultCode      : INT;              (* 故障码（2xxx） *)
    iFaultLevel     : INT;              (* 级别 1=Warning 2=Critical *)
    iFaultSub       : INT;              (* 子码（驱动器 Er.xxx） *)
END_VAR
VAR
    iStep           : INT;              (* 运动状态机 AXST_* *)
    iBufSeg         : INT;              (* 缓冲当前段游标（base 0：0..iSegCount-1） *)
    bMoving         : BOOL;             (* 定位/缓冲进行中 *)
    bJogActive      : BOOL;             (* 点动进行中 *)
    rLastTarget     : REAL;             (* 本段目标位置（到位判定） *)
    diMoveSnap      : DINT;             (* 本段启动扫描计数（超时判定，跨段每段重置） *)
    diMoveStartSnap : DINT;             (* 本次离散定位整体启动扫描计数（用时锁存，跨段不重置） *)
    diMoveTimeLatch : DINT;             (* 最近一次离散定位完成用时 (ms)，完成时锁存 *)
    diOverCnt       : DINT;             (* 超力持续扫描计数（×10ms） *)
    rBiasP          : REAL;             (* 正侧静止基线 (%) *)
    rBiasN          : REAL;             (* 负侧静止基线 (%) *)
    bBiasPValid     : BOOL;
    bBiasNValid     : BOOL;
    rFiltN          : REAL;             (* 牵引力低通值 (N) *)
    bDrvErrPrev     : BOOL;             (* 驱动器故障锁存（事件边沿用） *)
    bEncFltMatch    : BOOL;             (* 本扫驱动器码命中编码器反馈类报警（联调填码） *)
    bEncFltLatch    : BOOL;             (* 编码器故障锁存（bReset 清除，绝对位置不可信） *)
    bOverLatch      : BOOL;             (* 超力锁存（bReset 清除） *)
    bToutReported   : BOOL;             (* 本段超时已报（防重复） *)
    rActPos         : REAL;
    rActVel         : REAL;
    rActTorque      : REAL;
    bPowerState     : BOOL;
    bMotionState    : BOOL;
    bDrvErr         : BOOL;
    iDrvCode        : INT;
    bStandStill     : BOOL;
    bAtInit         : BOOL;
    bInPosition     : BOOL;
    rNetPct         : REAL;
    rForceRawN      : REAL;
    bOverForce      : BOOL;
    bSwRej          : BOOL;             (* 本扫软限位/非法拒绝事件 *)
    iRejCode        : INT;
    bTimeoutEv      : BOOL;             (* 本扫超时事件 *)
    iTimeoutCode    : INT;
END_VAR

(*------------------------------------------------------------
  1) 驱动器状态采集（每扫直读轴字段）
------------------------------------------------------------*)
rActPos      := Axis.fActPosition;
rActVel      := Axis.fActVelocity;
rActTorque   := Axis.fActTorque;
bPowerState  := Axis.bPowerState;
bMotionState := Axis.bMotionState;
iDrvCode     := Axis.wServoError;
IF (Axis.wServoError <> 0) OR (Axis.wAxisError <> 0) THEN
    bDrvErr := TRUE;
    IF Axis.wServoError <> 0 THEN
        iDrvCode := Axis.wServoError;
    ELSE
        iDrvCode := Axis.wAxisError;
    END_IF;
ELSE
    bDrvErr := FALSE;
END_IF;

(* 1.1 编码器反馈故障：iDrvCode 命中 M900 编码器/反馈类报警码即视为绝对位置不可信。
       → 置 stStatus.Servo.bEncoderFault，下游 SAFETY 保护停机并报 ERR_AXIS_ENCODER(2002)。
       TODO 联调：M900(CiA402/EtherCAT) 编码器反馈类报警 Er.xxx 确切码表需依驱动器手册
                  及台架实测填入下面判定（文档仅有的 Er.101/201/234 为 SV630 举例，不可套用）。
                  填码前默认不命中（bEncFltMatch:=FALSE），编码器故障链保持断开、不误保护。 *)
bEncFltMatch := FALSE;
(* 联调填码示例（待手册/台架确认后启用，并保留有效码）：
   bEncFltMatch := bDrvErr AND ( (iDrvCode = ErXXX) OR (iDrvCode = ErYYY) ... );
   （编码器断线/多圈电池掉电/反馈计数异常等均属此列；命中后绝对位置不可信，禁定位） *)

(* 锁存：命中即置位保持；复位脉冲且驱动器故障已消时清除（与 bToutReported 同步复位） *)
IF bEncFltMatch THEN
    bEncFltLatch := TRUE;
END_IF;

(* 静止：已使能且非运动态（速度窗由驱动器 bMotionState 保证） *)
bStandStill := bPowerState AND NOT bMotionState;
bAtInit     := bPowerState AND (ABS(rActPos - rInitPos) <= rTolerance);

(*------------------------------------------------------------
  2) 默认输出与事件清零（每扫先清零，按条件再置位）
------------------------------------------------------------*)
bFaultEvent  := FALSE;
iFaultCode   := 0;
iFaultLevel  := 0;
iFaultSub    := 0;
bSwRej       := FALSE;
iRejCode     := 0;
bTimeoutEv   := FALSE;
iTimeoutCode := 0;

Axis.bPowerOn := bEnable;          (* 使能电平直写（POWER 已按急停/时序裁决） *)
Axis.bJogP    := FALSE;
Axis.bJogN    := FALSE;
Axis.bAbsPos  := FALSE;
Axis.bRelPos  := FALSE;
Axis.bStop    := FALSE;
Axis.bReset   := bReset;           (* 复位脉冲直透（驱动器清错） *)
Axis.bHome    := FALSE;

(*------------------------------------------------------------
  3) 故障/复位处理
------------------------------------------------------------*)
(* 3.1 驱动器故障上升沿 → 2001 Critical，子码=驱动器 Er.xxx *)
IF bDrvErr AND NOT bDrvErrPrev THEN
    bFaultEvent := TRUE;
    iFaultCode  := ERR_AXIS_DRIVE;
    iFaultLevel := 2;
    iFaultSub   := iDrvCode;
END_IF;
bDrvErrPrev := bDrvErr;

(* 3.2 复位脉冲且驱动器故障已消 → 清锁存 *)
IF bReset AND NOT bDrvErr THEN
    bOverLatch    := FALSE;
    bToutReported := FALSE;
    bEncFltLatch  := FALSE;
    IF iStep = AXST_ERROR THEN
        iStep := AXST_READY;
    END_IF;
END_IF;

IF bDrvErr THEN
    iStep := AXST_ERROR;
END_IF;

(*------------------------------------------------------------
  4) 力估算（每扫）
------------------------------------------------------------*)
(* 4.1 基线学习：静止时收到学习脉冲，记录当前力矩为正/负侧基线 *)
IF bLearnBias AND bStandStill THEN
    rBiasP      := rActTorque;
    rBiasN      := rActTorque;
    bBiasPValid := TRUE;
    bBiasNValid := TRUE;
END_IF;

(* 4.2 净扭矩：按运动方向选侧基线；静止未学基线时净力按 0 *)
IF bMotionState THEN
    IF rActVel >= 0 THEN
        IF bBiasPValid THEN
            rNetPct := rActTorque - rBiasP;
        ELSE
            rNetPct := 0.0;
        END_IF;
    ELSE
        IF bBiasNValid THEN
            rNetPct := rActTorque - rBiasN;
        ELSE
            rNetPct := 0.0;
        END_IF;
    END_IF;
ELSE
    rNetPct := 0.0;
END_IF;
rForceRawN := ABS(rNetPct) * rForceScaleN;

(* 4.3 一阶低通（系数 FORCE_LPF_ALPHA，台架可标） *)
rFiltN := rFiltN + (rForceRawN - rFiltN) * FORCE_LPF_ALPHA;

(* 4.4 超力：运动中低通值超阈持续 OVERFORCE_SCAN 扫（≈500ms@10ms）→ 锁存 *)
bOverForce := bMotionState AND bBiasPValid AND (rFiltN > rOverForceN);
IF bOverForce THEN
    diOverCnt := diOverCnt + 1;
    IF diOverCnt >= OVERFORCE_SCAN THEN
        bOverLatch := TRUE;
    END_IF;
ELSE
    diOverCnt := 0;
END_IF;

(*------------------------------------------------------------
  5) 运动状态机（无驱动器故障时才接受运动命令）
------------------------------------------------------------*)
IF NOT bDrvErr THEN
    (* 5.1 使能态迁移 *)
    IF NOT bPowerState THEN
        IF bEnable THEN
            iStep := AXST_ENABLING;
        ELSE
            iStep := AXST_IDLE;
            bMoving    := FALSE;
            bJogActive := FALSE;
        END_IF;
    ELSIF iStep <> AXST_MOVE AND iStep <> AXST_BUFFER AND iStep <> AXST_JOG THEN
        iStep := AXST_READY;
    END_IF;

    (* 5.2 原点标定（工厂建零）：已使能才发 MC_Home，其余门控在 P9 任务层 *)
    IF bZeroComm AND bPowerState THEN
        Axis.bHome := TRUE;
    END_IF;

    (* 5.3 停车（安全链/停止命令）：撤掉所有运动命令，发 bStop 脉冲 *)
    IF bStop OR bSafetyStop THEN
        Axis.bStop    := TRUE;
        Axis.bJogP    := FALSE;
        Axis.bJogN    := FALSE;
        bMoving       := FALSE;
        bJogActive    := FALSE;
        iStep         := AXST_READY;
        bToutReported := TRUE;   (* 中断的段不再报超时 *)
    ELSIF bPowerState THEN
        (* 5.4 点动（电平）：限位方向禁动（防冲出软限位） *)
        IF bJogPos AND (rActPos < rPosLimit) AND NOT bMoving THEN
            Axis.bJogP       := TRUE;
            Axis.fJogVelocity:= rJogVel;
            bJogActive       := TRUE;
            iStep            := AXST_JOG;
        ELSIF bJogNeg AND (rActPos > rNegLimit) AND NOT bMoving THEN
            Axis.bJogN       := TRUE;
            Axis.fJogVelocity:= rJogVel;
            bJogActive       := TRUE;
            iStep            := AXST_JOG;
        END_IF;
        IF bJogActive AND NOT bJogPos AND NOT bJogNeg THEN
            bJogActive := FALSE;
            IF NOT bMoving THEN
                iStep := AXST_READY;
            END_IF;
        END_IF;

        (* 5.5 绝对/相对/缓冲启动（静止态才接受新段任务） *)
        IF NOT bMoving AND NOT bJogActive THEN
            IF bMoveBuffer AND (iSegCount >= 1) THEN
                (* 缓冲需参考有效（已建零），否则 2006 拒绝 *)
                IF NOT bZeroCommRetain THEN
                    bSwRej := TRUE; iRejCode := ERR_AXIS_CMD_ILLEGAL;
                ELSE
                    (* 首段立即下发绝对定位命令（段游标 base 0：0=首段） *)
                    iBufSeg                := 0;
                    Axis.fTarPosition1     := arSegPos[0];
                    Axis.fTarVelocity1     := arSegVel[0];
                    Axis.fTarAcceleration1 := rAcc;
                    Axis.fTarDecelaration1 := rDec;
                    Axis.wCurveType1       := 0;
                    Axis.bAbsPos           := TRUE;
                    rLastTarget            := arSegPos[0];
                    diMoveSnap             := diScanCount;
                    diMoveStartSnap        := diScanCount;
                    diMoveTimeLatch        := 0;
                    bMoving                := TRUE;
                    bToutReported          := FALSE;
                    iStep                  := AXST_BUFFER;
                END_IF;
            ELSIF bMoveAbs THEN
                IF NOT bZeroCommRetain THEN
                    bSwRej := TRUE; iRejCode := ERR_AXIS_CMD_ILLEGAL;     (* 未建零禁绝对定位 *)
                ELSIF (rTargetPos > rPosLimit) OR (rTargetPos < rNegLimit) THEN
                    bSwRej := TRUE; iRejCode := ERR_AXIS_SWLIMIT;        (* 越软限位拒绝 *)
                ELSE
                    Axis.fTarPosition1    := rTargetPos;
                    Axis.fTarVelocity1    := rTargetVel;
                    Axis.fTarAcceleration1:= rAcc;
                    Axis.fTarDecelaration1:= rDec;
                    Axis.wCurveType1      := 0;
                    Axis.bAbsPos          := TRUE;
                    rLastTarget           := rTargetPos;
                    diMoveSnap            := diScanCount;
                    diMoveStartSnap       := diScanCount;
                    diMoveTimeLatch       := 0;
                    bMoving               := TRUE;
                    bToutReported        := FALSE;
                    iStep                 := AXST_MOVE;
                END_IF;
            ELSIF bMoveRel THEN
                (* 相对定位：增量运动，仍受软限位约束（目标落点校验） *)
                IF (rActPos + rTargetPos > rPosLimit) OR (rActPos + rTargetPos < rNegLimit) THEN
                    bSwRej := TRUE; iRejCode := ERR_AXIS_SWLIMIT;
                ELSE
                    Axis.fTarPosition1    := rTargetPos;
                    Axis.fTarVelocity1    := rTargetVel;
                    Axis.fTarAcceleration1:= rAcc;
                    Axis.fTarDecelaration1:= rDec;
                    Axis.wCurveType1      := 0;
                    Axis.bRelPos          := TRUE;
                    rLastTarget           := rActPos + rTargetPos;
                    diMoveSnap            := diScanCount;
                    diMoveStartSnap       := diScanCount;
                    diMoveTimeLatch       := 0;
                    bMoving               := TRUE;
                    bToutReported        := FALSE;
                    iStep                 := AXST_MOVE;
                END_IF;
            END_IF;
        END_IF;

        (* 5.6 段推进与完成判定（运动中驱动器 bMotionState 回落且到位 → 本段完成） *)
        IF bMoving AND NOT bMotionState AND (ABS(rActPos - rLastTarget) <= rTolerance) THEN
            IF iStep = AXST_BUFFER THEN
                IF iBufSeg < (iSegCount - 1) THEN
                    (* 下一段：目标/速度取自段表，发绝对定位脉冲（段表 base 0，合法下标 0..iSegCount-1） *)
                    iBufSeg               := iBufSeg + 1;
                    Axis.fTarPosition1    := arSegPos[iBufSeg];
                    Axis.fTarVelocity1    := arSegVel[iBufSeg];
                    Axis.fTarAcceleration1:= rAcc;
                    Axis.fTarDecelaration1:= rDec;
                    Axis.wCurveType1      := 0;
                    Axis.bAbsPos          := TRUE;
                    rLastTarget           := arSegPos[iBufSeg];
                    diMoveSnap            := diScanCount;
                    bToutReported        := FALSE;
                ELSE
                    (* 全部段完成：锁存整体离散运动用时（整体起点→末段到位，ms） *)
                    diMoveTimeLatch := (diScanCount - diMoveStartSnap) * 10;
                    bMoving := FALSE;
                    iStep   := AXST_READY;
                END_IF;
            ELSE
                (* 单段完成：锁存本段离散运动用时（ms） *)
                diMoveTimeLatch := (diScanCount - diMoveSnap) * 10;
                bMoving := FALSE;
                iStep   := AXST_READY;
            END_IF;
        END_IF;

        (* 5.7 单段超时：diTimeout(ms) 内未到位 → 2005 Critical，发停车 *)
        IF bMoving AND NOT bToutReported THEN
            IF (diScanCount - diMoveSnap) * 10 >= diTimeout THEN
                bToutReported := TRUE;
                bTimeoutEv    := TRUE;
                iTimeoutCode  := ERR_AXIS_STEP_TOUT;
                Axis.bStop    := TRUE;
                bMoving       := FALSE;
                iStep         := AXST_ERROR;
            END_IF;
        END_IF;
    END_IF;
END_IF;

(* 5.8 拒绝/超时事件上报（驱动器故障事件优先） *)
IF NOT bFaultEvent THEN
    IF bTimeoutEv THEN
        bFaultEvent := TRUE; iFaultCode := iTimeoutCode; iFaultLevel := 2; iFaultSub := 0;
    ELSIF bSwRej THEN
        bFaultEvent := TRUE; iFaultCode := iRejCode; iFaultLevel := 1; iFaultSub := 0;
    END_IF;
END_IF;

(* 到位：静止且在最后目标容差内 *)
bInPosition := bPowerState AND NOT bMotionState AND NOT bMoving
               AND (ABS(rActPos - rLastTarget) <= rTolerance);

(*------------------------------------------------------------
  6) 状态全量回填 stStatus（Servo + Force + 业务层）
------------------------------------------------------------*)
stStatus.Servo.rActPosition         := rActPos;
stStatus.Servo.rActVelocity         := rActVel;
stStatus.Servo.rActTorque           := rActTorque;
stStatus.Servo.iDriveErrorCode      := iDrvCode;
stStatus.Servo.iErrorCode           := iFaultCode;
stStatus.Servo.diDiscreteMotionTime := diMoveTimeLatch;   (* 最近一次离散定位完成用时(ms)，完成时锁存 *)
stStatus.Servo.bEnabled             := bPowerState;
stStatus.Servo.bReady               := bPowerState AND NOT bDrvErr;
stStatus.Servo.bBusy                := bMotionState OR bMoving OR bJogActive;
stStatus.Servo.bDone                := bInPosition;
stStatus.Servo.bStandStill          := bStandStill;
stStatus.Servo.bInPosition          := bInPosition;
stStatus.Servo.bDiscreteMotion      := bMoving;
stStatus.Servo.bMoveDone            := bInPosition AND (iStep = AXST_READY);  (* 完成脉冲近似 *)
stStatus.Servo.bZeroCommissioned    := bZeroCommRetain;
stStatus.Servo.bZeroCommissioning   := bZeroComm;
stStatus.Servo.bOriginSwitch        := Axis.bhomestate;
stStatus.Servo.bPosLimit            := Axis.bphlimit OR Axis.bpslimit;
stStatus.Servo.bNegLimit            := Axis.bnhlimit OR Axis.bnslimit;
stStatus.Servo.bError               := bDrvErr OR (iStep = AXST_ERROR);
stStatus.Servo.bStopping            := bStop OR bSafetyStop OR (Axis.wPLCOpenState = 3);
stStatus.Servo.bEncoderFault        := bEncFltLatch;   (* 编码器反馈故障锁存（码表见 1.1 TODO，联调填码） *)

stStatus.Force.rBiasPosPct          := rBiasP;
stStatus.Force.rBiasNegPct          := rBiasN;
stStatus.Force.rNetTorquePct        := rNetPct;
stStatus.Force.rForceRawN           := rForceRawN;
stStatus.Force.rForceFiltN          := rFiltN;
stStatus.Force.diOverForceET        := diOverCnt * 10;
stStatus.Force.bForceValid          := bPowerState AND (bBiasPValid OR bBiasNValid);
stStatus.Force.bBiasPosValid        := bBiasPValid;
stStatus.Force.bBiasNegValid        := bBiasNValid;
stStatus.Force.bOverForce           := bOverForce;
stStatus.Force.bOverForceLatched    := bOverLatch;

stStatus.iCurrentStep               := iStep;
stStatus.diMotionTime               := (diScanCount - diMoveSnap) * 10;
stStatus.iErrorCode                 := iFaultCode;
stStatus.bCalibrated                := bZeroCommRetain;
stStatus.bError                     := bDrvErr OR (iStep = AXST_ERROR);
stStatus.bWarning                   := bSwRej;
stStatus.bAxisErrorStopping         := bTimeoutEv;
stStatus.bAtInit                    := bAtInit;

END_FUNCTION_BLOCK
