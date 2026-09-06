(*============================================================================
  PRG_InputAdapter —— 层 10 输入：硬接线 I/O 镜像 + HMI 命令解析（扫描链第 2 环）
  ----------------------------------------------------------------------------
  唯一写入：io* I/O 镜像、diAdRaw/bAdValid、trig* 脉冲位（局部 R_TRIG.Q 转写）、
            bPauseLevel/bResumeLevel/bFootSignal 电平镜像；
            HMI 脉冲命令位回清（只清目标位，保留同字反馈位）。
  读入：  物理 I_Estop1/I_Estop2/I_SafeRelay/I_ResetBtn/I_PusherOrigin、IW_PusherAd、
          HMI.Condition.Cmd.*、HMI.Sys.Cmd.*、各轴/推杆 Cmd。
  P1：I/O 去抖镜像、调理命令字边沿锁存、AD 有效判定。
  P2：Sys.Cmd/轴 Cmd/推杆 Cmd 全部脉冲位边沿与电平镜像、命令位回清。
==========================================================================*)
PROGRAM PRG_InputAdapter
VAR
    (* H5U 定时器为内联指令 TONR(IN:=,PT:=,Q=>布尔位)，无需声明 TON 实例；
       下列 tXxxDb 即 TONR 的 Q=> 输出 BOOL（去抖结果）。 *)
    tEstop1Db    : BOOL;   (* 急停通道1 去抖输出（X2 常闭） *)
    tEstop2Db    : BOOL;   (* 急停通道2 去抖输出（X3 常闭） *)
    tSafeRelayDb : BOOL;   (* 安全继电器去抖输出（X4 常开） *)
    tOriginDb    : BOOL;   (* 推杆原点传感器去抖输出（X5） *)
    tResetDb     : BOOL;   (* 复位按钮去抖输出（X7） *)
    tDbTime      : TIME := T#30MS;
    (* 上升沿检测：H5U 类型为 TRIG.R_TRIG（功能块实例，仅局部 VAR 可声明），
       .Q 每扫转写全局 BOOL 脉冲位；全局 GVL 不支持功能块实例。 *)
    rTrigStart      : TRIG.R_TRIG;   (* S1 启动流程 *)
    rTrigChengJiao  : TRIG.R_TRIG;   (* S2 开始成角 *)
    rTrigAllow      : TRIG.R_TRIG;   (* S3 确认 *)
    rTrigStop       : TRIG.R_TRIG;   (* 停止 *)
    rTrigReset      : TRIG.R_TRIG;   (* 复位错误 *)
END_VAR

(*--- 硬接线 I/O 去抖镜像 ---*)
(* 急停：双通道常闭（I_Estop1/I_Estop2=TRUE 正常）+ 安全继电器常开
   （I_SafeRelay=TRUE=拍下）。三者均去抖后合成 ioEstopOK：
   任一通道断开或安全继电器动作 → ioEstopOK=FALSE → SafetyManager 硬急停。 *)
TONR(IN := I_Estop1,    PT := tDbTime, Q => tEstop1Db);
TONR(IN := I_Estop2,    PT := tDbTime, Q => tEstop2Db);
TONR(IN := I_SafeRelay, PT := tDbTime, Q => tSafeRelayDb);
ioEstopOK := tEstop1Db AND tEstop2Db AND NOT tSafeRelayDb;
(* TODO P4: 两通道不一致诊断（通道粘连/断路）上报安全故障。 *)

TONR(IN := I_PusherOrigin, PT := tDbTime, Q => tOriginDb);
ioPusherOrigin := tOriginDb;

TONR(IN := I_ResetBtn, PT := tDbTime, Q => tResetDb);
ioResetBtn := tResetDb;

(*--- 扩展 AD：原始值 + 有效窗口判定（限值在推杆参数加载后可用，P8 完善） ---*)
diAdRaw  := INT_TO_DINT(IW_PusherAd);
bAdValid := TRUE;   (* TODO P8: 按 HMI.TailTilt.Config.diAdMin/diAdMax 判定窗口 *)

(*--- 调理命令字脉冲边沿：局部 R_TRIG 检测，.Q 转写全局 BOOL 位（本扫有效） ---*)
rTrigStart(CLK      := HMI.Condition.Cmd.S1_StartProcess);
rTrigChengJiao(CLK  := HMI.Condition.Cmd.S2_StartChengJiao);
rTrigAllow(CLK      := HMI.Condition.Cmd.S3_AllowSignal);
rTrigStop(CLK       := HMI.Condition.Cmd.bStop);
rTrigReset(CLK      := HMI.Condition.Cmd.bReset);
trigStart     := rTrigStart.Q;
trigChengJiao := rTrigChengJiao.Q;
trigAllow     := rTrigAllow.Q;
trigStop      := rTrigStop.Q;
trigReset     := rTrigReset.Q;

(*--- 电平命令直接镜像 ---*)
bPauseLevel  := HMI.Condition.Cmd.bPause;
bResumeLevel := HMI.Condition.Cmd.bResume;
bFootSignal  := HMI.Condition.Cmd.bSignal;   (* 脚踏无独立物理点（CSV 未定义），仅取 HMI 信号 *)

(* TODO P2:
   - Sys.Cmd 各 *Req 脉冲位 R_TRIG（bHomingReq/bStopReq/bResetReq/bEmergencyStopReq/
     bInitializeReq/bCalibrateReq/bStartSelfTestReq/bAllPowerOnReq/...）；
     电平位直接镜像（bServiceAuthConfirm/bNoLoadConfirm/bRevalidateParams）。
   - 三轴 Cmd（bEnable/bReset/bZeroCommission/bStop/bMoveAbs/bMoveRel/bAutoMove/
     bMoveBuffer/bRequestDisable）与推杆 Cmd（bCalibrate/bHome/bAutoMove/bManualPreset/
     bResetError）的边沿/电平分类处理。
   - 脉冲位消费后回清 HMI 命令字：只清目标位，保留同字反馈位
     （如 Condition.Cmd 字内 bPpad 与 Status 不同字，清命令字不碰状态字）。
   - 摇杆/点动电平（bJogPos/bJogNeg/bJogUp/bJogDown）按住有效，离态由
     CmdPreclear 清残留。 *)
END_PROGRAM
