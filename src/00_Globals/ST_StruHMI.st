(*============================================================================
  HMI 线上结构体类型库 —— 寄存器布局契约
  ----------------------------------------------------------------------------
  权威来源：旧工程 InoProShop 变量表导出
    old/结构体/Stru_HMI_new.csv                     （主结构体，AT %MW200）
    old/结构体/Stru_HMI_DeviceInfo_new.csv          （设备信息镜像，AT %MW1000）
    old/结构体/Stru_HMI_DeviceIdentityWrite_new.csv （设备身份维护，AT %MW1010）

  ⚠ 铁律：类型名、字段名、字段顺序、数据类型、数组长度必须与 CSV 完全一致，
     一字不改。BOOL 按位打包、REAL/DINT 偶字对齐由编译器自动完成；
     本工程照抄定义并整体 AT 映射后，布局即与旧工程/HMI 完全相同。
  验收：下载后 InoProShop 变量表中 HMI 的 nBitLen 应 = 11856 bit（741 字，
        D200–D940），与旧工程一致。
==========================================================================*)


(*---------------------------------------------------------------------------
  通用命令：参数块统一操作集（Load/Apply/Save/ResetDefault + 回令）
  出现位置：Condition.ParamCmd / TailTilt.ConfigCmd / 3×Axis.ConfigCmd / HomingParams.Cmd
---------------------------------------------------------------------------*)
TYPE Stru_ConfigCmd :
STRUCT
    iErrorCode      : INT;      // 操作错误
    bLoad           : BOOL;     // 加载：从运行区读到缓冲区
    bApply          : BOOL;     // 应用：缓冲区覆盖运行区
    bSave           : BOOL;     // 保存：运行区写入 Retain
    bResetDefault   : BOOL;     // 恢复工厂默认
    bSuccess        : BOOL;     // 操作成功（PLC→HMI 回令）
    bError          : BOOL;     // 操作失败（只读，PLC→HMI 回令）
    bPad0           : BOOL;     // 填充
    bPad1           : BOOL;     // 对齐填充
END_STRUCT
END_TYPE


(*---------------------------------------------------------------------------
  调理区（Condition）
---------------------------------------------------------------------------*)
TYPE Stru_CondCmd :
STRUCT
    S1_StartProcess     : BOOL;     // 启动流程 (电平，CSV 注释；PLC 侧按 R_TRIG 消费亦安全)
    S2_StartChengJiao   : BOOL;     // 开始成角 (脉冲)
    S3_AllowSignal      : BOOL;     // 确认信号 (脉冲)
    bStop               : BOOL;     // 停止 (脉冲)
    bSignal             : BOOL;     // 脚踏信号 (脉冲/电平)
    bReset              : BOOL;     // 复位错误 (脉冲)
    bPause              : BOOL;     // 暂停
    bResume             : BOOL;     // 恢复
    bSkipAngle          : BOOL;     // 跳过成角 (脉冲, v3.16)
    bPpad               : BOOL[7];  // 填充（字段名照抄 CSV：bPpad）
END_STRUCT
END_TYPE


(* 单轴往复运动参数（SeatTwist / LegAngle / ChestImpact 三处复用） *)
TYPE Stru_ReciprocationSettings :
STRUCT
    arPosition      : REAL[16];    // 各段目标位置
    arVelocity      : REAL[16];    // 各段速度
    rAcc            : REAL;        // 加速度（必须 > 0）
    rDec            : REAL;        // 减速度（必须 > 0）
    rInitialPosition: REAL;        // 初始位置
    rReserved       : REAL;        // 保留
    iVelocityMode   : INT;         // 速度切换模式 0=独立速度 1=统一用 arVelocity[0]
    iCycleModeLen   : INT;         // 方向数组 abCycleMode 有效长度 (1~16)
    iCycleCount     : INT;         // 本轴循环次数，-1=用全局值
    iSignalMode     : INT;         // 本轴信号模式，-1=用全局值，0=点动 1=连动
    iSegmentCount   : INT;         // 运动段数 (1~16)，必须 >0 否则报错 1005
    iPadInt         : INT;         // 对齐填充
    bEnabled        : BOOL;        // 轴使能（FALSE=不参与联动，用于 2 轴场景）
    bOneWay         : BOOL;        // 单向还是多向
    abCycleMode     : BOOL[16];    // 方向数组
    bPad0           : BOOL;        // 填充
    bPad1           : BOOL;        // 对齐填充
