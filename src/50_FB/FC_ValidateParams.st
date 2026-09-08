(*============================================================================
  FC_ValidateParams —— 参数 Apply 前校验（P5）
  ----------------------------------------------------------------------------
  对指定参数块的编辑缓冲（HMI 区）做合法性检查，非法即拒绝且不触碰运行区。
  入参：iBlock —— 1=Condition 调理参数（含三轴 16 段往复）
                  2=Pusher 推杆配置（iErrAxis 恒为 AXIS_ID_TAIL=4）
                  3=Chest 冲击轴 Config（iErrAxis=1）
                  4=Leg   转角轴 Config（iErrAxis=2）
                  5=Seat  扭角轴 Config（iErrAxis=3）
                  6=Homing 回零参数（iErrAxis=0，全局）
  出参：iErrCode  —— 0=通过；PARAM_ERR_SEGMENT=1005 段数非法；ERR_PARAM_VALUE=5007 值非法
        iErrAxis  —— 错误所在轴（1=Chest 2=Leg 3=Seat 4=Tail，0=全局）
        iErrField —— 错误字段索引（块内编号，随 iParamErrorField 上报 HMI 定位）
  返回：TRUE=校验通过可 Apply；FALSE=拒绝（三元组已填）。
  说明：仅静态范围/逻辑校验；跨块一致性（如段位置 vs 轴软限位）在运行前检查
       （7xxx，P10）兜底。范围阈值为保守工程值，现场可按工艺收紧。
==========================================================================*)
FUNCTION FC_ValidateParams : BOOL
VAR_INPUT
    iBlock      : INT;
END_VAR
VAR_OUTPUT
    iErrCode    : INT;
    iErrAxis    : INT;
    iErrField   : INT;
END_VAR
(* 段循环下标 vpI 与轴配置视图 vpCfg 为函数私有工作变量，H5U 不支持 FUNCTION 局部
   VAR，已上移为 GVL_Internal 全局（vpI:INT / vpCfg:Stru_AxisLimitConfig）。 *)

(* 默认通过 *)
FC_ValidateParams := TRUE;
iErrCode  := 0;
iErrAxis  := 0;
iErrField := 0;

(*==========================================================================
  iBlock = 1：调理参数（三轴往复 + 全局）
  ==========================================================================*)
