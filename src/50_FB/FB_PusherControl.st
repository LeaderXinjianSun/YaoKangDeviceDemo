(*============================================================================
  FB_PusherControl —— 尾板电推杆控制（开关型，HSC 位置 + 几何解算）P8 实现
  ----------------------------------------------------------------------------
  职责：点动/回零/原点标定/自动定位/手动 Preset；堵转与超时保护、换向缓冲、
        惯性补偿、软限位；bHomed 与 bCalibrated 解耦；未校准/参考无效禁自动
        定位（报 3024）。
  位置反馈（真实推杆，无 AD）：开关型电推杆 Y5/Y6 正反转，位置由 HC_Counter
        高速计数器读得，单位 mm（rPosMm，INPUT_ADAPTER 采集自 Axis_推杆）。
        角度由几何解算（算法蓝本：推杆轴控制方式.txt）：
          倾斜长度_1 = 倾斜零位偏置(PUSHER_GEO_TILT0_MM) + 当前位置(mm)，钳 >=0；
          cosC = (垂直² + 平行² − 倾斜_1²) / (2·垂直·平行)，cosC 钳到 [-1,1]；
          当前角度 = 180 − PUSHER_GEO_FIX_ANG(72.6) − ACOS(cosC)·180/π
                     + PUSHER_GEO_ANG_COMP。
        几何常量全部在 GVL_CONST（现场实测标定），不在运行区参数。
  方向约定：bRunUp = 角度增大（几何上倾斜边变短/推杆收回方向，由 OUTPUT_ADAPTER
        的 bInvertPusherDirection 与物理 Y5/Y6 对齐）；原点 = 角度 rHomePosition。
  时间基准：全部按扫描周期 10ms，用 diScanCount 差值计时（ms = 扫数×10）。
    （H5U 内联 TONR 为累计型无复位端、跨步骤残留，故本 FB 不用 TONR。）
  输出：bRunUp/bRunDown 为请求位，OUTPUT_ADAPTER 转写 Q_Pusher_Up(Y5)/
        Q_Pusher_Down(Y6)，bInvertPusherDirection 在 OUTPUT_ADAPTER 交换。
  故障：bFaultEvent 单扫脉冲 + iFaultCode/iFaultLevel，OUTPUT_ADAPTER 序列化
        提交（SRC_PUSHER）；Critical 锁存进 iStep=90，需 bResetError 退出。
  ⚠ 待标定：GVL_CONST 几何长度/补偿（占位）现场实测；角度°阈值在运行区参数。
==========================================================================*)
FUNCTION_BLOCK FB_PusherControl
VAR_INPUT
    bEnable       : BOOL;            (* 使能（电平） *)
    bJogUp        : BOOL;            (* 上行点动（电平） *)
    bJogDown      : BOOL;            (* 下行点动（电平） *)
    bHome         : BOOL;            (* 回零：移动到原点角度 rHomePosition（脉冲触发） *)
    bCalibrate    : BOOL;            (* 原点标定（脉冲） *)
    bAutoMove     : BOOL;            (* 自动定位到 rTargetAngle（脉冲） *)
    bManualPreset : BOOL;            (* 手动清零/预设（脉冲） *)
    bResetError   : BOOL;            (* 重置故障（脉冲） *)
    bStop         : BOOL;            (* 停止（脉冲） *)
    rTargetAngle  : REAL;            (* 目标角度 (°)，与 stMotion.rTargetAngle 同源 *)
    bHomeSwitch   : BOOL;            (* 原点传感器（去抖后 ioPusherOrigin，X5） *)
    rPosMm        : REAL;            (* 当前推杆位置（mm，HC_Counter.Position） *)
    bPosValid     : BOOL;            (* 位置有效（HC_Counter.Valid 且无 Error） *)
    bSafetyStop   : BOOL;            (* 安全链停车（硬/软急停） *)
    stConfig      : Stru_PusherLimitConfig;  (* 运行区推杆参数 runPusher（°单位） *)
    stMotion      : Stru_PusherMotion;       (* Motion（rManualPresetAngle/diMoveTimeout…） *)
    bCalibRetain  : BOOL;            (* 推杆标定 Retain（retainTailZeroComm，P9 写入） *)