END_STRUCT
END_TYPE


TYPE Stru_CondParams :
STRUCT
    SeatTwist       : Stru_ReciprocationSettings;   // 扭腰往复（线上顺序 Seat→Leg→Chest）
    LegAngle        : Stru_ReciprocationSettings;   // 摆腿往复
    ChestImpact     : Stru_ReciprocationSettings;   // 冲击往复
    rPusherPos      : REAL;        // 成角角度（尾板目标角度，度）
    rPusherInitPos   : REAL;        // 尾板初始角度
    diBatchCount    : DINT;        // 完整调理流程重复次数（老化模式）
    diBatchInterval : DINT;        // 批次间隔时间 (ms，老化模式)
    diTotalTimeout  : DINT;        // 总超时 (ms，默认 300000)
    diConfirmTimeout: DINT;        // HMI 等待确认超时 (ms，<=0=禁用)
    iCycleCount     : INT;         // 全局循环次数
    iSignalMode     : INT;         // 全局信号模式 (0=脚踏 1=自动)
END_STRUCT
END_TYPE


TYPE Stru_CondStatus :
STRUCT
    diActRunTime        : DINT;    // 实际运行时间 (ms，含暂停)
    diBatchCurrent      : DINT;    // 已完成批次数（老化）
    diBatchTarget       : DINT;    // 目标批次数（老化）
    diBatchRemainTime   : DINT;    // 批次间隔剩余时间 (ms)
    iPhase              : INT;     // 调理阶段 (0=空闲 1=预备 2=运行 3=成角 9=完成)
    iStep               : INT;     // 当前步骤（阶段内细分）
    iCurrentCycle       : INT;     // 当前循环次数
    iTargetCycles       : INT;     // 目标循环次数
    iErrorCode          : INT;     // 错误码
    iErrorLevel         : INT;     // 错误等级 0=L0 1=L1 2=L2
    iParamError         : INT;     // 参数验证错误码
    iParamErrorAxis     : INT;     // 参数错误所在轴 (1=Chest 2=Leg 3=Seat 4=Tail)
    iParamErrorField    : INT;     // 错误字段索引
    pad_int             : INT;     // 对齐填充
    bRunning            : BOOL;    // 调理进行中
    bDone               : BOOL;    // 调理已完成
    bPaused             : BOOL;    // 暂停中
    bError              : BOOL;    // 错误激活
    bBusy               : BOOL;    // 任意动作进行中
    bWaitingAngle       : BOOL;    // 等待成角
    bHoming             : BOOL;    // 回零中
    bAngleDone          : BOOL;    // 成角已完成
    bWaitingSignal      : BOOL;    // 等待脚踏信号
    bMoving             : BOOL;    // 往复动作中
    bHomeDone           : BOOL;    // 回零完成
    bManualStop         : BOOL;    // 手动停止
    bEmergencyStop      : BOOL;    // 紧急中止
    bParamValid         : BOOL;    // 参数校验通过
    bApplyDone          : BOOL;    // 参数应用完成
    bResetDone          : BOOL;    // 调理复位完成
    bBatchDone          : BOOL;    // 批量运行完成（老化）
END_STRUCT
END_TYPE


TYPE Stru_HMI_Condition :
STRUCT
    Cmd     : Stru_CondCmd;        // 调理命令
    Param   : Stru_CondParams;     // 调理参数（线上编辑区）
    Status  : Stru_CondStatus;     // 调理状态（PLC→HMI）
    ParamCmd: Stru_ConfigCmd;      // 参数块操作命令
END_STRUCT
END_TYPE


