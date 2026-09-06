(*============================================================================
  FB_PusherControl —— 尾板电推杆控制（开关型，双参考模式）
  ----------------------------------------------------------------------------
  职责：点动/回零/原点标定/自动定位/手动 Preset/回初始位；堵转与超时保护、
        换向缓冲、惯性补偿；双参考 iReferenceMode：
          0 = 脉冲计数 + 原点传感器；1 = AD 三次拟合角度（rFitK0..K3）。
        bHomed 与 bCalibrated 解耦；未校准/参考无效禁自动定位（报 3024）。
  线结构体：HMI.TailTilt.Status/Cmd/Motion/Config/ConfigCmd（字段见 ST_StruHMI.st）。
  物理输出 Q_Pusher_Up/Q_Pusher_Down 经 OUTPUT_ADAPTER 单写；本 FB 出请求位。
  P1：接口骨架。P8：校准流程（3101–3107）、堵转 5001/超时 5002/重试 5003。
==========================================================================*)
FUNCTION_BLOCK FB_PusherControl
VAR_INPUT
    bEnable       : BOOL;            (* 使能 *)
    bJogUp        : BOOL;            (* 上行点动（电平） *)
    bJogDown      : BOOL;            (* 下行点动（电平） *)
    bHome         : BOOL;            (* 回零：移动到原点位置（脉冲） *)
    bCalibrate    : BOOL;            (* 原点标定（脉冲） *)
    bAutoMove     : BOOL;            (* 自动定位到 rTargetAngle（脉冲） *)
    bManualPreset : BOOL;            (* 手动清零/预设（脉冲） *)
    bResetError   : BOOL;            (* 重置故障（脉冲） *)
    bStop         : BOOL;            (* 停止 *)
    rTargetAngle  : REAL;            (* 目标角度 (°) *)
    iReferenceMode: INT;             (* 0=脉冲+原点  1=AD 拟合 *)
    bHomeSwitch   : BOOL;            (* 原点传感器（去抖后 ioPusherOrigin） *)
    diAdRaw       : DINT;            (* AD 原始值 *)
    bAdValid      : BOOL;            (* AD 有效 *)
    bSafetyStop   : BOOL;            (* 安全链停车 *)
END_VAR
VAR_OUTPUT
    bRunUp        : BOOL;            (* 请求上行（→ OUTPUT_ADAPTER → Q_Pusher_Up） *)
    bRunDown      : BOOL;            (* 请求下行 *)
    bBusy         : BOOL;
    bDone         : BOOL;
    bHomed        : BOOL;            (* 已回零（与标定解耦） *)
    bCalibrated   : BOOL;            (* 已校准 *)
    bReferenceValid: BOOL;           (* 坐标参考有效 *)
    bError        : BOOL;
    iErrorCode    : INT;             (* 5001 堵转 / 5002 超时 / 5003 重试超限 / 3024 未校准 *)
    rCurrAngle    : REAL;            (* 当前角度（°） *)
END_VAR
VAR
    iStep         : INT;
    iRetryCount   : INT;
    (* H5U 定时器为内联指令 TONR(IN:=,PT:=,Q=>布尔位)，无需 TON 实例：
       tStepTimer/tStallTimer 即 TONR 的 Q=> 输出 BOOL（定时到标志）。 *)
    tStepTimer    : BOOL;   (* 步序定时到（P8：TONR Q=>tStepTimer） *)
    tStallTimer   : BOOL;   (* 堵转定时到（P8：TONR Q=>tStallTimer） *)
END_VAR

(* TODO P8:
   - 角度源：模式 0 脉冲计数 × rPulsePerDeg；模式 1 AD 三次拟合 K0..K3 + 跳变保护。
   - 校准流程：默认上行找原点；已压原点→先下行脱离→缓冲 diReverseDelay→上行精找→
     30ms 去抖→清零；上行撞顶堵转→缓冲换向→下行反找；全局超时 diTimeout。
   - 堵转：走过 rMinTravel 后，速度趋零持续 diStallTimeout → 5001，换向缓冲后重试，
     超 iMaxRetries → 5003。
   - 自动定位前校验 bCalibrated/bReferenceValid，否则报 3024 拒绝。
   - 惯性补偿 rInertiaUp/Down、软限位 rMaxDeg/rMinDeg、到位容差 rTolerance。
   - 方向取反 bInvertPusherDirection 作用于输出请求位。
   - 状态位全量回写 HMI.TailTilt.Status（bHomeSensorHealthy/StuckOn/StuckOff/
     bHomePlausible/bSensorChecked/bAutoMovePending 等，P9 传感器诊断）。 *)
END_FUNCTION_BLOCK
