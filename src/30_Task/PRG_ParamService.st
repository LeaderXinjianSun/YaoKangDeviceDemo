(*============================================================================
  PRG_ParamService —— 层 30 任务：参数管理服务（扫描链第 8 环）
  ----------------------------------------------------------------------------
  唯一写入：GVL_Params 三区（run* 运行区 / retain* 保持区）；
            6 处 ConfigCmd 的 bSuccess/bError/iErrorCode 回令及其 4 个命令位回清；
            Condition.Status 的 iParamError/iParamErrorAxis/iParamErrorField/bParamValid；
            HMI 参数编辑缓冲（Load/上电/ResetDefault 时由运行区/默认值刷新）。
  读入：  HMI.*.ConfigCmd（bLoad/bApply/bSave/bResetDefault）、HMI 参数编辑缓冲、
          iState（运行区锁定判定）、bRevalidateParams 电平（参数重校验）。
  三区模型：
    编辑缓冲 = HMI D 区（HMI.Condition.Param / 各轴 .Config / HomingParams.Params /
               TailTilt.Config），HMI 直接读写，Apply 前不影响运行。
    运行区   = GVL_Params.run*（非保持），任务/运动 FB 只读；Apply 校验通过后
               由编辑缓冲覆盖；上电从 Retain 装载，Retain 无效则工厂默认。
    Retain区 = GVL_Params.retain*（VAR_GLOBAL RETAIN），Save 时由运行区写入。
  ConfigCmd 语义（命令位为本程序私有脉冲，本程序自行 R_TRIG 锁存+回清，
    InputAdapter 不触碰）：
    bLoad         : 运行区 → 编辑缓冲（放弃未应用的线上修改）
    bApply        : 编辑缓冲 → FC_ValidateParams → 通过覆盖运行区，失败回三元组
    bSave         : 运行区 → Retain（置 retainValid）
    bResetDefault : 工厂默认 → 运行区+缓冲+Retain（运行锁定态拒绝 Apply/Default）
  轴数组下标（GVL_Params.runAxis[3]，base 0）：0=Chest 冲击 / 1=Seat 扭角 / 2=Leg 转角。
  注：iBlock=1..6 为 FC_ValidateParams 功能块协议块号（非数组下标，不改）。
  P11：设备身份 D1000/D1010 的 Load/Apply 见段 8（本程序实现）。
==========================================================================*)
PROGRAM PRG_ParamService
VAR
    (* 6 块 × 4 命令 = 24 路上升沿（TRIG.R_TRIG，仅局部 VAR；
       命名 r<块><命令>：Cnd=Cond  Tail=推杆  C1=Chest C2=Seat C3=Leg  Hom=回零） *)
    rCndLoad  : TRIG.R_TRIG;  rCndApply : TRIG.R_TRIG;  rCndSave  : TRIG.R_TRIG;  rCndDef   : TRIG.R_TRIG;
    rTailLoad : TRIG.R_TRIG;  rTailApply: TRIG.R_TRIG;  rTailSave : TRIG.R_TRIG;  rTailDef  : TRIG.R_TRIG;
    rC1Load   : TRIG.R_TRIG;  rC1Apply  : TRIG.R_TRIG;  rC1Save   : TRIG.R_TRIG;  rC1Def    : TRIG.R_TRIG;
    rC2Load   : TRIG.R_TRIG;  rC2Apply  : TRIG.R_TRIG;  rC2Save   : TRIG.R_TRIG;  rC2Def    : TRIG.R_TRIG;
    rC3Load   : TRIG.R_TRIG;  rC3Apply  : TRIG.R_TRIG;  rC3Save   : TRIG.R_TRIG;  rC3Def    : TRIG.R_TRIG;
    rHomLoad  : TRIG.R_TRIG;  rHomApply : TRIG.R_TRIG;  rHomSave  : TRIG.R_TRIG;  rHomDef   : TRIG.R_TRIG;

    (* P11 设备身份维护命令（D1010 块，仅 Load/Apply） *)
    rDevLoad  : TRIG.R_TRIG;  rDevApply : TRIG.R_TRIG;
END_VAR


(*==========================================================================
  1. 上电首扫：Retain 有效 → 装载保持区；无效 → 工厂默认装载并落 Retain
     同时刷新全部 HMI 编辑缓冲（等同上电自动 Load，HMI 开机即见生效值）。
  ==========================================================================*)