END_VAR
VAR_OUTPUT
    bRunUp        : BOOL;            (* 请求上行（→ OUTPUT_ADAPTER → Q_Pusher_Up） *)
    bRunDown      : BOOL;            (* 请求下行 *)
    bBusy         : BOOL;
    bDone         : BOOL;            (* 完成脉冲（本扫） *)
    bHomed        : BOOL;            (* 已回零（与标定解耦） *)
    bCalibrated   : BOOL;            (* 已校准 *)
    bReferenceValid: BOOL;           (* 坐标参考有效 *)
    bError        : BOOL;
    iErrorCode    : INT;             (* 业务错误码（5001/5002/5003/3xxx） *)
    rCurrAngle    : REAL;            (* 当前角度（°） *)
    stStatus      : Stru_PusherStatus;  (* 状态全量回填 HMI.TailTilt.Status *)
    bFaultEvent   : BOOL;            (* 故障提交脉冲（本扫，OUTPUT_ADAPTER 序列化） *)
    iFaultLevel   : INT;             (* 故障级别 1=Warning 2=Critical *)
    bCalibDone    : BOOL;            (* 标定成功脉冲（本扫，P9 建零门控消费） *)
END_VAR
VAR
    (* --- 状态机步号（字面整数 + 行尾注释，遵守 H5U 约定） --- *)
    iStep         : INT;             (* 0空闲 1标定下行脱离 2标定上行找原点 3标定去抖
                                        5标定下行反找 11通用换向缓冲 21定位接近
                                        22堵转换向缓冲 23停车滑行校验 90错误 *)
    iRetryCount   : INT;             (* 重试计数（找原点/定位共用） *)
    iNextStep     : INT;             (* 换向缓冲后的目标步 *)
    iHomeFlow     : INT;             (* 流程标记：0=自动定位 1=上行找原点 2=下行找原点 3=定位回零 *)

    (* --- 位置/速度（HC_Counter mm 位置 → 几何解算角度，单位 °/mm） --- *)
    rTilt1        : REAL;            (* 倾斜长度_1（mm）= PUSHER_GEO_TILT0_MM + rPosMm，钳>=0 *)
    rCosC         : REAL;            (* 余弦定理 cosC，钳[-1,1] 后喂 ACOS *)
    rSpeed        : REAL;            (* 速度 °/s（几何角度定时差分） *)
    rTarget       : REAL;            (* 本次定位目标角度 *)
    diSpdSnap     : DINT;            (* 速度采样快照（扫） *)
    rSpdRefAngle  : REAL;            (* 速度采样参考角度 *)

    (* --- 计时（diScanCount 差值，毫秒 = (差)×10） --- *)
    diStepSnap    : DINT;            (* 本步起始扫描快照 *)
    diFlowSnap    : DINT;            (* 流程（标定全局/定位）起始快照 *)
    diStallRef    : DINT;            (* 堵转判定参考快照 *)
    rStallRefAng  : REAL;            (* 堵转判定参考角度 *)
    rFlowStartAng : REAL;            (* 流程起始角度（最小行程判定） *)
    bMoving       : BOOL;            (* 本扫有运动输出（上/下行） *)
    bLastMoving   : BOOL;            (* 上扫有运动输出（堵转判定用） *)
    bStallNow     : BOOL;            (* 本扫堵转成立（位置有效，超时+位移/速度趋零） *)

    (* --- 锁存/边沿 --- *)
    bStallLat     : BOOL;            (* 堵转锁存（stStatus.bStall） *)
    bTimeoutLat   : BOOL;            (* 超时锁存（stStatus.bTimeout） *)
    rEnable       : TRIG.R_TRIG;     (* 使能上升沿 *)
    rHomeSw       : TRIG.R_TRIG;     (* 原点传感器上升沿 *)

    (* --- 原点传感器卡死诊断（§6.4；空闲/点动期背景监护，流程期由 31xx 覆盖） --- *)
    bStuckOnLat   : BOOL;            (* 卡死ON 锁存 → stStatus.bHomeSensorStuckOn *)
    bStuckOffLat  : BOOL;            (* 卡死OFF 锁存 → stStatus.bHomeSensorStuckOff *)
    diStuckSnap   : DINT;            (* 卡死判定快照：下行持续/上行累计起点 *)
    diUpAccum     : DINT;            (* 有效上行运动累计扫数（点动） *)