(*---------------------------------------------------------------------------
  系统区（Sys）
---------------------------------------------------------------------------*)
TYPE Stru_HMI_SysCmd :
STRUCT
    iWorkMode               : INT;
    iResetMode              : INT;
    iHomingMode             : INT;
    iUserRole               : INT;
    iAuthCode               : INT;
    arReservedInt           : INT[2];
    bServiceModeReq         : BOOL;
    bHomingReq              : BOOL;
    bStopReq                : BOOL;
    bPause                  : BOOL;
    bResume                 : BOOL;
    bAutoStartReq           : BOOL;
    bCalibrateReq           : BOOL;
    bResetReq               : BOOL;
    bAckErrorReq            : BOOL;
    bEmergencyStopReq       : BOOL;
    bInitializeReq          : BOOL;
    bServiceMechHomeReq     : BOOL;
    bSelfTestConfirm        : BOOL;
    bSelfTestSkip           : BOOL;
    bAllPowerOffReq         : BOOL;
    bAllPowerOnReq          : BOOL;
    bRevalidateParams       : BOOL;
    bServiceAuthConfirm     : BOOL;
    bNoLoadConfirm          : BOOL;
    bStartSelfTestReq       : BOOL;
    bServiceDoneReq         : BOOL;
    bReadyCheckReq          : BOOL;
    bQuickStartReq          : BOOL;
    bForceSkipSelfTestReq   : BOOL;
    bClearZeroRetainReq     : BOOL;
    bLearnImpactBiasReq     : BOOL;
    bPadHmi0                : BOOL;
END_STRUCT
END_TYPE


TYPE Stru_HMI_SysDisplay :
STRUCT
    rTailDriftPulse         : REAL;
    diUpTime                : DINT;
    diReadyCheckResult      : DINT;
    iState                  : INT;
    iPhase                  : INT;
    iInitErrorCode          : INT;
    iErrorCode              : INT;
    iErrorSubCode           : INT;
    iErrorLevel             : INT;
    iErrorSource            : INT;
    iHealthLevel            : INT;
    iTaskPhase              : INT;
    iBlockReason            : INT;
    iWorkMode               : INT;
    iPadInt                 : BOOL;     // CSV 中该字段类型为 BOOL，照抄
    bInitialized            : BOOL;
    bParamInitialized       : BOOL;
    bAutoProcessRunning     : BOOL;
    bPowerOn                : BOOL;
    bPoweringUp             : BOOL;
    bNeedReset              : BOOL;
    bTailSensorAtBoot       : BOOL;
    bHealthCheckSkipped     : BOOL;
    bAllAxesReferenced      : BOOL;
    bAllAxesHomed           : BOOL;
    bAllAxesAtInit          : BOOL;
    bAllAxesIdle            : BOOL;
    bAnyAxisAtLimit         : BOOL;
    bReady                  : BOOL;
    bSafeToStart            : BOOL;
    bBusy                   : BOOL;
    bParamError             : BOOL;
    bAbsPositionValid       : BOOL;
    bSensitiveRunning       : BOOL;
    bIsEmergency            : BOOL;
    bSelfTestDone           : BOOL;
    bSkipSelfTestAllowed    : BOOL;
    bForceSkipSelfTestAllowed: BOOL;
END_STRUCT
END_TYPE


TYPE Stru_ErrorEntry :
STRUCT
    iLevel      : INT;
    iCode       : INT;
    iSource     : INT;
    iVal1       : INT;
    diTimestamp : DINT;
END_STRUCT
END_TYPE


TYPE Stru_ErrorQueue :
STRUCT
    aEntries    : Stru_ErrorEntry[9];
    iHead       : INT;
    iTail       : INT;
    iCount      : INT;
    bOverflow   : BOOL;
    bPad0       : BOOL;
END_STRUCT
END_TYPE


TYPE Stru_HMI_SysRuntime :
STRUCT
    diAgingCycleCount   : DINT;
    diTotalCycles       : DINT;
    diRunTime           : DINT;
    diReserved          : DINT;
    iCurrentStep        : INT;
    iActCycles          : INT;
    bBatchDone          : BOOL;
    pad                 : BOOL;
END_STRUCT
END_TYPE


TYPE Stru_HMI_SysError :
STRUCT
    iLevel      : INT;
    iCode       : INT;
    iSource     : INT;
    iSubCode    : INT;
    iVal1       : INT;
    iVal2       : INT;
    bActive     : BOOL;
    bCritical   : BOOL;
    bEscalated  : BOOL;
    bNeedReset  : BOOL;
    pad0        : BOOL;
    pad1        : BOOL;
    pad2        : BOOL;
    pad3        : BOOL;
END_STRUCT
END_TYPE


TYPE Stru_HMI_SysWarning :
STRUCT
    iCode       : INT;
    iSource     : INT;
    iVal1       : INT;
    pad_int     : INT;
    bActive     : BOOL;
    pad0        : BOOL;