IF NOT bParamBootDone THEN
    IF retainValid THEN
        (*--- Retain 有效：保持区 → 运行区 ---*)
        runCond    := retainCond;
        runAxis    := retainAxis;
        runHoming  := retainHoming;
        runPusher  := retainPusher;
    ELSE
        (*--- Retain 无效（首板/失保持）：工厂默认 → 运行区 ---*)
        runCond   := FC_DefaultConditionParams();
        runAxis[0] := FC_DefaultAxisConfig();    (* 下标0 Chest 冲击 *)
        runAxis[1] := FC_DefaultAxisConfig();    (* 下标1 Seat 扭角 *)
        runAxis[2] := FC_DefaultAxisConfig();    (* 下标2 Leg 转角 *)
        runHoming := FC_DefaultHomingParams();
        runPusher := FC_DefaultPusherConfig();
        (*--- 默认值同步落 Retain，置有效标志 ---*)
        retainCond   := runCond;
        retainAxis   := runAxis;
        retainHoming := runHoming;
        retainPusher := runPusher;
        retainValid  := TRUE;
    END_IF;

    (*--- 运行区 → HMI 编辑缓冲（上电自动 Load） ---*)
    HMI.Condition.Param      := runCond;
    HMI.ChestImpact.Config   := runAxis[0];
    HMI.SeatTwist.Config     := runAxis[1];
    HMI.LegAngle.Config      := runAxis[2];
    HMI.HomingParams.Params  := runHoming;
    HMI.TailTilt.Config      := runPusher;

    bRunParamValid := TRUE;
    bParamBootDone := TRUE;

    (*--- 上电清 6 块命令/回令位，避免残留 ---*)
    HMI.Condition.ParamCmd.bLoad := FALSE;  HMI.Condition.ParamCmd.bApply := FALSE;
    HMI.Condition.ParamCmd.bSave := FALSE;  HMI.Condition.ParamCmd.bResetDefault := FALSE;
    HMI.Condition.ParamCmd.bSuccess := FALSE; HMI.Condition.ParamCmd.bError := FALSE;
    HMI.Condition.ParamCmd.iErrorCode := 0;
    HMI.TailTilt.ConfigCmd.bLoad := FALSE;  HMI.TailTilt.ConfigCmd.bApply := FALSE;
    HMI.TailTilt.ConfigCmd.bSave := FALSE;  HMI.TailTilt.ConfigCmd.bResetDefault := FALSE;
    HMI.TailTilt.ConfigCmd.bSuccess := FALSE; HMI.TailTilt.ConfigCmd.bError := FALSE;
    HMI.TailTilt.ConfigCmd.iErrorCode := 0;
    FOR psI := 0 TO 2 DO
        IF psI = 0 THEN
            HMI.ChestImpact.ConfigCmd.bLoad := FALSE; HMI.ChestImpact.ConfigCmd.bApply := FALSE;
            HMI.ChestImpact.ConfigCmd.bSave := FALSE; HMI.ChestImpact.ConfigCmd.bResetDefault := FALSE;
            HMI.ChestImpact.ConfigCmd.bSuccess := FALSE; HMI.ChestImpact.ConfigCmd.bError := FALSE;
            HMI.ChestImpact.ConfigCmd.iErrorCode := 0;
        ELSIF psI = 1 THEN
            HMI.SeatTwist.ConfigCmd.bLoad := FALSE; HMI.SeatTwist.ConfigCmd.bApply := FALSE;
            HMI.SeatTwist.ConfigCmd.bSave := FALSE; HMI.SeatTwist.ConfigCmd.bResetDefault := FALSE;
            HMI.SeatTwist.ConfigCmd.bSuccess := FALSE; HMI.SeatTwist.ConfigCmd.bError := FALSE;
            HMI.SeatTwist.ConfigCmd.iErrorCode := 0;
        ELSE
            HMI.LegAngle.ConfigCmd.bLoad := FALSE; HMI.LegAngle.ConfigCmd.bApply := FALSE;
            HMI.LegAngle.ConfigCmd.bSave := FALSE; HMI.LegAngle.ConfigCmd.bResetDefault := FALSE;
            HMI.LegAngle.ConfigCmd.bSuccess := FALSE; HMI.LegAngle.ConfigCmd.bError := FALSE;
            HMI.LegAngle.ConfigCmd.iErrorCode := 0;
        END_IF;
    END_FOR;
    HMI.HomingParams.Cmd.bLoad := FALSE;  HMI.HomingParams.Cmd.bApply := FALSE;
    HMI.HomingParams.Cmd.bSave := FALSE;  HMI.HomingParams.Cmd.bResetDefault := FALSE;
    HMI.HomingParams.Cmd.bSuccess := FALSE; HMI.HomingParams.Cmd.bError := FALSE;
    HMI.HomingParams.Cmd.iErrorCode := 0;
END_IF;


(*==========================================================================
  2. 调理参数块 Condition.ParamCmd（iBlock=1）
  ==========================================================================*)
rCndLoad(CLK  := HMI.Condition.ParamCmd.bLoad);
rCndApply(CLK := HMI.Condition.ParamCmd.bApply);
rCndSave(CLK  := HMI.Condition.ParamCmd.bSave);
rCndDef(CLK   := HMI.Condition.ParamCmd.bResetDefault);