END_VAR

(*==========================================================================
  1) 每扫默认输出与边沿
==========================================================================*)
bFaultEvent := FALSE;
bCalibDone  := FALSE;
bDone       := FALSE;
bLastMoving := bRunUp OR bRunDown;
bMoving     := FALSE;

rEnable(CLK := bEnable);
rHomeSw(CLK := bHomeSwitch);

(*==========================================================================
  2) 几何解算：HC_Counter mm 位置 → 余弦定理/ACOS → 当前角度（°）
     倾斜_1 = PUSHER_GEO_TILT0_MM + rPosMm（钳>=0）；
     cosC   = (垂直² + 平行² − 倾斜_1²) / (2·垂直·平行)，cosC 钳[-1,1] 防 ACOS 越界；
     角度   = 180 − PUSHER_GEO_FIX_ANG − ACOS(cosC)·180/π + PUSHER_GEO_ANG_COMP。
     位置无效（bPosValid=FALSE）时保持上一拍角度/速度（反馈掉线不跳变）。
==========================================================================*)
IF bPosValid THEN
    rTilt1 := PUSHER_GEO_TILT0_MM + rPosMm;
    IF rTilt1 < 0.0 THEN
        rTilt1 := 0.0;
    END_IF;
    rCosC := (PUSHER_GEO_VERT_MM*PUSHER_GEO_VERT_MM
            + PUSHER_GEO_PAR_MM *PUSHER_GEO_PAR_MM
            - rTilt1*rTilt1)
            / (2.0*PUSHER_GEO_VERT_MM*PUSHER_GEO_PAR_MM);
    IF rCosC > 1.0 THEN
        rCosC := 1.0;
    ELSIF rCosC < -1.0 THEN
        rCosC := -1.0;
    END_IF;
    rCurrAngle := 180.0 - PUSHER_GEO_FIX_ANG
                - ACOS(rCosC)*180.0/PUSHER_PI + PUSHER_GEO_ANG_COMP;

    (* 速度估算：每 100ms（10 扫）角度差分，°/s *)
    IF (diScanCount - diSpdSnap) >= 10 THEN
        rSpeed       := (rCurrAngle - rSpdRefAngle) /
                        (DINT_TO_REAL(diScanCount - diSpdSnap) * 0.01);
        diSpdSnap    := diScanCount;
        rSpdRefAngle := rCurrAngle;
    END_IF;
END_IF;

(*==========================================================================
  3) 堵转参考维护 + 判定（每扫；基于上扫运动状态，位置有效时有效）
     运动中位移超过阈值即刷新参考（未堵转）；走过 rMinTravel 后，位移与速度
     同时趋零且持续 diStallTimeout → bStallNow。（阈值均为 °，直接取 stConfig）
==========================================================================*)
bStallNow := FALSE;
IF bPosValid AND bLastMoving THEN
    IF ABS(rCurrAngle - rStallRefAng) > stConfig.rStallThreshold THEN
        diStallRef   := diScanCount;
        rStallRefAng := rCurrAngle;
    END_IF;
    IF (ABS(rCurrAngle - rFlowStartAng) >= stConfig.rMinTravel)
       AND ((diScanCount - diStallRef) * 10 >= stConfig.diStallTimeout)
       AND (ABS(rCurrAngle - rStallRefAng) < stConfig.rStallThreshold)
       AND (ABS(rSpeed) < stConfig.rStallSpeedThreshold) THEN
        bStallNow := TRUE;
    END_IF;
END_IF;

(*==========================================================================
  4) 安全 / 失使能 / 停止 —— 无条件中止一切流程，断输出
==========================================================================*)
IF bSafetyStop OR (NOT bEnable) THEN
    bRunUp   := FALSE;
    bRunDown := FALSE;
    IF iStep <> 0 THEN
        iStep       := 0;
        iRetryCount := 0;
        iHomeFlow   := 0;
    END_IF;
    (* 安全停车保持已锁存故障；失使能仅停流程不清故障 *)