IF iBlock = 1 THEN
    (*--- 扭腰 SeatTwist（iErrAxis=AXIS_ID_SEAT=3） ---*)
    IF HMI.Condition.Param.SeatTwist.bEnabled THEN
        IF (HMI.Condition.Param.SeatTwist.iSegmentCount < 1) OR
           (HMI.Condition.Param.SeatTwist.iSegmentCount > 16) THEN
            FC_ValidateParams := FALSE; iErrCode := PARAM_ERR_SEGMENT; iErrAxis := AXIS_ID_SEAT; iErrField := 1; RETURN;
        END_IF;
        IF HMI.Condition.Param.SeatTwist.rAcc <= 0.0 THEN
            FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_SEAT; iErrField := 2; RETURN;
        END_IF;
        IF HMI.Condition.Param.SeatTwist.rDec <= 0.0 THEN
            FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_SEAT; iErrField := 3; RETURN;
        END_IF;
        IF (HMI.Condition.Param.SeatTwist.iCycleModeLen < 1) OR
           (HMI.Condition.Param.SeatTwist.iCycleModeLen > 16) THEN
            FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_SEAT; iErrField := 4; RETURN;
        END_IF;
        FOR vpI := 1 TO HMI.Condition.Param.SeatTwist.iSegmentCount DO
            IF HMI.Condition.Param.SeatTwist.arVelocity[vpI] <= 0.0 THEN
                FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_SEAT; iErrField := 100 + vpI; RETURN;
            END_IF;
        END_FOR;
    END_IF;

    (*--- 摆腿 LegAngle（iErrAxis=AXIS_ID_LEG=2） ---*)
    IF HMI.Condition.Param.LegAngle.bEnabled THEN
        IF (HMI.Condition.Param.LegAngle.iSegmentCount < 1) OR
           (HMI.Condition.Param.LegAngle.iSegmentCount > 16) THEN
            FC_ValidateParams := FALSE; iErrCode := PARAM_ERR_SEGMENT; iErrAxis := AXIS_ID_LEG; iErrField := 1; RETURN;
        END_IF;
        IF HMI.Condition.Param.LegAngle.rAcc <= 0.0 THEN
            FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_LEG; iErrField := 2; RETURN;
        END_IF;
        IF HMI.Condition.Param.LegAngle.rDec <= 0.0 THEN
            FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_LEG; iErrField := 3; RETURN;
        END_IF;
        IF (HMI.Condition.Param.LegAngle.iCycleModeLen < 1) OR
           (HMI.Condition.Param.LegAngle.iCycleModeLen > 16) THEN
            FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_LEG; iErrField := 4; RETURN;
        END_IF;
        FOR vpI := 1 TO HMI.Condition.Param.LegAngle.iSegmentCount DO
            IF HMI.Condition.Param.LegAngle.arVelocity[vpI] <= 0.0 THEN
                FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_LEG; iErrField := 100 + vpI; RETURN;
            END_IF;
        END_FOR;
    END_IF;

    (*--- 冲击 ChestImpact（iErrAxis=AXIS_ID_CHEST=1） ---*)
    IF HMI.Condition.Param.ChestImpact.bEnabled THEN
        IF (HMI.Condition.Param.ChestImpact.iSegmentCount < 1) OR
           (HMI.Condition.Param.ChestImpact.iSegmentCount > 16) THEN
            FC_ValidateParams := FALSE; iErrCode := PARAM_ERR_SEGMENT; iErrAxis := AXIS_ID_CHEST; iErrField := 1; RETURN;
        END_IF;
        IF HMI.Condition.Param.ChestImpact.rAcc <= 0.0 THEN
            FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_CHEST; iErrField := 2; RETURN;
        END_IF;
        IF HMI.Condition.Param.ChestImpact.rDec <= 0.0 THEN
            FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_CHEST; iErrField := 3; RETURN;
        END_IF;
        IF (HMI.Condition.Param.ChestImpact.iCycleModeLen < 1) OR
           (HMI.Condition.Param.ChestImpact.iCycleModeLen > 16) THEN
            FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_CHEST; iErrField := 4; RETURN;
        END_IF;
        FOR vpI := 1 TO HMI.Condition.Param.ChestImpact.iSegmentCount DO
            IF HMI.Condition.Param.ChestImpact.arVelocity[vpI] <= 0.0 THEN
                FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_CHEST; iErrField := 100 + vpI; RETURN;
            END_IF;
        END_FOR;
    END_IF;

    (*--- 全局字段（iErrAxis=0） ---*)
    IF HMI.Condition.Param.diBatchCount < 1 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 10; RETURN;
    END_IF;
    IF HMI.Condition.Param.diBatchInterval < 0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 11; RETURN;
    END_IF;
    IF HMI.Condition.Param.diTotalTimeout <= 0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 12; RETURN;
    END_IF;
    IF HMI.Condition.Param.iCycleCount < 1 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 13; RETURN;
    END_IF;
    IF (HMI.Condition.Param.iSignalMode < 0) OR (HMI.Condition.Param.iSignalMode > 1) THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 14; RETURN;
    END_IF;

(*==========================================================================
  iBlock = 2：推杆配置（iErrAxis=AXIS_ID_TAIL=4）
  ==========================================================================*)
ELSIF iBlock = 2 THEN
    IF HMI.TailTilt.Config.rMaxDeg <= HMI.TailTilt.Config.rMinDeg THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_TAIL; iErrField := 1; RETURN;
    END_IF;
    IF HMI.TailTilt.Config.rTolerance <= 0.0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_TAIL; iErrField := 2; RETURN;
    END_IF;
    IF HMI.TailTilt.Config.diTimeout <= 0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_TAIL; iErrField := 3; RETURN;
    END_IF;
    IF HMI.TailTilt.Config.diStallTimeout <= 0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_TAIL; iErrField := 4; RETURN;
    END_IF;
    IF HMI.TailTilt.Config.iMaxRetries < 0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_TAIL; iErrField := 5; RETURN;
    END_IF;
    IF HMI.TailTilt.Config.rStallThreshold <= 0.0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_TAIL; iErrField := 6; RETURN;
    END_IF;
    IF HMI.TailTilt.Config.rMinTravel < 0.0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_TAIL; iErrField := 7; RETURN;
    END_IF;
    IF (HMI.TailTilt.Config.rInitialPosition < HMI.TailTilt.Config.rMinDeg) OR
       (HMI.TailTilt.Config.rInitialPosition > HMI.TailTilt.Config.rMaxDeg) THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_TAIL; iErrField := 8; RETURN;
    END_IF;
    IF HMI.TailTilt.Config.diReverseDelay < 0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := AXIS_ID_TAIL; iErrField := 9; RETURN;
    END_IF;

(*==========================================================================
  iBlock = 3/4/5：单轴 Config（Chest=1 / Leg=2 / Seat=3）
  ==========================================================================*)