END_STRUCT
END_TYPE


TYPE Stru_HMI_Sys :
STRUCT
    Cmd         : Stru_HMI_SysCmd;
    Status      : Stru_HMI_SysDisplay;
    ErrorQueue  : Stru_ErrorQueue;
    Runtime     : Stru_HMI_SysRuntime;
    Error       : Stru_HMI_SysError;
    Warning     : Stru_HMI_SysWarning;
END_STRUCT
END_TYPE


(*---------------------------------------------------------------------------
  尾板/电推杆（TailTilt）
---------------------------------------------------------------------------*)
TYPE Stru_PusherCmd :
STRUCT
    bEnable         : BOOL;     // 使能
    bStop           : BOOL;     // 停止
    bReset          : BOOL;
    bCalibrate      : BOOL;     // 执行标定
    bAutoMove       : BOOL;     // 自动定位
    bHome           : BOOL;     // 回零（移动到原点位置）
    bJogUp          : BOOL;     // 正向点动
    bJogDown        : BOOL;     // 负向点动
    bManualPreset   : BOOL;     // 手动清零
    bResetError     : BOOL;     // 重置故障
    bPad            : BOOL[6];  // 填充
END_STRUCT
END_TYPE


TYPE Stru_PusherStatus :
STRUCT
    rCurrAngle              : REAL;     // 当前角度（HC_Counter mm 位置经余弦定理/ACOS 解算）
    rCurrPosMm              : REAL;     // 当前推杆位置（mm，HC_Counter.Position 镜像）
    rPresetDeg              : REAL;     // 最近一次 Preset 目标角度
    rReserved               : REAL;
    iErrorCode              : INT;      // 错误码 (5001=堵转 5002=超时 5003=重试超限)
    iRetryCount             : INT;      // 当前重试计数
    bCalibrated             : BOOL;     // 已校准
    bHomed                  : BOOL;     // 已回零（Home 流程置位，与标定解耦）
    bHoming                 : BOOL;     // 正在执行 Home 流程
    bHomeSwitch             : BOOL;     // 原点传感器有效 (= I_Pusher_Origin)
    bReferenceValid         : BOOL;     // 坐标参考有效
    bHomeSensorHealthy      : BOOL;     // 原点传感器健康
    bHomeSensorStuckOn      : BOOL;     // 原点传感器卡死 ON
    bHomeSensorStuckOff     : BOOL;     // 原点传感器卡死 OFF/不可达
    bHomePlausible          : BOOL;     // 原点传感器与角度一致性通过
    bRunUp                  : BOOL;     // 正转输出
    bRunDown                : BOOL;     // 反转输出
    bBusy                   : BOOL;     // 忙
    bDone                   : BOOL;     // 完成
    bError                  : BOOL;     // 故障
    bWarning                : BOOL;
    bStall                  : BOOL;
    bTimeout                : BOOL;
    bPosLimit               : BOOL;
    bNegLimit               : BOOL;
    bAtInit                 : BOOL;
    bSensorChecked          : BOOL;     // 传感器已被检验（FB_Home.out_bSensorChecked 镜像）
    bAutoMovePending        : BOOL;
    bAutoMoveAllowed        : BOOL;
    bPadDiag0               : BOOL;
    bPadDiag1               : BOOL;
END_STRUCT
END_TYPE


TYPE Stru_PusherLimitConfig :
STRUCT
    rMaxDeg                 : REAL;     // 正限位 (°)
    rMinDeg                 : REAL;     // 负限位 (°)
    rTolerance              : REAL;     // 到位容差 (°，判断到位/bAtInit)
    rInitialPosition        : REAL;     // 初始位置角度 (°，回零目标)
    rMinTravel              : REAL;     // 最小行程保护 (°，堵转检测前必须走过)
    rHomePosition           : REAL;     // 原点位置 (°)
    rInertiaUp              : REAL;     // 角度增大方向惯性补偿 (°，提前停)
    rInertiaDown            : REAL;     // 角度减小方向惯性补偿 (°，提前停)
    rStallThreshold         : REAL;     // 堵转位移阈值 (°)
    rStallSpeedThreshold    : REAL;     // 堵转速度阈值 (°/s)
    diStallTimeout          : DINT;     // 堵转判定时间 (ms)
    diTimeout               : DINT;     // 寻传感器/标定超时 (ms)
    diReverseDelay          : DINT;     // 反向缓冲延时 (ms)
    diStopCheck             : DINT;     // 停车滑行等待 (ms)
    iMaxRetries             : INT;      // 最大修正次数
    iPad                    : INT;      // 填充
    bInvertPusherDirection  : BOOL;     // 输出方向取反（Y5/Y6 交换，对齐物理方向）