IF rCndLoad.Q THEN
    HMI.Condition.Param := runCond;                       (* 运行区 → 缓冲 *)
    HMI.Condition.ParamCmd.bSuccess := TRUE;
    HMI.Condition.ParamCmd.bError   := FALSE;
    HMI.Condition.ParamCmd.iErrorCode := 0;
ELSIF rCndApply.Q THEN
    IF iState = ST_AUTORUN THEN                            (* 运行锁定：快照不改 *)
        HMI.Condition.ParamCmd.bSuccess := FALSE;
        HMI.Condition.ParamCmd.bError   := TRUE;
        HMI.Condition.ParamCmd.iErrorCode := ERR_PARAM_LOCKED;
    ELSE
        psBVC := FC_ValidateParams(iBlock := 1, iErrCode => psIVCode, iErrAxis => psIVAxis, iErrField => psIVField);
        IF psBVC THEN
            runCond := HMI.Condition.Param;                (* 缓冲 → 运行区 *)
            bRunParamValid := TRUE;
            HMI.Condition.Status.iParamError     := 0;
            HMI.Condition.Status.iParamErrorAxis := 0;
            HMI.Condition.Status.iParamErrorField:= 0;
            HMI.Condition.ParamCmd.bSuccess := TRUE;
            HMI.Condition.ParamCmd.bError   := FALSE;
            HMI.Condition.ParamCmd.iErrorCode := 0;
        ELSE
            (* 校验拒绝：三元组上报 Condition.Status，运行区不动 *)
            HMI.Condition.Status.iParamError      := psIVCode;
            HMI.Condition.Status.iParamErrorAxis  := psIVAxis;
            HMI.Condition.Status.iParamErrorField := psIVField;
            HMI.Condition.ParamCmd.bSuccess := FALSE;
            HMI.Condition.ParamCmd.bError   := TRUE;
            HMI.Condition.ParamCmd.iErrorCode := psIVCode;
        END_IF;
    END_IF;
ELSIF rCndSave.Q THEN
    retainCond  := runCond;                                (* 运行区 → Retain *)
    retainValid := TRUE;
    HMI.Condition.ParamCmd.bSuccess := TRUE;
    HMI.Condition.ParamCmd.bError   := FALSE;
    HMI.Condition.ParamCmd.iErrorCode := 0;
ELSIF rCndDef.Q THEN
    IF iState = ST_AUTORUN THEN
        HMI.Condition.ParamCmd.bSuccess := FALSE;
        HMI.Condition.ParamCmd.bError   := TRUE;
        HMI.Condition.ParamCmd.iErrorCode := ERR_PARAM_LOCKED;
    ELSE
        runCond := FC_DefaultConditionParams();            (* 工厂默认 → 运行区 *)
        HMI.Condition.Param := runCond;                    (* 同步缓冲 *)
        retainCond := runCond;                             (* 同步 Retain *)
        retainValid := TRUE;
        bRunParamValid := TRUE;
        HMI.Condition.ParamCmd.bSuccess := TRUE;
        HMI.Condition.ParamCmd.bError   := FALSE;
        HMI.Condition.ParamCmd.iErrorCode := 0;
    END_IF;
END_IF;
(* 回令后命令位回清（本块私有脉冲，本程序唯一触碰） *)
HMI.Condition.ParamCmd.bLoad         := FALSE;
HMI.Condition.ParamCmd.bApply        := FALSE;
HMI.Condition.ParamCmd.bSave         := FALSE;
HMI.Condition.ParamCmd.bResetDefault := FALSE;


(*==========================================================================
  3. 推杆配置块 TailTilt.ConfigCmd（iBlock=2，iErrAxis=4）
  ==========================================================================*)
rTailLoad(CLK  := HMI.TailTilt.ConfigCmd.bLoad);
rTailApply(CLK := HMI.TailTilt.ConfigCmd.bApply);
rTailSave(CLK  := HMI.TailTilt.ConfigCmd.bSave);
rTailDef(CLK   := HMI.TailTilt.ConfigCmd.bResetDefault);

IF rTailLoad.Q THEN
    HMI.TailTilt.Config := runPusher;
    HMI.TailTilt.ConfigCmd.bSuccess := TRUE;
    HMI.TailTilt.ConfigCmd.bError   := FALSE;
    HMI.TailTilt.ConfigCmd.iErrorCode := 0;
