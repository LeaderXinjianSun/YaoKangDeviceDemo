(*============================================================================
  PRG_ParamService —— 层 30 任务：参数管理服务（扫描链第 8 环）
  ----------------------------------------------------------------------------
  唯一写入：内部参数运行区/编辑缓冲/Retain（P5 建内部模型结构体）；
            各 ConfigCmd 的 bSuccess/bError/iErrorCode 回令；身份块
            HMI_DeviceIdentity / HMI_DeviceIdentityWrite。
  读入：  HMI.*.ConfigCmd（bLoad/bApply/bSave/bResetDefault）、
          HMI_DeviceIdentityWrite.Cmd（身份块仅 bLoad/bApply）。
  三区模型：运行区（生效）/ 编辑缓冲（HMI 线上编辑区）/ Retain（断电保持）。
  P1：骨架。
  P5：FC_ValidateParams 校验拒绝（返回 iParamError+轴+字段三元组）、
      工厂默认、运行中锁存快照、Retain（含 bZeroCommissioned）。
  P11：设备身份 Load/Apply，非法/锁定报 5005/5006；D1000 镜像 + MAC 回填。
==========================================================================*)
PROGRAM PRG_ParamService
VAR
END_VAR

(* TODO P5: 统一处理 5 个 Stru_ConfigCmd 实例：
     HMI.Condition.ParamCmd / HMI.TailTilt.ConfigCmd /
     HMI.ChestImpact.ConfigCmd / HMI.SeatTwist.ConfigCmd /
     HMI.LegAngle.ConfigCmd / HMI.HomingParams.Cmd
   脉冲位由 INPUT_ADAPTER 的 R_TRIG 解析后（P2 补 trig），按：
     bLoad   : 运行区 → 编辑缓冲（HMI 线上区）
     bApply  : 编辑缓冲 → FC_ValidateParams 校验 → 通过则覆盖运行区，失败回 iErrorCode
     bSave   : 运行区 → Retain
     bResetDefault : 工厂默认 → 运行区/缓冲
   回令：成功置 bSuccess、失败置 bError+iErrorCode，命令位由 InputAdapter 回清。 *)

(* TODO P11: 设备身份（D1000–D1013）
   - 每扫回填只读镜像 HMI_DeviceIdentity：
       diDeviceNoRaw := Retain 设备编号；
       iMacWord0/1/2 := _Ethernet.MACAddress[0..2]（H5U 系统变量，P11 核对名称）。
   - HMI_DeviceIdentityWrite.Cmd：bLoad 回读当前编号；bApply 校验+权限/锁定
     判定后写入 Retain，失败回 bError + 5005（锁定）/5006（非法）。 *)
END_PROGRAM