END_STRUCT
END_TYPE


TYPE Stru_PusherMotion :
STRUCT
    rTargetAngle        : REAL;     // 目标角度 (°)
    rManualPresetAngle  : REAL;     // 手动 Preset 目标角度 (°)
    diJogTime           : DINT;     // Jog 限时 (ms，bJogModeTimed=TRUE 时生效)
    diMoveTimeout       : DINT;     // 定位超时 (ms)
    bJogModeTimed       : BOOL;     // 限时 Jog 模式
    bPad0               : BOOL;
END_STRUCT
END_TYPE


TYPE Stru_HMI_Pusher :
STRUCT
    Cmd         : Stru_PusherCmd;
    Status      : Stru_PusherStatus;
    ConfigCmd   : Stru_ConfigCmd;
    Config      : Stru_PusherLimitConfig;
    Motion      : Stru_PusherMotion;
END_STRUCT
END_TYPE


(*---------------------------------------------------------------------------
  伺服轴（ChestImpact / SeatTwist / LegAngle 三处复用）
  ⚠ 字段顺序照抄 CSV：Status → Cmd → Motion → Config → ConfigCmd
---------------------------------------------------------------------------*)
TYPE Stru_ServoAxisStatus :
STRUCT
    rActPosition            : REAL;     // 实际位置（脉冲或 mm）
    rActVelocity            : REAL;     // 实际速度
    rActTorque              : REAL;     // 实际扭矩
    iErrorCode              : INT;      // 错误码（来自 FB_运动控制）
    iDriveErrorCode         : INT;      // 驱动器错误码（来自伺服/M900）
    diDiscreteMotionTime    : DINT;     // 定位运动时间 (ms)
    bEnabled                : BOOL;     // 已使能（驱动器上电）
    bReady                  : BOOL;     // 驱动就绪
    bBusy                   : BOOL;     // 运动中
    bDone                   : BOOL;     // 动作完成（上升沿）
    bStandStill             : BOOL;     // 静止
    bInPosition             : BOOL;     // 到位
    bDiscreteMotion         : BOOL;     // 定位运动中
    bMoveDone               : BOOL;     // 运动完成 (脉冲)
    bZeroCommissioned       : BOOL;     // 底层 home-state 镜像（非持久建零标志）
    bZeroCommissioning      : BOOL;     // 正在原点标定（运行期通常不触发）
    bOriginSwitch           : BOOL;     // 原点传感器信号（物理输入）
    bPosLimit               : BOOL;     // 正限位触发
    bNegLimit               : BOOL;     // 负限位触发
    bError                  : BOOL;     // 错误激活
    bStopping               : BOOL;     // 错误停止中
    bEncoderFault           : BOOL;     // 编码器故障
    pad0                    : BOOL;
    pad1                    : BOOL;
    pad2                    : BOOL;
    bPad3                   : BOOL;     // CSV 中该字段名带 b 前缀，照抄
END_STRUCT
END_TYPE


TYPE Stru_AxisForceStatus :
STRUCT
    rBiasPosPct     : REAL;     // 正扭矩侧静止基线 (%)
    rBiasNegPct     : REAL;     // 负扭矩侧静止基线 (%)
    rNetTorquePct   : REAL;     // 扣基线后净扭矩 (%)
    rForceRawN      : REAL;     // 未滤波牵引力估算 (N)
    rForceFiltN     : REAL;     // 低通后牵引力估算 (N)
    diOverForceET   : DINT;     // 超力持续时间 (ms)
    bForceValid     : BOOL;     // 力估算有效
    bBiasPosValid   : BOOL;     // 正侧基线已学习
    bBiasNegValid   : BOOL;     // 负侧基线已学习
    bOverForce      : BOOL;     // 超力实时态
    bOverForceLatched: BOOL;    // 超力锁存
    bPad0           : BOOL;