ELSIF rTailApply.Q THEN
    IF iState = ST_AUTORUN THEN
        HMI.TailTilt.ConfigCmd.bSuccess := FALSE;
        HMI.TailTilt.ConfigCmd.bError   := TRUE;
        HMI.TailTilt.ConfigCmd.iErrorCode := ERR_PARAM_LOCKED;
    ELSE
        psBVC := FC_ValidateParams(iBlock := 2, iErrCode => psIVCode, iErrAxis => psIVAxis, iErrField => psIVField);
        IF psBVC THEN
            runPusher := HMI.TailTilt.Config;
            bRunParamValid := TRUE;
            HMI.TailTilt.ConfigCmd.bSuccess := TRUE;
            HMI.TailTilt.ConfigCmd.bError   := FALSE;
            HMI.TailTilt.ConfigCmd.iErrorCode := 0;
        ELSE
            HMI.Condition.Status.iParamError      := psIVCode;
            HMI.Condition.Status.iParamErrorAxis  := psIVAxis;
            HMI.Condition.Status.iParamErrorField := psIVField;
            HMI.TailTilt.ConfigCmd.bSuccess := FALSE;
            HMI.TailTilt.ConfigCmd.bError   := TRUE;
            HMI.TailTilt.ConfigCmd.iErrorCode := psIVCode;
        END_IF;
    END_IF;
ELSIF rTailSave.Q THEN
    retainPusher := runPusher;
    retainValid  := TRUE;
    HMI.TailTilt.ConfigCmd.bSuccess := TRUE;
    HMI.TailTilt.ConfigCmd.bError   := FALSE;
    HMI.TailTilt.ConfigCmd.iErrorCode := 0;
ELSIF rTailDef.Q THEN
    IF iState = ST_AUTORUN THEN
        HMI.TailTilt.ConfigCmd.bSuccess := FALSE;
        HMI.TailTilt.ConfigCmd.bError   := TRUE;
        HMI.TailTilt.ConfigCmd.iErrorCode := ERR_PARAM_LOCKED;
    ELSE
        runPusher := FC_DefaultPusherConfig();
        HMI.TailTilt.Config := runPusher;
        retainPusher := runPusher;
        retainValid  := TRUE;
        bRunParamValid := TRUE;
        HMI.TailTilt.ConfigCmd.bSuccess := TRUE;
        HMI.TailTilt.ConfigCmd.bError   := FALSE;
        HMI.TailTilt.ConfigCmd.iErrorCode := 0;
    END_IF;
END_IF;
HMI.TailTilt.ConfigCmd.bLoad         := FALSE;
HMI.TailTilt.ConfigCmd.bApply        := FALSE;
HMI.TailTilt.ConfigCmd.bSave         := FALSE;
HMI.TailTilt.ConfigCmd.bResetDefault := FALSE;


(*==========================================================================
  4. 三轴 Config 块（内部下标 base 0：0=Chest 1=Seat 2=Leg；校验块号 3/5/4）
  ==========================================================================*)
(*--- 下标0 ChestImpact（校验 iBlock=3，协议块号非数组下标） ---*)
rC1Load(CLK  := HMI.ChestImpact.ConfigCmd.bLoad);
rC1Apply(CLK := HMI.ChestImpact.ConfigCmd.bApply);
rC1Save(CLK  := HMI.ChestImpact.ConfigCmd.bSave);
rC1Def(CLK   := HMI.ChestImpact.ConfigCmd.bResetDefault);
IF rC1Load.Q THEN
    HMI.ChestImpact.Config := runAxis[0];
    HMI.ChestImpact.ConfigCmd.bSuccess := TRUE;
    HMI.ChestImpact.ConfigCmd.bError   := FALSE;
    HMI.ChestImpact.ConfigCmd.iErrorCode := 0;
ELSIF rC1Apply.Q THEN
    IF iState = ST_AUTORUN THEN
        HMI.ChestImpact.ConfigCmd.bSuccess := FALSE;
        HMI.ChestImpact.ConfigCmd.bError   := TRUE;
        HMI.ChestImpact.ConfigCmd.iErrorCode := ERR_PARAM_LOCKED;
    ELSE
        psBVC := FC_ValidateParams(iBlock := 3, iErrCode => psIVCode, iErrAxis => psIVAxis, iErrField => psIVField);
        IF psBVC THEN
            runAxis[0] := HMI.ChestImpact.Config;
            bRunParamValid := TRUE;
            HMI.ChestImpact.ConfigCmd.bSuccess := TRUE;
            HMI.ChestImpact.ConfigCmd.bError   := FALSE;
            HMI.ChestImpact.ConfigCmd.iErrorCode := 0;
        ELSE
            HMI.Condition.Status.iParamError      := psIVCode;
            HMI.Condition.Status.iParamErrorAxis  := psIVAxis;
            HMI.Condition.Status.iParamErrorField := psIVField;
            HMI.ChestImpact.ConfigCmd.bSuccess := FALSE;
            HMI.ChestImpact.ConfigCmd.bError   := TRUE;
            HMI.ChestImpact.ConfigCmd.iErrorCode := psIVCode;
        END_IF;
    END_IF;
