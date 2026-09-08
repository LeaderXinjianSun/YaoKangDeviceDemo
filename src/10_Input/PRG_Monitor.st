(*============================================================================
  PRG_Monitor —— 层 10 输入：物理量采集与 plausibility 监视（扫描链第 3 环）
  ----------------------------------------------------------------------------
  唯一写入：尾板推杆反馈块 HMI.TailTiltAdFeedback 的 mm 位置/有效位
            （diPosMm/bPosValid，镜像 GVL_Internal rPusherPosMm/bPusherPosValid，
             源自 HC_Counter）；几何解算角度 rAngle 由 OUTPUT_ADAPTER（环10）在
             fbPusher 调用后回填（角度在环10 才算出，环3 不写）；扫描心跳 diScanCount。
  读入：  rPusherPosMm/bPusherPosValid、ioPusherOrigin（诊断由 FB_PusherControl 落地）。
  说明：不产生状态机切换，只提供诊断数据与故障请求（经 ERROR_MANAGER 上报）。
  P1：心跳计数 + 推杆 mm 位置/有效位镜像到 D936–D940 窗口。
==========================================================================*)
PROGRAM PRG_Monitor

(*--- 扫描心跳 + 毫秒运行刻度（事件时间戳源；非日历 RTC，见 GVL_Internal diMsTick 说明） ---*)
diScanCount := diScanCount + 1;
diMsTick    := diMsTick + SCAN_PERIOD_MS;

(*--- 推杆反馈窗口（D936–D940）：mm 位置/有效位镜像（HC_Counter，环2 采集） ---*)
HMI.TailTiltAdFeedback.diPosMm   := REAL_TO_DINT(rPusherPosMm);
HMI.TailTiltAdFeedback.bPosValid := bPusherPosValid;
(* rAngle（几何解算角度）由 OUTPUT_ADAPTER（环10）fbPusher 之后回填，本环不写 *)

(* 传感器与轴诊断落点（P8/P9 已落地，本程序不重复写）：
   - 原点传感器卡死 ON/OFF、与角度一致性 → FB_PusherControl §6.4 诊断
     写 bHomeSensorHealthy/StuckOn/StuckOff/bHomePlausible，异常报 3021/3022/3023。
   - 编码器故障 → OUTPUT_ADAPTER 镜像各轴 Servo.bEncoderFault；
     三轴汇总 bAbsPositionValid 由 HMI_OUTPUT（环11）回填 Sys.Status。
   - 伺服轴实际位置/速度/扭矩 → OUTPUT_ADAPTER 从 MC 轴结构体镜像。 *)
END_PROGRAM
