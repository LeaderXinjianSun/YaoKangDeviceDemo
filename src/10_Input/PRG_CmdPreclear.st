(*============================================================================
  PRG_CmdPreclear —— 层 10 输入：命令残留清理（扫描链第 1 环）
  ----------------------------------------------------------------------------
  脉冲命令由 INPUT_ADAPTER 用 R_TRIG 锁存（gTrig*），边沿输出天然只存活
  一个扫描周期，业务模块在本扫后置环节直接消费，无需全局请求位清零。
  本程序职责（P2 完整落地）：
    1) 电平命令离态清残留：HMI 电平位已 FALSE 但内部执行/输出仍 TRUE 时，
       清执行侧（点动 JogPos/JogNeg、维护授权 bServiceAuthConfirm、
       无负载确认 bNoLoadConfirm、参数重校验 bRevalidateParams 等）。
    2) 扫描链最前的兜底清理钩子。
  P1 骨架：空占位 + TODO。
==========================================================================*)
PROGRAM PRG_CmdPreclear
VAR
END_VAR

(* TODO P2: 电平命令离态清残留
   IF NOT HMI.ChestImpact.Cmd.bJogPos THEN <内部点动执行位清 FALSE>; END_IF;
   ...（三轴 + 推杆 bJogUp/bJogDown + 维护授权/无负载确认） *)