ELSIF rC1Save.Q THEN
    retainAxis[0] := runAxis[0];
    retainValid   := TRUE;
    HMI.ChestImpact.ConfigCmd.bSuccess := TRUE;
    HMI.ChestImpact.ConfigCmd.bError   := FALSE;
    HMI.ChestImpact.ConfigCmd.iErrorCode := 0;
ELSIF rC1Def.Q THEN
    IF iState = ST_AUTORUN THEN
        HMI.ChestImpact.ConfigCmd.bSuccess := FALSE;
        HMI.ChestImpact.ConfigCmd.bError   := TRUE;
        HMI.ChestImpact.ConfigCmd.iErrorCode := ERR_PARAM_LOCKED;
    ELSE
        runAxis[0] := FC_DefaultAxisConfig();
        HMI.ChestImpact.Config := runAxis[0];
        retainAxis[0] := runAxis[0];
        retainValid   := TRUE;
        bRunParamValid := TRUE;
        HMI.ChestImpact.ConfigCmd.bSuccess := TRUE;
        HMI.ChestImpact.ConfigCmd.bError   := FALSE;
        HMI.ChestImpact.ConfigCmd.iErrorCode := 0;
    END_IF;
END_IF;
HMI.ChestImpact.ConfigCmd.bLoad         := FALSE;
HMI.ChestImpact.ConfigCmd.bApply        := FALSE;
HMI.ChestImpact.ConfigCmd.bSave         := FALSE;
HMI.ChestImpact.ConfigCmd.bResetDefault := FALSE;

(*--- 下标1 SeatTwist（校验 iBlock=5，协议块号非数组下标） ---*)
rC2Load(CLK  := HMI.SeatTwist.ConfigCmd.bLoad);
rC2Apply(CLK := HMI.SeatTwist.ConfigCmd.bApply);
rC2Save(CLK  := HMI.SeatTwist.ConfigCmd.bSave);
rC2Def(CLK   := HMI.SeatTwist.ConfigCmd.bResetDefault);
IF rC2Load.Q THEN
    HMI.SeatTwist.Config := runAxis[1];
    HMI.SeatTwist.ConfigCmd.bSuccess := TRUE;
    HMI.SeatTwist.ConfigCmd.bError   := FALSE;
    HMI.SeatTwist.ConfigCmd.iErrorCode := 0;
ELSIF rC2Apply.Q THEN
    IF iState = ST_AUTORUN THEN
        HMI.SeatTwist.ConfigCmd.bSuccess := FALSE;
        HMI.SeatTwist.ConfigCmd.bError   := TRUE;
        HMI.SeatTwist.ConfigCmd.iErrorCode := ERR_PARAM_LOCKED;
    ELSE
        psBVC := FC_ValidateParams(iBlock := 5, iErrCode => psIVCode, iErrAxis => psIVAxis, iErrField => psIVField);
        IF psBVC THEN
            runAxis[1] := HMI.SeatTwist.Config;
            bRunParamValid := TRUE;
            HMI.SeatTwist.ConfigCmd.bSuccess := TRUE;
            HMI.SeatTwist.ConfigCmd.bError   := FALSE;
            HMI.SeatTwist.ConfigCmd.iErrorCode := 0;
        ELSE
            HMI.Condition.Status.iParamError      := psIVCode;
            HMI.Condition.Status.iParamErrorAxis  := psIVAxis;
            HMI.Condition.Status.iParamErrorField := psIVField;
            HMI.SeatTwist.ConfigCmd.bSuccess := FALSE;
            HMI.SeatTwist.ConfigCmd.bError   := TRUE;
            HMI.SeatTwist.ConfigCmd.iErrorCode := psIVCode;
        END_IF;
    END_IF;
ELSIF rC2Save.Q THEN
    retainAxis[1] := runAxis[1];
    retainValid   := TRUE;
    HMI.SeatTwist.ConfigCmd.bSuccess := TRUE;
    HMI.SeatTwist.ConfigCmd.bError   := FALSE;
    HMI.SeatTwist.ConfigCmd.iErrorCode := 0;
ELSIF rC2Def.Q THEN
    IF iState = ST_AUTORUN THEN
        HMI.SeatTwist.ConfigCmd.bSuccess := FALSE;
        HMI.SeatTwist.ConfigCmd.bError   := TRUE;
        HMI.SeatTwist.ConfigCmd.iErrorCode := ERR_PARAM_LOCKED;
    ELSE
        runAxis[1] := FC_DefaultAxisConfig();
        HMI.SeatTwist.Config := runAxis[1];
        retainAxis[1] := runAxis[1];
        retainValid   := TRUE;
        bRunParamValid := TRUE;
        HMI.SeatTwist.ConfigCmd.bSuccess := TRUE;
        HMI.SeatTwist.ConfigCmd.bError   := FALSE;
        HMI.SeatTwist.ConfigCmd.iErrorCode := 0;
    END_IF;