END_STRUCT
END_TYPE


TYPE Stru_AxisStatus :
STRUCT
    Servo               : Stru_ServoAxisStatus;
    Force               : Stru_AxisForceStatus;
    iCurrentStep        : INT;      // 当前运动步骤 (0=空闲 1-N=执行中)
    iPadInt             : INT;      // 对齐填充
    diWaitingTime       : DINT;     // 等待时间 (ms)
    diMotionTime        : DINT;     // 运动用时 (ms)
    iErrorCode          : INT;      // [镜像] = Servo.iErrorCode
    bCalibrated         : BOOL;     // 已标定
    bError              : BOOL;
    bWarning            : BOOL;     // 警告激活（区别于 Servo.bError）
    bAxisErrorStopping  : BOOL;     // 轴错误停止中（区别于 Servo.bStopping）
    bAtInit             : BOOL;     // 在初始位置容差内
    bPad0               : BOOL;
END_STRUCT
END_TYPE


TYPE Stru_AxisCmd :
STRUCT
    bEnable             : BOOL;     // 使能（伺服上电）
    bReset              : BOOL;     // 复位（清除轴错误）
    bZeroCommission     : BOOL;     // 原点标定（仅工厂模式，触发 MC_Home，运行期禁止）
    bStop               : BOOL;     // 停止（立即减速停车）
    bMoveAbs            : BOOL;     // 绝对定位
    bMoveRel            : BOOL;     // 相对定位
    bJogPos             : BOOL;     // 正向点动（按住持续）
    bJogNeg             : BOOL;     // 负向点动（按住持续）
    bAutoMove           : BOOL;
    bMoveBuffer         : BOOL;
    bRequestDisable     : BOOL;     // 请求断使能（EMERGENCY_HOME 降级复位流程）
    bPad0               : BOOL;
    pad1                : BOOL;     // CSV 中该字段名无 b 前缀，照抄
    pad2                : BOOL;
    pad3                : BOOL;
    pad4                : BOOL;
END_STRUCT
END_TYPE


TYPE Stru_AxisMotionParam :
STRUCT
    rTargetPos  : REAL;     // 目标位置
    rTargetVel  : REAL;     // 目标速度
    rJogVel     : REAL;     // 点动速度
    rAcc        : REAL;     // 加速度
    rDec        : REAL;     // 减速度
    rInitPos    : REAL;     // 初始位置
    diTimeout   : DINT;     // 超时 (ms)
    rReserved   : REAL;
END_STRUCT
END_TYPE


TYPE Stru_AxisLimitConfig :
STRUCT
    rPosLimit       : REAL;     // 正限位 (°或 mm)
    rNegLimit       : REAL;     // 负限位 (°或 mm)
    rInitPos        : REAL;     // 初始位置
    rTolerance      : REAL;     // 到位容差 (°或 mm)
    rMaxVel         : REAL;     // 最大速度
    rMinVel         : REAL;     // 最小速度
    rMaxAcc         : REAL;     // 最大加速度
    rMaxDec         : REAL;     // 最大减速度
    diPulsePerDeg   : DINT;     // 脉冲当量 (Pulse/°)
    diTimeout       : DINT;     // 超时报警 (ms)
END_STRUCT
END_TYPE


TYPE Stru_HMI_Axis :
STRUCT
    Status      : Stru_AxisStatus;
    Cmd         : Stru_AxisCmd;
    Motion      : Stru_AxisMotionParam;
    Config      : Stru_AxisLimitConfig;
    ConfigCmd   : Stru_ConfigCmd;
END_STRUCT
END_TYPE


(*---------------------------------------------------------------------------
  回零参数（HomingParams）
---------------------------------------------------------------------------*)
TYPE Stru_HomingParams :
STRUCT
    rLimitEscapeVel         : REAL;
    rChestJogVel            : REAL;
    rLegJogVel              : REAL;
    rSeatJogVel             : REAL;
    rChestCrawlVel          : REAL;
    rLegCrawlVel            : REAL;
    rSeatCrawlVel           : REAL;
    rChestApproachZone      : REAL;
    rLegApproachZone        : REAL;
    rSeatApproachZone       : REAL;
    rChestHysteresis        : REAL;
    rLegHysteresis          : REAL;
    rSeatHysteresis         : REAL;
    rChestJogAcc            : REAL;
    rLegJogAcc              : REAL;
    rSeatJogAcc             : REAL;
    rAntiPinchTorqueLimit   : REAL;
    diHomingTimeout         : DINT;
    diEmergencyTimeout      : DINT;
    diLimitEscapeTimeout    : DINT;
    diStopReleaseTimeout    : DINT;
    diEmergencyCoastMs      : DINT;
    diEmergencyStallTimeout : DINT;
    iHomingMode             : INT;
    iMaxRetry               : INT;
    bEmergencyAllowCalib    : BOOL;
    bPad0                   : BOOL;