ELSIF bStop THEN
    (* 推杆停止脉冲：断输出回空闲（不清除故障锁存） *)
    bRunUp      := FALSE;
    bRunDown    := FALSE;
    iStep       := 0;
    iRetryCount := 0;
    iHomeFlow   := 0;

ELSE

(*==========================================================================
  5) 主状态机（CASE 标签为字面整数，行尾注释）
==========================================================================*)
CASE iStep OF

    0:  (* 空闲：命令分发 / 点动 *)
        bRunUp   := FALSE;
        bRunDown := FALSE;
        IF bResetError THEN
            bError        := FALSE;
            iErrorCode    := 0;
            bStallLat     := FALSE;
            bTimeoutLat   := FALSE;
            bStuckOnLat   := FALSE;
            bStuckOffLat  := FALSE;
            diStuckSnap   := 0;
            diUpAccum     := 0;
            iRetryCount   := 0;
        END_IF;

        IF bManualPreset THEN
            (* 手动预设：几何角度为绝对解算（无运行时偏置可设），仅置参考/标定有效；
               操作员确认当前在 rManualPresetAngle 位姿，位置与角度由 HSC+几何提供 *)
            bCalibrated    := TRUE;
            bReferenceValid:= TRUE;
            bHomed         := TRUE;
            bDone          := TRUE;

        ELSIF bCalibrate THEN
            IF bError THEN
                (* 故障态拒绝重新标定，需先 ResetError *)
            ELSIF bHomeSwitch THEN
                (* 启动时原点已压下：先下行脱离 *)
                iStep     := 1;
                iHomeFlow := 2;
            ELSE
                (* 默认上行找原点 *)
                iStep     := 2;
                iHomeFlow := 1;
            END_IF;
            iRetryCount  := 0;
            diFlowSnap   := diScanCount;
            diStepSnap   := diScanCount;
            diStallRef   := diScanCount;
            rStallRefAng := rCurrAngle;
            rFlowStartAng:= rCurrAngle;

        ELSIF bHome THEN
            IF NOT bReferenceValid THEN
                (* 无参考：走标定式找原点 *)
                IF bHomeSwitch THEN
                    iStep := 1; iHomeFlow := 2;
                ELSE
                    iStep := 2; iHomeFlow := 1;
                END_IF;
            ELSE
                (* 有参考：定位到原点角度 rHomePosition *)
                rTarget   := stConfig.rHomePosition;
                iStep     := 21;
                iHomeFlow := 3;
            END_IF;
            iRetryCount  := 0;
            diFlowSnap   := diScanCount;
            diStepSnap   := diScanCount;
            diStallRef   := diScanCount;
            rStallRefAng := rCurrAngle;
            rFlowStartAng:= rCurrAngle;

        ELSIF bAutoMove THEN
            IF NOT (bCalibrated AND bReferenceValid) THEN
                (* 3024：未校准/参考无效，禁自动定位（Warning 拒绝，不锁死） *)
                iErrorCode  := ERR_TAIL_NOT_CALIB;
                bFaultEvent := TRUE;
                iFaultLevel := 1;
            ELSIF (rTargetAngle < stConfig.rMinDeg) OR (rTargetAngle > stConfig.rMaxDeg) THEN
                (* 3025：目标越软限位（Critical 锁存） *)
                iErrorCode  := ERR_TAIL_ANGLE_LIMIT;
                bFaultEvent := TRUE;
                iFaultLevel := 2;
                bError      := TRUE;
                iStep       := 90;
            ELSE
                rTarget      := rTargetAngle;
                iStep        := 21;
                iHomeFlow    := 0;
                iRetryCount  := 0;
                diFlowSnap   := diScanCount;
                diStepSnap   := diScanCount;
                diStallRef   := diScanCount;
                rStallRefAng := rCurrAngle;
                rFlowStartAng:= rCurrAngle;
            END_IF;

        ELSIF bJogUp AND NOT bJogDown THEN
            IF rCurrAngle < stConfig.rMaxDeg THEN
                bRunUp  := TRUE;
                bMoving := TRUE;
            END_IF;

        ELSIF bJogDown AND NOT bJogUp THEN
            IF rCurrAngle > stConfig.rMinDeg THEN
                bRunDown:= TRUE;
                bMoving := TRUE;
            END_IF;
        END_IF;

    1:  (* 标定：下行脱离原点（原点已压下启动） *)
        bRunDown := TRUE; bMoving := TRUE; bRunUp := FALSE;
        IF NOT bHomeSwitch THEN
            (* 已脱离：换向缓冲后上行精找 *)
            bRunDown   := FALSE;
            iNextStep  := 2;
            iHomeFlow  := 1;
            iStep      := 11;
            diStepSnap := diScanCount;
        ELSIF (diScanCount - diStepSnap) * 10 >= stConfig.diTimeout THEN
            (* 3103：下行脱离失败（原点不释放） *)
            iErrorCode := ERR_TAIL_CAL_ESCAPE; bFaultEvent := TRUE; iFaultLevel := 2;
            bError := TRUE; bRunUp := FALSE; bRunDown := FALSE; iStep := 90;
        END_IF;

    2:  (* 标定：上行找原点 *)
        bRunUp := TRUE; bMoving := TRUE; bRunDown := FALSE;
        IF rHomeSw.Q OR bHomeSwitch THEN
            (* 压到原点：30ms 去抖（3 扫） *)
            bRunUp     := FALSE;
            iStep      := 3;
            diStepSnap := diScanCount;
        ELSIF bStallNow THEN
            (* 上行撞顶/堵转：3101 信息性上报（Warning），换向下行反找 *)
            bRunUp     := FALSE;
            IF iRetryCount = 0 THEN
                iErrorCode  := ERR_TAIL_CAL_TOP;
                bFaultEvent := TRUE;
                iFaultLevel := 1;
            END_IF;
            iRetryCount := iRetryCount + 1;
            iNextStep   := 5;
            iHomeFlow   := 2;
            iStep       := 22;
            diStepSnap  := diScanCount;
        END_IF;

    3:  (* 标定：原点去抖 30ms（3 扫，须持续压合） *)
        bRunUp := FALSE; bRunDown := FALSE;
        IF NOT bHomeSwitch THEN
            (* 去抖期内抖动脱离：3104 原点不稳定（Critical，中止） *)
            iErrorCode := ERR_TAIL_CAL_DEBOUNCE; bFaultEvent := TRUE; iFaultLevel := 2;
            bError := TRUE; iStep := 90;
        ELSIF (diScanCount - diStepSnap) >= 3 THEN
            (* 去抖通过：几何绝对角度无运行时偏置，仅建立参考；
               3023：原点处几何角度与 rHomePosition 偏差超合理带（占位 5°+容差） *)
            IF ABS(rCurrAngle - stConfig.rHomePosition) >
               (stConfig.rTolerance + 5.0) THEN
                iErrorCode := ERR_TAIL_SENSOR_IMPL; bFaultEvent := TRUE; iFaultLevel := 2;
                bError := TRUE; iStep := 90;
            END_IF;
            IF NOT bError THEN
                bCalibrated    := TRUE;
                bReferenceValid:= TRUE;
                bHomed         := TRUE;
                bCalibDone     := TRUE;
                bDone          := TRUE;
                iErrorCode     := 0;   (* 清 3101 等历史 Warning，避免 bWarning 残留误显 *)
                (* 标定成功证明原点传感器本次可压合可释放：清卡死锁存与累计器 *)
                bStuckOnLat    := FALSE;
                bStuckOffLat   := FALSE;
                diStuckSnap    := 0;
                diUpAccum      := 0;
                iStep          := 0;
                iRetryCount    := 0;
                iHomeFlow      := 0;
            END_IF;
        END_IF;

    5:  (* 标定：下行反找原点（上行撞顶后的反向搜索） *)
        bRunDown := TRUE; bMoving := TRUE; bRunUp := FALSE;
        IF rHomeSw.Q OR bHomeSwitch THEN
            bRunDown   := FALSE;
            iStep      := 3;      (* 同样 30ms 去抖 *)
            diStepSnap := diScanCount;
        ELSIF bStallNow THEN
            bRunDown := FALSE;
            IF iRetryCount <= stConfig.iMaxRetries THEN
                (* 反向再试上行 *)
                iRetryCount := iRetryCount + 1;
                iNextStep   := 2;
                iHomeFlow   := 1;
                iStep       := 22;
                diStepSnap  := diScanCount;
            ELSE
                (* 3102：上行/反找均失败 *)
                iErrorCode := ERR_TAIL_CAL_HOME; bFaultEvent := TRUE; iFaultLevel := 2;
                bError := TRUE; iStep := 90;
            END_IF;
        END_IF;

    11: (* 通用换向缓冲（diReverseDelay） *)
        bRunUp := FALSE; bRunDown := FALSE;
        IF (diScanCount - diStepSnap) * 10 >= stConfig.diReverseDelay THEN
            iStep        := iNextStep;
            diStepSnap   := diScanCount;
            diStallRef   := diScanCount;
            rStallRefAng := rCurrAngle;
        END_IF;

    21: (* 定位：向 rTarget 接近（含惯性补偿提前停） *)
        IF rTarget > rCurrAngle + stConfig.rTolerance THEN
            bRunUp := TRUE; bMoving := TRUE; bRunDown := FALSE;
            (* 惯性补偿：距目标 ≤ rInertiaUp（°）提前停 *)
            IF (rTarget - rCurrAngle) <= stConfig.rInertiaUp THEN
                bRunUp := FALSE; bMoving := FALSE;
                iStep := 23; diStepSnap := diScanCount;
            END_IF;
        ELSIF rTarget < rCurrAngle - stConfig.rTolerance THEN
            bRunDown := TRUE; bMoving := TRUE; bRunUp := FALSE;
            (* 惯性补偿：距目标 ≤ rInertiaDown（°）提前停 *)
            IF (rCurrAngle - rTarget) <= stConfig.rInertiaDown THEN
                bRunDown := FALSE; bMoving := FALSE;
                iStep := 23; diStepSnap := diScanCount;
            END_IF;
        ELSE
            (* 已在容差内：直接进入滑行校验 *)
            bRunUp := FALSE; bRunDown := FALSE;
            iStep := 23; diStepSnap := diScanCount;
        END_IF;
        IF bMoving AND bStallNow THEN
            (* 定位途中堵转：换向缓冲后重试，超 iMaxRetries → 5003 *)
            bRunUp := FALSE; bRunDown := FALSE;
            bStallLat := TRUE;
            IF iRetryCount < stConfig.iMaxRetries THEN
                iRetryCount := iRetryCount + 1;
                iNextStep   := 21;
                iStep       := 22;
                diStepSnap  := diScanCount;
            ELSE
                iErrorCode := PUSHER_ERR_RETRY; bFaultEvent := TRUE; iFaultLevel := 2;
                bError := TRUE; iStep := 90;
            END_IF;
        END_IF;

    22: (* 堵转/换向缓冲（diReverseDelay 后回 iNextStep） *)
        bRunUp := FALSE; bRunDown := FALSE;
        IF (diScanCount - diStepSnap) * 10 >= stConfig.diReverseDelay THEN
            iStep        := iNextStep;
            diStepSnap   := diScanCount;
            diStallRef   := diScanCount;
            rStallRefAng := rCurrAngle;
        END_IF;

    23: (* 停车滑行校验（diStopCheck 后判到位） *)
        bRunUp := FALSE; bRunDown := FALSE;
        IF (diScanCount - diStepSnap) * 10 >= stConfig.diStopCheck THEN
            IF ABS(rCurrAngle - rTarget) <= stConfig.rTolerance THEN
                bDone       := TRUE;
                IF iHomeFlow = 3 THEN
                    bHomed := TRUE;      (* 仅回零流程置 bHomed *)
                END_IF;
                iStep       := 0;
                iRetryCount := 0;
                iHomeFlow   := 0;
            ELSIF iRetryCount < stConfig.iMaxRetries THEN
                (* 滑行后未到位：再接近 *)
                iRetryCount  := iRetryCount + 1;
                iStep        := 21;
                diStepSnap   := diScanCount;
                diStallRef   := diScanCount;
                rStallRefAng := rCurrAngle;
            ELSE
                (* 3107：回零/定位失败（重试超限仍未到位） *)
                iErrorCode := ERR_TAIL_HOME_FAILED; bFaultEvent := TRUE; iFaultLevel := 2;
                bError := TRUE; iStep := 90;
            END_IF;
        END_IF;

    90: (* 错误态：断输出，等 bResetError 回空闲 *)
        bRunUp := FALSE; bRunDown := FALSE;
        IF bResetError THEN
            bError        := FALSE;
            iErrorCode    := 0;
            bStallLat     := FALSE;
            bTimeoutLat   := FALSE;
            bStuckOnLat   := FALSE;
            bStuckOffLat  := FALSE;
            diStuckSnap   := 0;
            diUpAccum     := 0;
            iRetryCount   := 0;
            iStep         := 0;
            iHomeFlow     := 0;
        END_IF;