ELSIF (iBlock = 3) OR (iBlock = 4) OR (iBlock = 5) THEN
    IF iBlock = 3 THEN
        vpCfg := HMI.ChestImpact.Config;  iErrAxis := AXIS_ID_CHEST;
    ELSIF iBlock = 4 THEN
        vpCfg := HMI.LegAngle.Config;     iErrAxis := AXIS_ID_LEG;
    ELSE
        vpCfg := HMI.SeatTwist.Config;    iErrAxis := AXIS_ID_SEAT;
    END_IF;

    IF vpCfg.rPosLimit <= vpCfg.rNegLimit THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrField := 1; RETURN;
    END_IF;
    IF vpCfg.rTolerance <= 0.0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrField := 2; RETURN;
    END_IF;
    IF vpCfg.rMaxVel <= 0.0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrField := 3; RETURN;
    END_IF;
    IF vpCfg.rMinVel < 0.0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrField := 4; RETURN;
    END_IF;
    IF vpCfg.rMaxVel <= vpCfg.rMinVel THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrField := 5; RETURN;
    END_IF;
    IF vpCfg.rMaxAcc <= 0.0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrField := 6; RETURN;
    END_IF;
    IF vpCfg.rMaxDec <= 0.0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrField := 7; RETURN;
    END_IF;
    IF vpCfg.diPulsePerDeg <= 0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrField := 8; RETURN;
    END_IF;
    IF vpCfg.diTimeout <= 0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrField := 9; RETURN;
    END_IF;
    IF (vpCfg.rInitPos < vpCfg.rNegLimit) OR (vpCfg.rInitPos > vpCfg.rPosLimit) THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrField := 10; RETURN;
    END_IF;

(*==========================================================================
  iBlock = 6：回零参数（iErrAxis=0 全局）
  ==========================================================================*)
ELSIF iBlock = 6 THEN
    IF HMI.HomingParams.Params.rLimitEscapeVel <= 0.0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 1; RETURN;
    END_IF;
    IF HMI.HomingParams.Params.rChestJogVel <= 0.0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 2; RETURN;
    END_IF;
    IF HMI.HomingParams.Params.rLegJogVel <= 0.0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 3; RETURN;
    END_IF;
    IF HMI.HomingParams.Params.rSeatJogVel <= 0.0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 4; RETURN;
    END_IF;
    IF HMI.HomingParams.Params.rChestCrawlVel <= 0.0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 5; RETURN;
    END_IF;
    IF HMI.HomingParams.Params.rLegCrawlVel <= 0.0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 6; RETURN;
    END_IF;
    IF HMI.HomingParams.Params.rSeatCrawlVel <= 0.0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 7; RETURN;
    END_IF;
    IF HMI.HomingParams.Params.rAntiPinchTorqueLimit <= 0.0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 8; RETURN;
    END_IF;
    IF HMI.HomingParams.Params.diHomingTimeout <= 0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 9; RETURN;
    END_IF;
    IF HMI.HomingParams.Params.diEmergencyTimeout <= 0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 10; RETURN;
    END_IF;
    IF HMI.HomingParams.Params.diLimitEscapeTimeout <= 0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 11; RETURN;
    END_IF;
    IF HMI.HomingParams.Params.diStopReleaseTimeout <= 0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 12; RETURN;
    END_IF;
    IF HMI.HomingParams.Params.diEmergencyStallTimeout <= 0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 13; RETURN;
    END_IF;
    IF HMI.HomingParams.Params.iMaxRetry < 0 THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 14; RETURN;
    END_IF;
    (*--- 爬行速度必须低于 Jog 速度（四段式减速逻辑前提） ---*)
    IF HMI.HomingParams.Params.rChestCrawlVel >= HMI.HomingParams.Params.rChestJogVel THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 15; RETURN;
    END_IF;
    IF HMI.HomingParams.Params.rLegCrawlVel >= HMI.HomingParams.Params.rLegJogVel THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 16; RETURN;
    END_IF;
    IF HMI.HomingParams.Params.rSeatCrawlVel >= HMI.HomingParams.Params.rSeatJogVel THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 17; RETURN;
    END_IF;
    (*--- 接近区/迟滞必须为正 ---*)
    IF (HMI.HomingParams.Params.rChestApproachZone <= 0.0) OR
       (HMI.HomingParams.Params.rLegApproachZone   <= 0.0) OR
       (HMI.HomingParams.Params.rSeatApproachZone  <= 0.0) THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 18; RETURN;
    END_IF;
    IF (HMI.HomingParams.Params.rChestHysteresis <= 0.0) OR
       (HMI.HomingParams.Params.rLegHysteresis   <= 0.0) OR
       (HMI.HomingParams.Params.rSeatHysteresis  <= 0.0) THEN
        FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 19; RETURN;
    END_IF;

ELSE
    (* 未知块号：直接拒绝 *)
    FC_ValidateParams := FALSE; iErrCode := ERR_PARAM_VALUE; iErrAxis := 0; iErrField := 0;
END_IF;

END_FUNCTION