END_STRUCT
END_TYPE


TYPE Stru_HMI_HomingParams :
STRUCT
    Cmd     : Stru_ConfigCmd;
    Params  : Stru_HomingParams;
END_STRUCT
END_TYPE


(*---------------------------------------------------------------------------
  尾板位置/角度反馈（D936–D940，不挤占 TailTilt 主协议）
  真实推杆无 AD：位置来自 HC_Counter(mm)，角度由几何解算；布局保持 5 字不变。
---------------------------------------------------------------------------*)
TYPE Stru_HMI_TailAdFeedback :
STRUCT
    rAngle      : REAL;     // 当前角度（°，几何解算镜像，D936–D937）
    diPosMm     : DINT;     // 当前推杆位置（mm，HC_Counter.Position，D938–D939）
    bPosValid   : BOOL;     // 位置有效（HC_Counter.Valid 且无 Error）
    bPad0       : BOOL;     // 填充
END_STRUCT
END_TYPE


(*---------------------------------------------------------------------------
  主结构体：HMI，整体 AT %MW200（D200–D940，741 字）
  ⚠ 成员顺序照抄 CSV：Condition / Sys / TailTilt / ChestImpact / SeatTwist /
     LegAngle / HomingParams / TailTiltAdFeedback
---------------------------------------------------------------------------*)
TYPE Stru_HMI :
STRUCT
    Condition           : Stru_HMI_Condition;      // 调理参数、控制、状态
    Sys                 : Stru_HMI_Sys;            // 系统
    TailTilt            : Stru_HMI_Pusher;         // 尾板下降（电推杆）
    ChestImpact         : Stru_HMI_Axis;           // 冲击轴
    SeatTwist           : Stru_HMI_Axis;           // 扭角轴
    LegAngle            : Stru_HMI_Axis;           // 转角轴
    HomingParams        : Stru_HMI_HomingParams;   // 回零参数
    TailTiltAdFeedback  : Stru_HMI_TailAdFeedback; // 尾板位置/角度反馈（D936–D940，mm+几何角度）
END_STRUCT
END_TYPE


(*---------------------------------------------------------------------------
  设备信息只读镜像（D1000–D1004）—— Stru_HMI_DeviceInfo_new.csv
---------------------------------------------------------------------------*)
TYPE Stru_HMI_DeviceInfo :
STRUCT
    diDeviceNoRaw   : DINT;     // 原始设备编号（工厂烧录/维护配置）
    iMacWord0       : INT;      // PLC MAC 地址字 0 (= _Ethernet.MACAddress[0])
    iMacWord1       : INT;      // PLC MAC 地址字 1 (= _Ethernet.MACAddress[1])
    iMacWord2       : INT;      // PLC MAC 地址字 2 (= _Ethernet.MACAddress[2])
END_STRUCT
END_TYPE


(*---------------------------------------------------------------------------
  设备身份维护写入（D1010–D1013）—— Stru_HMI_DeviceIdentityWrite_new.csv
  例外：本块命令集仅 Load / Apply（无 Save / ResetDefault）
---------------------------------------------------------------------------*)
TYPE Stru_DeviceIdentityCmd :
STRUCT
    iErrorCode  : INT;
    bLoad       : BOOL;
    bApply      : BOOL;
    bSuccess    : BOOL;
    bError      : BOOL;
    bPad0       : BOOL;
    bPad1       : BOOL;
END_STRUCT
END_TYPE


TYPE Stru_HMI_DeviceIdentityWrite :
STRUCT
    Cmd             : Stru_DeviceIdentityCmd;
    diDeviceNoRaw   : DINT;     // DINT 偶字对齐 → D1012–D1013
END_STRUCT
END_TYPE