ELSE
    iStep := 0;
END_CASE;

(*==========================================================================
  6) 流程级监护
==========================================================================*)
(* 6.1 标定全局超时（步 1/2/3/5 期间，diTimeout → 3105） *)
IF (iStep = 1) OR (iStep = 2) OR (iStep = 3) OR (iStep = 5) THEN
    IF (diScanCount - diFlowSnap) * 10 >= stConfig.diTimeout THEN
        iErrorCode := ERR_TAIL_CAL_TIMEOUT; bFaultEvent := TRUE; iFaultLevel := 2;
        bError := TRUE; bTimeoutLat := TRUE;
        bRunUp := FALSE; bRunDown := FALSE; iStep := 90;
    END_IF;
END_IF;

(* 6.2 定位/回零超时（步 21/22/23，diMoveTimeout 缺省回退 diTimeout → 5002） *)
IF (iStep = 21) OR (iStep = 22) OR (iStep = 23) THEN
    (* diMoveTimeout>0 用运动参数，缺省回退 stConfig.diTimeout（IF 判定避开 SEL 参数顺序陷阱） *)
    IF ((stMotion.diMoveTimeout > 0) AND ((diScanCount - diFlowSnap) * 10 >= stMotion.diMoveTimeout))
       OR ((stMotion.diMoveTimeout <= 0) AND ((diScanCount - diFlowSnap) * 10 >= stConfig.diTimeout)) THEN
        iErrorCode := PUSHER_ERR_TIMEOUT; bFaultEvent := TRUE; iFaultLevel := 2;
        bError := TRUE; bTimeoutLat := TRUE;
        bRunUp := FALSE; bRunDown := FALSE; iStep := 90;
    END_IF;
