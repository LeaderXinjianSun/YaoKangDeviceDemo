(*============================================================================
  内部全局变量（不映射 D 区，层间通信）
  ----------------------------------------------------------------------------
  单写源硬约束（见开发计划 §0.4）：
    iState / iWorkMode ......... MODE_MANAGER 唯一写
    Error / Warning / Queue .... ERROR_MANAGER 唯一写
    轴 bEnable / MC 指令 ....... POWER / OUTPUT_ADAPTER 唯一写
    任务级请求 ................. 各任务模块经 gTrig* / FaultReq 提交
==========================================================================*)
VAR_GLOBAL
    (*--- 系统状态（MODE_MANAGER 单写） ---*)
    iState          : INT := 0;        (* 主状态码，见 GVL_CONST：ST_* *)
    iPhase          : INT := 0;        (* 当前任务内阶段（任务模块上报） *)
    iBlockReason    : INT := 0;        (* 阻塞原因码 *)
    iWorkMode       : INT := 0;        (* 工作模式 1=调理 2=治疗 3=老化 *)
    iUserRole       : INT := 0;        (* 角色 0=未登录 1=操作员 2=工程师 *)

    (*--- 安全（SAFETY_MANAGER 单写） ---*)
    bHardEstop      : BOOL;            (* 硬急停：断使能 *)
    bSoftEstop      : BOOL;            (* 软急停：受控减速 *)
    bSafetyStop     : BOOL;            (* 安全链触发的停止请求 *)
    bAllAxesIdle    : BOOL;            (* 全轴静止 *)
    bAllAxesRef     : BOOL;            (* 全轴参考有效 *)
    bAllAxesAtInit  : BOOL;            (* 全轴在初始位 *)

    (*--- I/O 镜像（INPUT_ADAPTER 单写，去抖后） ---*)
    ioEstopOK       : BOOL;            (* 急停链路正常（双通道常闭闭合 + 安全继电器未动作） *)
    ioResetBtn      : BOOL;            (* 复位按钮（X7 去抖） *)
    ioPusherOrigin  : BOOL;            (* 推杆原点（X5 去抖） *)

    (*--- AD 反馈镜像（INPUT_ADAPTER 单写） ---*)
    diAdRaw         : DINT;            (* AD 原始值 *)
    bAdValid        : BOOL;            (* AD 有效（在 diAdMin/diAdMax 内） *)

    (*--- 命令脉冲位（INPUT_ADAPTER 单写，本扫有效） ---*)
    (* H5U 全局变量不支持功能块实例：R_TRIG 在 PRG_InputAdapter 局部 VAR 声明，
       其 .Q 每扫写入下列 BOOL 位；下游直接读位，边沿仅存活一个扫描周期。 *)
    trigStart       : BOOL;            (* S1 启动流程（本扫脉冲） *)
    trigChengJiao   : BOOL;            (* S2 开始成角（本扫脉冲） *)
    trigAllow       : BOOL;            (* S3 确认（本扫脉冲） *)
    trigStop        : BOOL;            (* 停止（本扫脉冲） *)
    trigReset       : BOOL;            (* 复位错误（本扫脉冲） *)
    (* 电平命令（直接镜像，下游读 .Q 无意义，读电平位） *)
    bPauseLevel     : BOOL;            (* 暂停（电平） *)
    bResumeLevel    : BOOL;            (* 恢复（电平） *)
    bFootSignal     : BOOL;            (* 脚踏（电平/脉冲按模式） *)

    (*--- 故障提交区（任务模块写 gFaultSubmit，ERROR_MANAGER 唯一消费） ---*)
    gFaultSubmit    : BOOL;            (* 提交脉冲：填好下列字段后置 TRUE *)
    gFaultLevel     : INT;             (* 0=L0 Info 1=L1 Warning 2=L2 Critical *)
    gFaultCode      : INT;             (* 错误码（见 GVL_CONST 段位约定） *)
    gFaultSource    : INT;             (* 来源模块码 *)
    gFaultSubCode   : INT;             (* 子码：轴 9xxx / 驱动器 Er.xxx *)
    gFaultVal1      : INT;             (* 附加值 1 *)
    gFaultVal2      : INT;             (* 附加值 2 *)

    (*--- 扫描监控 ---*)
    (* 看门狗 tScanWatchdog 为 BOOL（H5U 内联 TONR 的 Q=> 输出），声明于 PRG_Main 局部 VAR *)
    diScanCount     : DINT;            (* 扫描计数（心跳） *)
END_VAR