END_IF;
HMI.SeatTwist.ConfigCmd.bLoad         := FALSE;
HMI.SeatTwist.ConfigCmd.bApply        := FALSE;
HMI.SeatTwist.ConfigCmd.bSave         := FALSE;
HMI.SeatTwist.ConfigCmd.bResetDefault := FALSE;

(*--- 下标2 LegAngle（校验 iBlock=4，协议块号非数组下标） ---*)
rC3Load(CLK  := HMI.LegAngle.ConfigCmd.bLoad);
rC3Apply(CLK := HMI.LegAngle.ConfigCmd.bApply);
rC3Save(CLK  := HMI.LegAngle.ConfigCmd.bSave);
rC3Def(CLK   := HMI.LegAngle.ConfigCmd.bResetDefault);
IF rC3Load.Q THEN
    HMI.LegAngle.Config := runAxis[2];
    HMI.LegAngle.ConfigCmd.bSuccess := TRUE;
    HMI.LegAngle.ConfigCmd.bError   := FALSE;
    HMI.LegAngle.ConfigCmd.iErrorCode := 0;
ELSIF rC3Apply.Q THEN
    IF iState = ST_AUTORUN THEN
        HMI.LegAngle.ConfigCmd.bSuccess := FALSE;
        HMI.LegAngle.ConfigCmd.bError   := TRUE;
        HMI.LegAngle.ConfigCmd.iErrorCode := ERR_PARAM_LOCKED;
    ELSE
        psBVC := FC_ValidateParams(iBlock := 4, iErrCode => psIVCode, iErrAxis => psIVAxis, iErrField => psIVField);
        IF psBVC THEN
            runAxis[2] := HMI.LegAngle.Config;
            bRunParamValid := TRUE;
            HMI.LegAngle.ConfigCmd.bSuccess := TRUE;
            HMI.LegAngle.ConfigCmd.bError   := FALSE;
            HMI.LegAngle.ConfigCmd.iErrorCode := 0;
        ELSE
            HMI.Condition.Status.iParamError      := psIVCode;
            HMI.Condition.Status.iParamErrorAxis  := psIVAxis;
            HMI.Condition.Status.iParamErrorField := psIVField;
            HMI.LegAngle.ConfigCmd.bSuccess := FALSE;
            HMI.LegAngle.ConfigCmd.bError   := TRUE;
            HMI.LegAngle.ConfigCmd.iErrorCode := psIVCode;
        END_IF;
    END_IF;
ELSIF rC3Save.Q THEN
    retainAxis[2] := runAxis[2];
    retainValid   := TRUE;
    HMI.LegAngle.ConfigCmd.bSuccess := TRUE;
    HMI.LegAngle.ConfigCmd.bError   := FALSE;
    HMI.LegAngle.ConfigCmd.iErrorCode := 0;
ELSIF rC3Def.Q THEN
    IF iState = ST_AUTORUN THEN
        HMI.LegAngle.ConfigCmd.bSuccess := FALSE;
        HMI.LegAngle.ConfigCmd.bError   := TRUE;
        HMI.LegAngle.ConfigCmd.iErrorCode := ERR_PARAM_LOCKED;
    ELSE
        runAxis[2] := FC_DefaultAxisConfig();
        HMI.LegAngle.Config := runAxis[2];
        retainAxis[2] := runAxis[2];
        retainValid   := TRUE;
        bRunParamValid := TRUE;
        HMI.LegAngle.ConfigCmd.bSuccess := TRUE;
        HMI.LegAngle.ConfigCmd.bError   := FALSE;
        HMI.LegAngle.ConfigCmd.iErrorCode := 0;
    END_IF;
END_IF;
HMI.LegAngle.ConfigCmd.bLoad         := FALSE;
HMI.LegAngle.ConfigCmd.bApply        := FALSE;
HMI.LegAngle.ConfigCmd.bSave         := FALSE;
HMI.LegAngle.ConfigCmd.bResetDefault := FALSE;


(*==========================================================================
  5. 回零参数块 HomingParams.Cmd（iBlock=6，iErrAxis=0 全局）
  ==========================================================================*)
rHomLoad(CLK  := HMI.HomingParams.Cmd.bLoad);
rHomApply(CLK := HMI.HomingParams.Cmd.bApply);
rHomSave(CLK  := HMI.HomingParams.Cmd.bSave);
rHomDef(CLK   := HMI.HomingParams.Cmd.bResetDefault);

IF rHomLoad.Q THEN
    HMI.HomingParams.Params := runHoming;
    HMI.HomingParams.Cmd.bSuccess := TRUE;
    HMI.HomingParams.Cmd.bError   := FALSE;
    HMI.HomingParams.Cmd.iErrorCode := 0;