END_IF;

(* 6.3 点动堵转（位置有效，空闲点动期间；流程内堵转已在各步处理 → 5001） *)
IF (iStep = 0) AND bMoving AND bStallNow THEN
    iErrorCode := PUSHER_ERR_STALL; bFaultEvent := TRUE; iFaultLevel := 2;
    bError := TRUE; bStallLat := TRUE;
    bRunUp := FALSE; bRunDown := FALSE; iStep := 90;
END_IF;

(* 6.4 原点传感器卡死诊断（3021 卡死ON / 3022 卡死OFF）
       流程期（标定/回零/定位）的传感器失效已由 3102/3103/3105 覆盖；本节做空闲/点动期
       背景监护：
         3021 卡死ON：有效下行脱离运动持续 diTimeout 而原点一直压合（应断开不开）。
                      下行 = 角度减小、脱离原点（见方向约定）；bJogDown 时 bRunDown 输出。
         3022 卡死OFF：有效上行运动累计达 diTimeout（中途若有一拍压合即清零，说明传感器
                      可达）却从未压合（应接通通不了）。需位置有效（几何角度提供位移参照；
                      位置无效时由流程期 3102/3105 兜底）。
       两锁存仅在标定成功（步3，证明传感器健康）或 bResetError 时清除；锁存置位当扫发
       bFaultEvent 单脉冲（自我边沿：仅 FALSE→TRUE 当扫）。 *)
