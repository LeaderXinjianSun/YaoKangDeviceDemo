(*============================================================================
  PRG_Monitor —— 层 10 输入：物理量采集与 plausibility 监视（扫描链第 3 环）
  ----------------------------------------------------------------------------
  唯一写入：尾板 AD 反馈块 HMI.TailTiltAdFeedback（rAdAngle 由 P8 拟合写入）；
            原点传感器健康诊断内部位（P8/P9 完善）；扫描心跳 diScanCount。
  读入：  diAdRaw/bAdValid、ioPusherOrigin、HMI.TailTilt.Config（AD 限值/拟合系数）。
  说明：不产生状态机切换，只提供诊断数据与故障请求（经 ERROR_MANAGER 上报）。
  P1：心跳计数 + AD 原始值/有效位镜像到 D936–D940 窗口。
==========================================================================*)
PROGRAM PRG_Monitor
VAR
END_VAR

(*--- 扫描心跳 ---*)
diScanCount := diScanCount + 1;

(*--- AD 反馈窗口（D936–D940）：原始值与有效位先镜像，角度拟合 P8 落地 ---*)
HMI.TailTiltAdFeedback.diAdRaw  := diAdRaw;
HMI.TailTiltAdFeedback.bAdValid := bAdValid;
(* HMI.TailTiltAdFeedback.rAdAngle := <三次拟合 K0..K3，P8>; *)

(* TODO P8/P9:
   - 尾板角度 AD 三次拟合（rFitK0..K3）+ 跳变保护 rAdJumpLimitDeg。
   - 原点传感器卡死 ON/OFF 检测、与角度一致性 plausibility
     → bHomeSensorHealthy/StuckOn/StuckOff/bHomePlausible，异常报 3021/3022/3023。
   - 编码器故障/绝对位置有效性汇总（bAbsPositionValid）。
   - 伺服轴实际位置/速度/扭矩由 OUTPUT_ADAPTER 从 MC 轴结构体镜像。 *)
END_PROGRAM
