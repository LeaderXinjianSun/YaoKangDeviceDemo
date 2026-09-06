(*============================================================================
  PRG_TaskRunner —— 层 30 任务：任务调度（扫描链第 7 环）
  ----------------------------------------------------------------------------
  唯一写入：iPhase（任务内阶段上报）、iBlockReason（阻塞原因）；任务级
            Cmd/Motion（HMI 各轴/推杆 Cmd 与 Motion 参数块）；故障经 gFaultSubmit。
  读入：  iState（MODE_MANAGER）、trig* 命令边沿、内部运行区参数。
  分派：按 iState 调度 AUTORUN（FBI_Cond/FATIGUE）/SELFTEST/HOMING/
        CALIBRATE/RESET 任务；任务模块只写任务级命令，MC 指令由
        OUTPUT_ADAPTER 唯一执行；不直接切 iState。
  P1：状态分派占位。
  P9/P10：回零/紧急回零/自检/建零、调理/治疗/老化自动流程。
==========================================================================*)
PROGRAM PRG_TaskRunner
VAR
END_VAR

(* H5U：CASE 标签须用字面整数（具名常量按变量处理会报错），行尾注释码值 *)
CASE iState OF
    10: // ST_STANDBY
        (* TODO P6/P10: 就绪态等待启动；快速启动/自动流程入口门控 *)
        iPhase := COND_IDLE;

    20: // ST_AUTORUN
        (* TODO P10: FBI_Cond（调理/治疗）/ FATIGUE（老化）状态机
           105 启动前检查 → 108 等待准备 → 110 成角 → 120 等确认
           → 130 三轴 16 段联动 → 140 安全降落 → 800 完成 / 900 异常 *)
        ;

    5: // ST_SELFTEST
        (* TODO P9: 动态自检 Step10→100/200（推杆参考检查→成角→三轴 ±2°→回零） *)
        ;

    40: // ST_HOMING
        (* TODO P9: 普通回零（三轴 MoveAbs 回初始位）；紧急回零在 SOFT_ESTOP 内 *)
        ;

    45: // ST_CALIBRATE
        (* TODO P8/P9: 推杆校准 / 维护建零（6 重门控后 MC_Home/标定） *)
        ;

    50: // ST_RESET
        (* TODO P9: 故障复位收口：清错误、回初始位、完成后回 STANDBY（由 ModeManager 切） *)
        iPhase := 0;
        iState := ST_STANDBY;   (* TODO: 复位流程完成后再切，P6 收口仲裁时移回 ModeManager *)

    60, 110, 120: // ST_STOPPING / ST_SOFT_ESTOP / ST_HARD_ESTOP
        (* 安全收口由 SAFETY_MANAGER / POWER / OUTPUT_ADAPTER 执行，任务层不动作 *)
        ;
ELSE
    (* 0 INIT / 3 READY_CHECK / 30 SERVICE / 15 SERVICE_REQUIRED / 998 PARAM_LIMITED：P6/P11 补 *)
    ;
END_CASE;
END_PROGRAM