IF iStep = 0 THEN
    (* 卡死ON：下行持续计数（要求有真实下行输出） *)
    IF bRunDown THEN
        IF bHomeSwitch AND (NOT bStuckOnLat) THEN
            IF diStuckSnap = 0 THEN
                diStuckSnap := diScanCount;
            END_IF;
            IF (diScanCount - diStuckSnap) * 10 >= stConfig.diTimeout THEN
                bStuckOnLat := TRUE;
                iErrorCode  := ERR_TAIL_SENSOR_STKON;
                bFaultEvent := TRUE; iFaultLevel := 2;
                bError      := TRUE; iStep := 90;
            END_IF;
        ELSE
            (* 传感器已释放（或已锁存）：脱离计时清零 *)
            diStuckSnap := 0;
        END_IF;
    ELSE
        diStuckSnap := 0;
    END_IF;

    (* 卡死OFF：上行运动累计（位置有效；传感器一旦压合即说明可达，清零） *)
    IF bPosValid AND bRunUp AND (NOT bStuckOffLat) THEN
        IF bHomeSwitch THEN
            diUpAccum := 0;
        ELSE
            diUpAccum := diUpAccum + 1;
            IF diUpAccum * 10 >= stConfig.diTimeout THEN
                bStuckOffLat := TRUE;
                iErrorCode   := ERR_TAIL_SENSOR_STKOFF;
                bFaultEvent  := TRUE; iFaultLevel := 2;
                bError       := TRUE; iStep := 90;
            END_IF;
        END_IF;
    ELSIF NOT bRunUp THEN
        (* 非上行扫不累计（点动间歇不影响）；置零由压合或复位处理 *)
        ;
    END_IF;