ELSIF rHomApply.Q THEN
    IF iState = ST_AUTORUN THEN
        HMI.HomingParams.Cmd.bSuccess := FALSE;
        HMI.HomingParams.Cmd.bError   := TRUE;
        HMI.HomingParams.Cmd.iErrorCode := ERR_PARAM_LOCKED;
    ELSE
        psBVC := FC_ValidateParams(iBlock := 6, iErrCode => psIVCode, iErrAxis => psIVAxis, iErrField => psIVField);
        IF psBVC THEN
            runHoming := HMI.HomingParams.Params;
            bRunParamValid := TRUE;
            HMI.HomingParams.Cmd.bSuccess := TRUE;
            HMI.HomingParams.Cmd.bError   := FALSE;
            HMI.HomingParams.Cmd.iErrorCode := 0;
        ELSE
            HMI.Condition.Status.iParamError      := psIVCode;
            HMI.Condition.Status.iParamErrorAxis  := psIVAxis;
            HMI.Condition.Status.iParamErrorField := psIVField;
            HMI.HomingParams.Cmd.bSuccess := FALSE;
            HMI.HomingParams.Cmd.bError   := TRUE;
            HMI.HomingParams.Cmd.iErrorCode := psIVCode;
        END_IF;
    END_IF;
ELSIF rHomSave.Q THEN
    retainHoming := runHoming;
    retainValid  := TRUE;
    HMI.HomingParams.Cmd.bSuccess := TRUE;
    HMI.HomingParams.Cmd.bError   := FALSE;
    HMI.HomingParams.Cmd.iErrorCode := 0;
ELSIF rHomDef.Q THEN
    IF iState = ST_AUTORUN THEN
        HMI.HomingParams.Cmd.bSuccess := FALSE;
        HMI.HomingParams.Cmd.bError   := TRUE;
        HMI.HomingParams.Cmd.iErrorCode := ERR_PARAM_LOCKED;
    ELSE
        runHoming := FC_DefaultHomingParams();
        HMI.HomingParams.Params := runHoming;
        retainHoming := runHoming;
        retainValid  := TRUE;
        bRunParamValid := TRUE;
        HMI.HomingParams.Cmd.bSuccess := TRUE;
        HMI.HomingParams.Cmd.bError   := FALSE;
        HMI.HomingParams.Cmd.iErrorCode := 0;
    END_IF;
END_IF;
HMI.HomingParams.Cmd.bLoad         := FALSE;
HMI.HomingParams.Cmd.bApply        := FALSE;
HMI.HomingParams.Cmd.bSave         := FALSE;
HMI.HomingParams.Cmd.bResetDefault := FALSE;


(*==========================================================================
  6. 参数重校验（Sys.Cmd.bRevalidateParams 电平，InputAdapter 镜像 bRevalidateParams）
     按住时对 6 块全量校验，结果刷 Condition.Status.bParamValid / iParamError。
  ==========================================================================*)
IF bRevalidateParams THEN
    psBVC := TRUE;
    FOR psI := 1 TO 6 DO
        psBVC := FC_ValidateParams(iBlock := psI, iErrCode => psIVCode, iErrAxis => psIVAxis, iErrField => psIVField);
        IF NOT psBVC THEN
            EXIT;   (* 遇首块非法即停止，三元组已定位 *)
        END_IF;
    END_FOR;
    HMI.Condition.Status.bParamValid := psBVC;
    IF psBVC THEN
        HMI.Condition.Status.iParamError      := 0;
        HMI.Condition.Status.iParamErrorAxis  := 0;
        HMI.Condition.Status.iParamErrorField := 0;
    ELSE
        HMI.Condition.Status.iParamError      := psIVCode;
        HMI.Condition.Status.iParamErrorAxis  := psIVAxis;
        HMI.Condition.Status.iParamErrorField := psIVField;
    END_IF;
END_IF;


(*==========================================================================
  7. 建零 Retain 握手（单写源：retainZeroComm / retainTailZeroComm 仅本环可写）
     - bZeroCommSetReq[0..2]（base 0：0=Chest/1=Seat/2=Leg）：TASK_RUNNER 环7 见 Servo.bZeroCommissioned 置位 →
       本环消费写 retainZeroComm[i] 并清请求；
     - bPushCalibDoneLatch：OUTPUT_ADAPTER 环10 见 fbPusher.bCalibDone 脉冲置位 →
       本环消费写 retainTailZeroComm 并清锁存；
     - trigClearZeroRetain（环2 脉冲，本环同扫可见）：工程师清参考，清全部
       Retain 与跨环请求/锁存（清后建零门控 6 之"参考无效"条件成立）。
     Retain 只置不清（除清除命令）：重复标定不重复写无副作用。
  ==========================================================================*)
IF bZeroCommSetReq[0] THEN
    retainZeroComm[0] := TRUE;
    bZeroCommSetReq[0] := FALSE;
