(*============================================================================
  PRG_Main —— 主扫描（唯一任务入口，固定调用链，顺序不可调整）
  ----------------------------------------------------------------------------
  扫描链（开发计划 P1）：
    1  PRG_CmdPreclear    命令残留清理：每扫首环兜底清全部内部脉冲位（P2 落地）
    2  PRG_InputAdapter   I/O 镜像去抖 + HMI 命令解析（R_TRIG 锁存脉冲/镜像电平 + HMI 脉冲位回清）
    3  PRG_Monitor        AD/传感器采集与 plausibility 诊断
    4  PRG_ErrorManager   错误唯一写入：活动错误/警告/历史队列
    5  PRG_SafetyManager  安全独立常驻：急停链/防夹/超力/堵转/限位
    6  PRG_ModeManager    系统状态机：iState 唯一写入（13 态仲裁）
    7  PRG_TaskRunner     任务分派：AUTORUN/SELFTEST/HOMING/CALIBRATE/RESET
    8  PRG_ParamService   参数三区 + ConfigCmd + 设备身份（P5/P11）
    9  PRG_Power          伺服上下电分时管理：轴使能唯一写入
    10 PRG_OutputAdapter  执行器 + MC 指令唯一调用点（3×M900 / 推杆）
    11 PRG_HmiOutput      内部状态 → D 区回填（最末环，不碰命令位）

  单写源：每个对外变量唯一写入者，见各程序头注释。
  HMI 映射：HMI AT %MW200（Stru_HMI）、HMI_DeviceIdentity AT %MW1000、
            HMI_DeviceIdentityWrite AT %MW1010（见 GVL_HMI.st）。
==========================================================================*)
PROGRAM PRG_Main

(*--- 扫描看门狗（预留状态位 mnTScanWatchdog）：
      真实周期看门狗为 H5U 任务组态/控制器硬件功能（扫描周期超时由控制器停机/进安全态），
      应用层单扫描任务无法用定时器自测周期超时（超时当扫不执行即无法上报；恒 IN 定时器
      反而会每开机 50ms 恒触发误报，故原内联 TONR 已移除）。
      现场处置策略待确认：若组态提供看门狗超时系统变量/特殊任务可置 mnTScanWatchdog，
      SAFETY_MANAGER 已接上升沿上报 1007(ERR_SCAN_WATCHDOG, Critical)。
      （H5U 定时器为内联指令 TONR(IN:=,PT:=,Q=>布尔位)，无需 TON 实例。） ---*)

(*--- 固定扫描链 ---*)
PRG_CmdPreclear();
PRG_InputAdapter();
PRG_Monitor();
PRG_ErrorManager();
PRG_SafetyManager();
PRG_ModeManager();
PRG_TaskRunner();
PRG_ParamService();
PRG_Power();
PRG_OutputAdapter();
PRG_HmiOutput();
END_PROGRAM