END_IF;

END_IF;   (* 第 4 节安全/停止 IF 的 ELSE 结束 *)

(*==========================================================================
  7) 上电从 Retain 恢复标定状态（使能上升沿）
==========================================================================*)
IF rEnable.Q AND bCalibRetain THEN
    bCalibrated    := TRUE;
    bReferenceValid:= TRUE;
END_IF;

(*==========================================================================
  8) 状态结构体回填（HMI.TailTilt.Status 全量）
==========================================================================*)
stStatus.rCurrAngle       := rCurrAngle;
stStatus.rCurrPosMm       := rPosMm;
stStatus.rPresetDeg       := stMotion.rManualPresetAngle;
stStatus.iErrorCode       := iErrorCode;
stStatus.iRetryCount      := iRetryCount;
stStatus.bCalibrated      := bCalibrated;
stStatus.bHomed           := bHomed;
stStatus.bHoming          := (iStep = 1) OR (iStep = 2) OR (iStep = 3) OR (iStep = 5);
stStatus.bHomeSwitch      := bHomeSwitch;
stStatus.bReferenceValid  := bReferenceValid;
stStatus.bHomeSensorStuckOn  := bStuckOnLat;
stStatus.bHomeSensorStuckOff := bStuckOffLat;
stStatus.bHomeSensorHealthy  := NOT (bStuckOnLat OR bStuckOffLat);
stStatus.bHomePlausible   := bReferenceValid AND NOT (bStuckOnLat OR bStuckOffLat);
stStatus.bRunUp           := bRunUp;
stStatus.bRunDown         := bRunDown;
stStatus.bBusy            := (iStep <> 0) OR bMoving;
stStatus.bDone            := bDone;
stStatus.bError           := bError;
stStatus.bWarning         := (iErrorCode = ERR_TAIL_NOT_CALIB) OR
                             (iErrorCode = ERR_TAIL_CAL_TOP);
stStatus.bStall           := bStallLat;
stStatus.bTimeout         := bTimeoutLat;
stStatus.bPosLimit        := rCurrAngle >= stConfig.rMaxDeg;
stStatus.bNegLimit        := rCurrAngle <= stConfig.rMinDeg;
stStatus.bAtInit          := bReferenceValid AND
                             (ABS(rCurrAngle - stConfig.rInitialPosition) <= stConfig.rTolerance);
stStatus.bSensorChecked   := bCalibrated;
stStatus.bAutoMovePending := FALSE;   (* 自动流程由 TASK_RUNNER 挂起，P10 落地 *)
stStatus.bAutoMoveAllowed := bCalibrated AND bReferenceValid AND NOT bError;

bBusy := stStatus.bBusy;

END_FUNCTION_BLOCK