END_IF;
IF bZeroCommSetReq[1] THEN
    retainZeroComm[1] := TRUE;
    bZeroCommSetReq[1] := FALSE;
END_IF;
IF bZeroCommSetReq[2] THEN
    retainZeroComm[2] := TRUE;
    bZeroCommSetReq[2] := FALSE;
END_IF;
IF bPushCalibDoneLatch THEN
    retainTailZeroComm := TRUE;
    bPushCalibDoneLatch := FALSE;
END_IF;
IF trigClearZeroRetain THEN
    retainZeroComm[0] := FALSE;
    retainZeroComm[1] := FALSE;
    retainZeroComm[2] := FALSE;
    retainTailZeroComm := FALSE;
    bZeroCommSetReq[0] := FALSE;
    bZeroCommSetReq[1] := FALSE;
    bZeroCommSetReq[2] := FALSE;
    bPushCalibDoneLatch := FALSE;
END_IF;


(*==========================================================================
  8. 设备身份（D1000–D1013）
     - 只读镜像 HMI_DeviceIdentity（D1000–1004，PLC→HMI）每扫回填：
       diDeviceNoRaw := retainDeviceNo；iMacWord0/1/2 := _Ethernet.MACAddress[0..2]。
       （H5U 系统变量 _Ethernet.MACAddress 为 USINT[6]，赋值 INT 截低 8 位，
         MAC 取前三字节；若现场系统变量名有出入，仅改这三行映射。）
     - 维护写入 HMI_DeviceIdentityWrite（D1010–1013，双向）命令仅 Load/Apply：
       bLoad ：回读当前编号到 diDeviceNoRaw（并把 HMI 待写字段镜像为现值）；
       bApply：工程师双重门控（角色=工程师 且 权限码 16#5A）+ 非自动流程运行锁定，
               编号合法（>0）才写 retainDeviceNo，失败回 bError + 5005（锁定/越权）
               /5006（编号非法）。
     本块为身份区唯一写者；retainDeviceNo 单写源属本程序。
  ==========================================================================*)
psIMac0 := _Ethernet.MACAddress[0];
psIMac1 := _Ethernet.MACAddress[1];
psIMac2 := _Ethernet.MACAddress[2];
HMI_DeviceIdentity.diDeviceNoRaw := retainDeviceNo;
HMI_DeviceIdentity.iMacWord0     := psIMac0;
HMI_DeviceIdentity.iMacWord1     := psIMac1;
HMI_DeviceIdentity.iMacWord2     := psIMac2;

rDevLoad(CLK  := HMI_DeviceIdentityWrite.Cmd.bLoad);
rDevApply(CLK := HMI_DeviceIdentityWrite.Cmd.bApply);

IF rDevLoad.Q THEN
    (* 回读：待写字段镜像当前保持值，iErrorCode 清 0 *)
    HMI_DeviceIdentityWrite.diDeviceNoRaw := retainDeviceNo;
    HMI_DeviceIdentityWrite.Cmd.iErrorCode := 0;
    HMI_DeviceIdentityWrite.Cmd.bSuccess   := TRUE;
    HMI_DeviceIdentityWrite.Cmd.bError     := FALSE;
ELSIF rDevApply.Q THEN
    IF (iUserRole <> ROLE_ENGINEER) OR (HMI.Sys.Cmd.iAuthCode <> AUTH_CODE_ENGINEER)
       OR (iState = ST_AUTORUN) THEN
        (* 越权（非工程师/权限码错）或运行锁定 → 5005 *)
        HMI_DeviceIdentityWrite.Cmd.iErrorCode := ERR_PARAM_DEVICE_LOCKED;
        HMI_DeviceIdentityWrite.Cmd.bSuccess   := FALSE;
        HMI_DeviceIdentityWrite.Cmd.bError     := TRUE;
    ELSIF HMI_DeviceIdentityWrite.diDeviceNoRaw <= 0 THEN
        (* 编号非法 → 5006 *)
        HMI_DeviceIdentityWrite.Cmd.iErrorCode := ERR_PARAM_DEVICE_VALUE;
        HMI_DeviceIdentityWrite.Cmd.bSuccess   := FALSE;
        HMI_DeviceIdentityWrite.Cmd.bError     := TRUE;
    ELSE
        retainDeviceNo := HMI_DeviceIdentityWrite.diDeviceNoRaw;
        HMI_DeviceIdentityWrite.Cmd.iErrorCode := 0;
        HMI_DeviceIdentityWrite.Cmd.bSuccess   := TRUE;
        HMI_DeviceIdentityWrite.Cmd.bError     := FALSE;
    END_IF;
END_IF;
(* 回令后命令位回清（本块私有脉冲，本程序唯一触碰） *)
HMI_DeviceIdentityWrite.Cmd.bLoad  := FALSE;
HMI_DeviceIdentityWrite.Cmd.bApply := FALSE;

END_PROGRAM
