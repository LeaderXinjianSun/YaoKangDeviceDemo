(*============================================================================
  常量库：状态码 / 错误码 / 角色 / 轴索引
  禁止魔法数字；新增码值须与《HMI-PLC地址分配表.md》对齐。
==========================================================================*)

VAR_GLOBAL CONSTANT
    (*--- 主状态 iState（MODE_MANAGER，13 态） ---*)
    ST_INIT              : INT := 0;
    ST_READY_CHECK       : INT := 3;
    ST_SELFTEST          : INT := 5;
    ST_STANDBY           : INT := 10;
    ST_SERVICE_REQUIRED  : INT := 15;
    ST_AUTORUN           : INT := 20;
    ST_SERVICE           : INT := 30;
    ST_HOMING            : INT := 40;
    ST_CALIBRATE         : INT := 45;
    ST_RESET             : INT := 50;
    ST_STOPPING          : INT := 60;
    ST_SOFT_ESTOP        : INT := 110;
    ST_HARD_ESTOP        : INT := 120;
    ST_PARAM_LIMITED     : INT := 998;

    (*--- 调理阶段 iPhase（Condition.Status.iPhase） ---*)
    COND_IDLE            : INT := 0;
    COND_PREPARE         : INT := 1;
    COND_RUNNING         : INT := 2;
    COND_ANGLE           : INT := 3;
    COND_DONE            : INT := 9;

    (*--- 工作模式 ---*)
    WORKMODE_COND        : INT := 1;    (* 调理 *)
    WORKMODE_TREAT       : INT := 2;    (* 治疗 *)
    WORKMODE_AGING       : INT := 3;    (* 老化 *)

    (*--- 用户角色（HMI 线协议：0=操作员 1=工程师；退出登录/未登录=操作员 0） ---*)
    ROLE_NONE            : INT := 0;
    ROLE_OPERATOR        : INT := 0;
    ROLE_ENGINEER        : INT := 1;
    AUTH_CODE_ENGINEER   : INT := 16#5A;   (* 登录写 16#5A、退出写 0（防误写） *)

    (*--- 轴索引（故障来源 gFaultSource / 参数错误上报用，INT 编号） ---*)
    (* 注：勿与 GVL_IoMap 中 Axis_胸背/臀盘/臀腿（AXIS_REF 轴引用）混淆，
       ST 标识符大小写不敏感，故本组常量使用 AXIS_ID_ 前缀。 *)
    AXIS_ID_CHEST        : INT := 1;    (* 冲击 *)
    AXIS_ID_LEG          : INT := 2;    (* 转角 *)
    AXIS_ID_SEAT         : INT := 3;    (* 扭角 *)
    AXIS_ID_TAIL         : INT := 4;    (* 尾板推杆 *)

    (*--- 错误码段位约定：
       1xxx 系统/急停  11xx 初始化/电源  12xx 紧急回零/防夹/跟随  13xx 自检
       2xxx 三轴       3xxx 推杆(3021-3025/3101-3107)  4xxx 回零
       5xxx 参数/身份(5001-5003/5005/5006)                          7xxx 调理前检查
       子码约定：轴故障 iSubCode=驱动器 Er.xxx；gFaultSource 用 AXIS_ID_* / SRC_*。
       级别：1001/1002/1003 段码由 ERROR_MANAGER 按码表定级（Critical 需手动复位）。 ---*)

    (*===== 1xxx 系统 / 急停 =====*)
    ERR_HARD_ESTOP       : INT := 1001;   (* 硬急停：物理急停链路断开（常闭点断开/安全继电器动作） *)
    ERR_SOFT_ESTOP       : INT := 1002;   (* 软急停：HMI 急停请求（D488.9，受控减速） *)
    ERR_ESTOP_MISMATCH   : INT := 1003;   (* 急停双通道不一致（通道1/通道2 状态分歧） *)
    ERR_SOFT_ESTOP_TOUT  : INT := 1004;   (* 软急停减速超时，升级硬急停 *)
    ERR_COMM_LOST        : INT := 1006;   (* HMI 通信超时（Modbus 心跳丢失） *)
    ERR_SCAN_WATCHDOG    : INT := 1007;   (* 扫描周期看门狗超时 *)

    (*===== 11xx 初始化 / 电源 =====*)
    ERR_INIT_POWER       : INT := 1101;   (* 伺服上电失败（使能超时无 bReady） *)
    ERR_INIT_AXIS_REF    : INT := 1102;   (* 轴参考/零点标志丢失，需回零 *)
    ERR_INIT_CONFIG      : INT := 1103;   (* 启动参数未应用/配置无效 *)

    (*===== 12xx 紧急回零 / 防夹 / 跟随 =====*)
    ERR_EMGHOME_RELEASE  : INT := 1201;   (* 紧急回零：MC_Stop 释放等待超时 *)
    ERR_EMGHOME_TORQUE   : INT := 1202;   (* 紧急回零：扭矩防夹触发（超阈重试上限内） *)
    ERR_EMGHOME_RETRY    : INT := 1203;   (* 紧急回零：防夹重试超限，中止 *)
    ERR_ANTIPINCH_JOG    : INT := 1204;   (* Jog 防夹：点动扭矩超阈，立即停止 *)
    ERR_AXIS_FOLLOW      : INT := 1205;   (* 跟随误差超限（位置偏差过大） *)
    ERR_OVERFORCE        : INT := 1206;   (* 超力保护：牵引力估算超阈持续超时，锁存停机 *)

    (*===== 13xx 自检 =====*)
    ERR_SELFTEST_ENTRY   : INT := 1301;   (* 自检门禁断言不满足 *)
    ERR_SELFTEST_TIMEOUT : INT := 1302;   (* 自检全局超时 *)
    ERR_SELFTEST_PUSHER  : INT := 1303;   (* 自检推杆参考/校准失败（30s 超时） *)
    ERR_SELFTEST_AXIS    : INT := 1304;   (* 自检三轴 ±2° 单循环失败（8s/轴超时） *)
    ERR_SELFTEST_DIRTY   : INT := 1305;   (* 自检完成后脏标记未清零 *)

    (*===== 2xxx 三轴伺服 =====*)
    ERR_AXIS_DRIVE       : INT := 2001;   (* 驱动器故障（子码=驱动器 Er.xxx） *)
    ERR_AXIS_ENCODER     : INT := 2002;   (* 编码器故障，绝对位置不可信，禁定位 *)
    ERR_AXIS_HWLIMIT     : INT := 2003;   (* 硬限位触发 *)
    ERR_AXIS_SWLIMIT     : INT := 2004;   (* 软限位：越限运动被禁 *)
    ERR_AXIS_STEP_TOUT   : INT := 2005;   (* 运动步骤超时（目标未在 diTimeout 内到达） *)
    ERR_AXIS_CMD_ILLEGAL : INT := 2006;   (* 轴命令非法（未使能/未参考时请求定位） *)

    (*===== 3xxx 电推杆（尾板成角） =====*)
    ERR_TAIL_SENSOR_STKON  : INT := 3021; (* 原点传感器卡死 ON（应断开通） *)
    ERR_TAIL_SENSOR_STKOFF : INT := 3022; (* 原点传感器卡死 OFF（应接通通不了） *)
    ERR_TAIL_SENSOR_IMPL   : INT := 3023; (* 原点与角度一致性不合理（参考冲突） *)
    ERR_TAIL_NOT_CALIB     : INT := 3024; (* 未校准/参考无效，禁止自动定位 *)
    ERR_TAIL_ANGLE_LIMIT   : INT := 3025; (* 角度软限位保护动作 *)
    ERR_TAIL_CAL_TOP       : INT := 3101; (* 校准：上行撞顶堵转 *)
    ERR_TAIL_CAL_HOME      : INT := 3102; (* 校准：上行找原点失败 *)
    ERR_TAIL_CAL_ESCAPE    : INT := 3103; (* 校准：下行脱离原点失败 *)
    ERR_TAIL_CAL_DEBOUNCE  : INT := 3104; (* 校准：原点去抖 30ms 不稳定 *)
    ERR_TAIL_CAL_TIMEOUT   : INT := 3105; (* 校准：全局超时 *)
    ERR_TAIL_CAL_DIR       : INT := 3106; (* 校准：方向逻辑异常（上下行判断矛盾） *)
    ERR_TAIL_HOME_FAILED   : INT := 3107; (* 回零失败 *)

    (*===== 4xxx 回零 =====*)
    ERR_HOME_TIMEOUT     : INT := 4001;   (* 普通回零全流程超时 *)
    ERR_HOME_REFUSE      : INT := 4002;   (* 回零被拒（安全/参考条件不满足） *)
    ERR_HOME_AXIS        : INT := 4003;   (* 某轴回初始位失败（子码=轴号） *)

    (*===== 5xxx 参数 / 身份 =====*)
    ERR_PARAM_LOCKED        : INT := 5004;   (* 参数 Apply/ResetDefault 被拒：自动流程运行中，运行区快照锁定 *)
    ERR_PARAM_DEVICE_LOCKED : INT := 5005;   (* 设备身份写入：锁定/状态不允许 *)
    ERR_PARAM_DEVICE_VALUE  : INT := 5006;   (* 设备编号非法 *)
    ERR_PARAM_VALUE         : INT := 5007;   (* 参数值非法（越界/≤0/逻辑矛盾），三元组定位到轴+字段 *)

    (*--- READY_CHECK 六项资格位掩码（Sys.Status.diReadyCheckResult，0=全过，置位=缺项） ---*)
    READY_BIT_ZERO    : INT := 0;   (* bit0：零点/参考无效（未建零或未回零） *)
    READY_BIT_PARAM   : INT := 1;   (* bit1：运行区参数无效/参数校验未过 *)
    READY_BIT_HW      : INT := 2;   (* bit2：硬件未就绪（未上电/伺服未使能） *)
    READY_BIT_HEALTH  : INT := 3;   (* bit3：健康检查未过（活动 Critical 错误） *)
    READY_BIT_POS     : INT := 4;   (* bit4：全轴未在初始位 *)
    READY_BIT_REF     : INT := 5;   (* bit5：全轴参考无效 *)

    (*--- 健康等级 iHealthLevel（Sys.Status） ---*)
    HEALTH_FAULT   : INT := 0;   (* 故障：有活动 Critical，禁止运行 *)
    HEALTH_NORMAL  : INT := 1;   (* 正常：全部资格具备 *)
    HEALTH_WARNING : INT := 2;   (* 警告：有活动 Warning，允许运行 *)
    HEALTH_UNKNOWN : INT := 3;   (* 未就绪：未完成自检/就绪检查 *)

    (*--- 电推杆错误码（TailTilt.Status.iErrorCode，业务码） ---*)
    PUSHER_ERR_STALL     : INT := 5001;  (* 堵转 *)
    PUSHER_ERR_TIMEOUT   : INT := 5002;  (* 超时 *)
    PUSHER_ERR_RETRY     : INT := 5003;  (* 重试超限 *)

    (*--- 参数校验错误（Condition.Status） ---*)
    PARAM_ERR_SEGMENT    : INT := 1005;  (* iSegmentCount 非法（校验类，Warning） *)

    (*===== 7xxx 调理前检查 / 运行条件 =====*)
    ERR_PRECHK_READY     : INT := 7001;   (* 就绪检查未通过（资格位掩码见 diReadyCheckResult） *)
    ERR_PRECHK_AXIS      : INT := 7002;   (* 启动前检查：轴未使能/未静止 *)
    ERR_PRECHK_POS        : INT := 7003;  (* 启动前检查：全轴未在初始位 *)
    ERR_PRECHK_PARAM     : INT := 7004;   (* 启动前检查：参数校验未通过 *)
    ERR_PRECHK_ZERO      : INT := 7005;   (* 启动前检查：零点/参考无效 *)

    (*--- 故障来源模块码 gFaultSource（轴用 AXIS_ID_CHEST/LEG/SEAT/TAIL=1..4） ---*)
    SRC_SAFETY           : INT := 10;   (* SAFETY_MANAGER *)
    SRC_MODE             : INT := 11;   (* MODE_MANAGER *)
    SRC_PARAM            : INT := 12;   (* PARAM_SERVICE *)
    SRC_MONITOR          : INT := 13;   (* MONITOR / AD / 通信 *)
    SRC_POWER            : INT := 14;   (* POWER *)
    SRC_OUTPUT           : INT := 15;   (* OUTPUT_ADAPTER（三轴） *)
    SRC_HOMING           : INT := 16;   (* 回零/紧急回零任务 *)
    SRC_SELFTEST         : INT := 17;   (* 自检任务 *)
    SRC_COND             : INT := 18;   (* 调理/治疗/老化任务 *)
    SRC_PUSHER           : INT := 19;   (* 推杆任务（区别于轴来源 AXIS_ID_TAIL=4） *)

    (*--- 轴命令位索引（Gvl.axisPulse / axisPulse 等 [3×N] 数组第二维下标）
       与 Stru_AxisCmd 中"脉冲型"字段一一对应；bJogPos/bJogNeg 为电平型，
       单独走 axisJogPos/axisJogNeg 镜像数组，不在本索引内。 ---*)
    AXCMD_RESET          : INT := 1;   (* bReset 复位清错 *)
    AXCMD_ZERO_COMM      : INT := 2;   (* bZeroCommission 原点标定（工厂） *)
    AXCMD_STOP           : INT := 3;   (* bStop 立即减速停车 *)
    AXCMD_MOVEABS        : INT := 4;   (* bMoveAbs 绝对定位 *)
    AXCMD_MOVEREL        : INT := 5;   (* bMoveRel 相对定位 *)
    AXCMD_AUTOMOVE       : INT := 6;   (* bAutoMove 自动流程运动 *)
    AXCMD_MOVEBUFFER     : INT := 7;   (* bMoveBuffer 16 段缓冲 *)
    AXCMD_REQ_DISABLE    : INT := 8;   (* bRequestDisable 请求断使能 *)
    AXCMD_MAX            : INT := 8;   (* 脉冲命令位个数（数组下界基准） *)

    (*--- FB_AxisControl 运动状态机步号（iStep / stStatus.iCurrentStep） ---*)
    AXST_IDLE            : INT := 0;   (* 未使能 *)
    AXST_ENABLING        : INT := 1;   (* 使能中 *)
    AXST_READY           : INT := 2;   (* 已使能静止就绪 *)
    AXST_JOG             : INT := 3;   (* 点动中 *)
    AXST_MOVE            : INT := 4;   (* 单段定位中 *)
    AXST_BUFFER          : INT := 5;   (* 多段缓冲执行中 *)
    AXST_ERROR           : INT := 9;   (* 轴错误态（驱动器故障/超时） *)

    (*--- POWER 分时上电时序（按 10ms 扫描周期推算，任务组态确认后统一修正） ---*)
    PWR_STAGGER_SCAN    : DINT := 50;     (* 逐轴使能间隔扫描数（50 扫≈500ms，防浪涌） *)
    PWR_ENABLE_TIMEOUT  : DINT := 300;    (* 单轴使能确认超时扫描数（300 扫≈3s，超时报 1101） *)

    (*--- 力估算占位常量（台架标定 TODO：换算系数/阈值/持续时间需实测标定） ---*)
    FORCE_LPF_ALPHA      : REAL := 0.1;    (* 牵引力一阶低通系数（每扫 0.1，@10ms） *)
    FORCE_SCALE_N        : REAL := 1.0;    (* 净扭矩% → 牵引力 N 换算系数（占位） *)
    OVERFORCE_N          : REAL := 100.0;  (* 超力阈值 N（低通后，占位） *)
    OVERFORCE_SCAN       : DINT := 50;     (* 超力持续扫描数（50 扫≈500ms@10ms）锁存 *)

    (*===== P9 任务步号（TASK_RUNNER 写 Condition.Status.iStep / iPhase；
           CASE 标签仍用字面整数 + 行尾注释，本处仅为消除魔法数字。 =====*)

    (*--- 普通回零（iState=ST_HOMING=40）：三轴 MoveAbs 回 rInitPos ---*)
    HOMSEQ_START         : INT := 4000;   (* 入口：装载目标/启动快照 *)
    HOMSEQ_MOVE          : INT := 4010;   (* 发 MoveAbs（顺序模式逐轴 / 并行模式全发） *)
    HOMSEQ_WAIT          : INT := 4020;   (* 等待全轴到位（4001 全流程超时） *)
    HOMSEQ_DONE          : INT := 4090;   (* 完成：置参考有效/位标志，iPhase=COND_DONE *)

    (*--- 回零执行模式（runHoming.iHomingMode） ---*)
    HOM_MODE_SEQUENTIAL  : INT := 0;      (* 顺序：Chest→Seat→Leg 逐轴 *)
    HOM_MODE_PARALLEL    : INT := 1;      (* 并行：三轴同时 MoveAbs *)

    (*--- 紧急回零（iState=ST_SOFT_ESTOP=110 内）：四段 Jog 回初始位 + 防夹 ---*)
    EMH_WAIT_RELEASE     : INT := 1100;   (* 等 MC_Stop 释放/停稳（1201 diStopReleaseTimeout） *)
    EMH_JOG_MAIN         : INT := 1110;   (* 主速 Jog 回初始位（超接近区前） *)
    EMH_JOG_CRAWL        : INT := 1120;   (* 爬行 Jog（进入 rApproachZone 后） *)
    EMH_SETTLE           : INT := 1130;   (* 微调/迟滞判停（|pos-init|<=rHysteresis） *)
    EMH_PINCH_WAIT       : INT := 1140;   (* 防夹触发后撤力等待（1202，重试计数） *)
    EMH_DONE             : INT := 1190;   (* 紧急回零完成（停车电平保持，等 trigSysReset） *)

    (*--- 动态自检（iState=ST_SELFTEST=5）：Step10 → 100 成功 / 200 失败 ---*)
    ST_GATE              : INT := 10;     (* 门禁断言（1301） *)
    ST_WAIT_CONFIRM      : INT := 20;     (* 等安全确认（可跳过/工程师强跳） *)
    ST_PUSHER_CALIB      : INT := 30;     (* 推杆参考检查 + 校准（1303，30s） *)
    ST_ANGLE             : INT := 40;     (* 成角（推杆自动定位到自检角） *)
    ST_AXIS_CYCLE        : INT := 50;     (* 三轴 ±2° 单循环（1304，8s/轴） *)
    ST_ANGLE_RETURN      : INT := 60;     (* 成角回零（推杆回零/回初始角） *)
    ST_DIRTY_CHECK       : INT := 70;     (* 清/核四个脏标记（1305） *)
    ST_STEP_DONE         : INT := 100;    (* 自检成功（bSelfTestDone:=TRUE） *)
    ST_STEP_FAIL         : INT := 200;    (* 自检失败（Critical 上报，等复位） *)

    (*--- 维护建零（iState=ST_CALIBRATE=45）：6 重门控 ---*)
    CAL_GATE             : INT := 5000;   (* 6 重门控断言（工程师/授权/空载/静止/安全/参考） *)
    CAL_COMM             : INT := 5010;   (* 发三轴 AXCMD_ZERO_COMM + 推杆标定脉冲 *)
    CAL_CONFIRM          : INT := 5020;   (* 等 Retain 握手回读（bZeroCommSetReq/bPushCalibDoneLatch） *)
    CAL_DONE             : INT := 5090;   (* 建零完成，iPhase=COND_DONE *)

    (*--- 自检运动参数（占位常量，与计划 ±2°/8s 对齐） ---*)
    ST_SWING_DEG         : REAL := 2.0;   (* 单循环摆动幅度 ±2°（相对 rInitPos） *)
    ST_AXIS_TOUT_SCAN    : DINT := 800;   (* 单轴单循环超时 800 扫 ≈ 8s（1304） *)
    ST_PUSHER_TOUT_SCAN  : DINT := 3000;  (* 推杆校准超时 3000 扫 ≈ 30s（1303） *)
    ST_GLOBAL_TOUT_SCAN  : DINT := 12000; (* 自检全局超时 12000 扫 ≈ 120s（1302） *)
    ST_ANGLE_DEG         : REAL := 15.0;  (* 自检成角目标（占位，取推杆配置安全角） *)

    (*===== P10 调理/治疗/老化任务步号（iState=ST_AUTORUN=20 内 iStepCond，
           写 Condition.Status.iStep；CASE 标签仍用字面整数 + 行尾注释。 =====*)
    CONDSEQ_GATE         : INT := 105;    (* 启动前检查（急停/就绪/参考/初始位/使能/参数，7001-7005） *)
    CONDSEQ_WAIT_PREP    : INT := 108;    (* 等待人员准备（S2 成角 / 跳过成角） *)
    CONDSEQ_ANGLE        : INT := 110;    (* 成角定位（推杆 AutoMove → rPusherPos） *)
    CONDSEQ_WAIT_SIGNAL  : INT := 120;    (* 等待开始确认（S3/脚踏；信号模式=1 自动放行） *)
    CONDSEQ_RUN          : INT := 130;    (* 三轴 16 段轨迹 × 循环联动（暂停/恢复贯穿） *)
    CONDSEQ_LAND         : INT := 140;    (* 安全降落（推杆回 rPusherInitPos，bDone 判定） *)
    CONDSEQ_BATCH_WAIT   : INT := 145;    (* 老化批间等待（diBatchInterval，批次进度上报） *)
    CONDSEQ_DONE         : INT := 800;    (* 完成（bDone，iPhase=COND_DONE） *)
    CONDSEQ_FAIL         : INT := 900;    (* 异常收口（bError；急停/手动停止由 ModeManager 转态） *)

    (*--- 停止安全降落步号（iState=ST_STOPPING=60 内 iStepStop） ---*)
    STOPSEQ_HALT         : INT := 6000;   (* 发三轴 STOP 脉冲至全轴静止 *)
    STOPSEQ_RETURN       : INT := 6010;   (* 三轴并行 MoveAbs 回初始位（到位后 ModeManager 回 STANDBY） *)

    (*===== 7xxx 补充：调理运行期超时（7001-7005 见前） =====*)
    ERR_COND_RUN_TIMEOUT : INT := 7006;   (* 调理流程总超时（diTotalTimeout，单批） *)
    ERR_COND_CONFIRM_TOUT: INT := 7007;   (* 等待人员准备/开始确认超时（diConfirmTimeout，Warning） *)

    (*===== 尾板推杆几何解算固定常量（真实推杆：开关型电推杆 + HC_Counter 读 mm 位置，
           余弦定理/ACOS 解算当前角度；无 AD。算法蓝本：推杆轴控制方式.txt。
           ★ 下列长度/补偿均为机械几何量，现场实测标定后固化，禁止运行时修改。 =====*)
    PUSHER_GEO_VERT_MM   : REAL := 100.0; (* 旋转中心垂直长度（mm，占位待实测） *)
    PUSHER_GEO_PAR_MM    : REAL := 100.0; (* 旋转中心平行长度（mm，占位待实测） *)
    PUSHER_GEO_TILT0_MM  : REAL := 100.0; (* 旋转中心倾斜长度零位偏置（mm，占位待实测）；
                                             倾斜长度_1 = 本偏置 + 当前推杆位置(mm)，钳 >=0 *)
    PUSHER_GEO_FIX_ANG   : REAL := 72.6;  (* 固定角（°）：当前角度 = 180 - 72.6 - ACOS·180/π + 补偿 *)
    PUSHER_GEO_ANG_COMP  : REAL := 0.0;   (* 角度补偿（°，占位待实测） *)
    PUSHER_PI            : REAL := 3.14159; (* 圆周率（弧度→度换算，ACOS 输出为弧度） *)
END_VAR
