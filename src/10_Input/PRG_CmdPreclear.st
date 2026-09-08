(*============================================================================
  PRG_CmdPreclear —— 层 10 输入：命令残留清理（扫描链第 1 环，每扫最早执行）
  ----------------------------------------------------------------------------
  职责（P2 落地）：
    1) 脉冲位每扫兜底清扫：上一扫描周期由 INPUT_ADAPTER 锁存的全部内部脉冲位
       （trig*/axisPulse*，单扫有效）在本环统一清 FALSE；随后第 2 环
       INPUT_ADAPTER 再按本扫 R_TRIG 边沿刷新。这样下游任何一环都不会看到
       跨扫描残留的脉冲（即便上一扫无人消费，也不会误触发到下一扫）。
    2) 电平命令离态清残留（钩子）：电平镜像位（bPauseLevel/axisJogPos/
       jogPushUp/bServiceAuthConfirm…）由 INPUT_ADAPTER 每扫直接镜像，
       HMI 松开即随镜像回落，正常无残留；任务模块离态时若仍需强制收口
       （如退出 SERVICE 后点动必须断开），由 MODE_MANAGER 状态门控实现，
       本程序保留兜底钩子与注释，P6/P7/P8 按需要补写。
  唯一写入：全部内部命令脉冲位（清扫语义，不产生命令）。
  不碰：HMI D 区命令字（回清归 INPUT_ADAPTER）、电平镜像位（归 INPUT_ADAPTER）。
==========================================================================*)
PROGRAM PRG_CmdPreclear

(*--- 1. 调理区脉冲位兜底清扫（INPUT_ADAPTER 本扫随后刷新） ---*)
trigStart       := FALSE;
trigChengJiao   := FALSE;
trigAllow       := FALSE;
trigStop        := FALSE;
trigReset       := FALSE;
trigSkipAngle   := FALSE;

(*--- 2. 系统区脉冲请求位兜底清扫 ---*)
trigServiceMode     := FALSE;
trigSysHoming       := FALSE;
trigSysStop         := FALSE;
trigAutoStart       := FALSE;
trigCalibrate       := FALSE;
trigSysReset        := FALSE;
trigAckError        := FALSE;
trigEmgStop         := FALSE;
trigInitialize      := FALSE;
trigSvcMechHome     := FALSE;
trigSelfTestConfirm := FALSE;
trigSelfTestSkip    := FALSE;
trigAllPowerOff     := FALSE;
trigAllPowerOn      := FALSE;
trigStartSelfTest   := FALSE;
trigServiceDone     := FALSE;
trigReadyCheck      := FALSE;
trigQuickStart      := FALSE;
trigForceSkipST     := FALSE;
trigClearZeroRetain := FALSE;
trigLearnBias       := FALSE;

(*--- 3. 推杆脉冲位兜底清扫 ---*)
trigPushStop        := FALSE;
trigPushReset       := FALSE;
trigPushCalibrate   := FALSE;
trigPushAutoMove    := FALSE;
trigPushHome        := FALSE;
trigPushPreset      := FALSE;
trigPushResetError  := FALSE;

(*--- 4. 三轴脉冲位数组兜底清扫（电平 axisEnableReq/axisJogPos/axisJogNeg 不扫） ---*)
FOR cpIAxis := 1 TO 3 DO
    FOR cpICmd := 1 TO AXCMD_MAX DO
        axisPulse[cpIAxis, cpICmd] := FALSE;
    END_FOR;
END_FOR;

(*--- 5. 电平命令离态清残留钩子 ---
   电平镜像位由 INPUT_ADAPTER 每扫从 HMI 直接镜像，松开自然回落；
   以下场景的"强制收口"不在这里做（避免双写源），留待对应阶段：
   - 退出 SERVICE / 急停 / 停止后点动必须断开 → MODE_MANAGER 状态门控（P6）
     或 OUTPUT_ADAPTER 输出使能条件（P7/P8）中按状态屏蔽 axisJogPos/
     axisJogNeg/jogPushUp/jogPushDown；
   - 维护授权/无负载确认离态 → 建零门控每扫重判（P9），电平镜像本身已回落。 *)
END_PROGRAM
