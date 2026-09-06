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

    (*--- 用户角色 ---*)
    ROLE_NONE            : INT := 0;
    ROLE_OPERATOR        : INT := 1;
    ROLE_ENGINEER        : INT := 2;
    AUTH_CODE_ENGINEER   : INT := 16#5A;

    (*--- 轴索引（故障来源 gFaultSource / 参数错误上报用，INT 编号） ---*)
    (* 注：勿与 GVL_IoMap 中 Axis_胸背/臀盘/臀腿（AXIS_REF 轴引用）混淆，
       ST 标识符大小写不敏感，故本组常量使用 AXIS_ID_ 前缀。 *)
    AXIS_ID_CHEST        : INT := 1;    (* 冲击 *)
    AXIS_ID_LEG          : INT := 2;    (* 转角 *)
    AXIS_ID_SEAT         : INT := 3;    (* 扭角 *)
    AXIS_ID_TAIL         : INT := 4;    (* 尾板推杆 *)

    (*--- 错误码段位（P3 落地，此处先定义段位约定） ---*)
    (* 1xxx 系统/急停  11xx 初始化/电源  12xx 紧急回零/防夹  13xx 自检
       2xxx 三轴       3xxx 推杆(3021-3024/3101-3107)  4xxx 回零
       5xxx 参数/身份(5005/5006)                          7xxx 调理前检查 *)
    ERR_PARAM_DEVICE_LOCKED : INT := 5005;   (* 设备身份写入：锁定/状态不允许 *)
    ERR_PARAM_DEVICE_VALUE  : INT := 5006;   (* 设备编号非法 *)

    (*--- 电推杆错误码（TailTilt.Status.iErrorCode） ---*)
    PUSHER_ERR_STALL     : INT := 5001;  (* 堵转 *)
    PUSHER_ERR_TIMEOUT   : INT := 5002;  (* 超时 *)
    PUSHER_ERR_RETRY     : INT := 5003;  (* 重试超限 *)

    (*--- 参数校验错误（Condition.Status） ---*)
    PARAM_ERR_SEGMENT    : INT := 1005;  (* iSegmentCount 非法 *)
END_VAR
