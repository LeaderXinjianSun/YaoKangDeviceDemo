(*============================================================================
  PRG_TaskRunner —— 层 30 任务：任务调度（扫描链第 7 环）
  ----------------------------------------------------------------------------
  !!! 重建占位骨架 !!!
  P9/P10 完整状态机实现（普通回零 HOMSEQ_*/ 紧急回零 EMH_*/ 动态自检 ST_*/
  维护建零 CAL_*/ 调理 CONDSEQ_*/ 停止降落 STOPSEQ_*）此前已编写完成，
  其工作变量已上移为 GVL_Internal 全局（tr* 前缀，共 52 个，含 8 组轴数组），
  但实现本体在一次编辑事故中丢失且无备份可恢复，现以可编译骨架占位，
  需依据 PLC程序开发计划.md P9/P10 与 GVL_CONST 步骤常量重新落地。
  ----------------------------------------------------------------------------
  唯一写入：iPhase（任务内阶段上报）、iBlockReason（阻塞原因）；任务级
            Cmd/Motion（HMI 各轴/推杆 Cmd 与 Motion 参数块）；故障经 gFaultSubmit。
  读入：  iState（MODE_MANAGER）、trig* 命令边沿、内部运行区参数、HMI.<Axis>.Status。
  分派：按 iState 调度 SELFTEST(5)/HOMING(40)/CALIBRATE(45)/SOFT_ESTOP(110) 任务；
        AUTORUN(20) P10。任务模块只写任务级命令与 Motion 参数块，MC 指令由
        OUTPUT_ADAPTER 唯一执行；不直接切 iState。
  H5U 约定：①无过程调用，故障上报内联赋值；②VAR_TEMP 仅声明区（本块不用）；
        ③CASE 标签用字面整数 + 行尾注释；④任务级步骤常量见 GVL_CONST HOMSEQ_*/
        EMH_*/ST_*/CAL_*（仅消除魔法数字，CASE 仍写字面码）。
  轴序：内部下标 i=1 Chest冲击(HMI.ChestImpact) / 2 Seat扭角(HMI.SeatTwist) /
        3 Leg转角(HMI.LegAngle)；故障轴号 gFaultSource=AXIS_ID_CHEST/SEAT/LEG。
  工作变量：全部上移全局 tr*（见 GVL_Internal.st PRG_TaskRunner 分组）；
        边沿实例 rDoneEdge/rFootEdge(TRIG.R_TRIG) 重建时声明于局部 VAR。
==========================================================================*)
PROGRAM PRG_TaskRunner
VAR
    (* 重建时在此仅声明功能块实例 / TRIG.R_TRIG 边沿实例（H5U 局部 VAR 允许）；
       简单工作变量一律使用 GVL_Internal 的 tr* 全局，不得在此声明。 *)
END_VAR

(* H5U：CASE 标签须用字面整数（具名常量按变量处理会报错），行尾注释码值 *)
CASE iState OF
    10: // ST_STANDBY
        (* TODO P6/P10: 就绪态等待启动；快速启动/自动流程入口门控 *)
        iPhase := 0;

    20: // ST_AUTORUN
        (* TODO P10(重建): FBI_Cond（调理/治疗）/ FATIGUE（老化）状态机
           105 启动前检查 → 108 等待准备 → 110 成角 → 120 等确认
           → 130 三轴 16 段联动 → 140 安全降落 → 800 完成 / 900 异常 *)
        ;

    5: // ST_SELFTEST
        (* TODO P9(重建): 动态自检 Step10→100/200（推杆参考检查→成角→三轴 ±2°→回零） *)
        ;

    40: // ST_HOMING
        (* TODO P9(重建): 普通回零 HOMSEQ_*（三轴 MoveAbs 回初始位）；
           紧急回零 EMH_* 在 SOFT_ESTOP(110) 内 *)
        ;

    45: // ST_CALIBRATE
        (* TODO P8/P9(重建): 推杆校准 / 维护建零 CAL_*（6 重门控后 MC_Home/标定） *)
        ;

    50: // ST_RESET
        (* TODO P9(重建): 故障复位收口：清错误、回初始位、完成后回 STANDBY（由 ModeManager 切） *)
        iPhase := 0;

    60, 110, 120: // ST_STOPPING / ST_SOFT_ESTOP / ST_HARD_ESTOP
        (* 安全收口由 SAFETY_MANAGER / POWER / OUTPUT_ADAPTER 执行，任务层不动作 *)
        ;
ELSE
    (* 0 INIT / 3 READY_CHECK / 30 SERVICE / 15 SERVICE_REQUIRED / 998 PARAM_LIMITED：P6/P11 补 *)
    ;
END_CASE;
END_PROGRAM
