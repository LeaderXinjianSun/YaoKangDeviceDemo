# 腰康复仪 PLC 重构开发计划

> 配套文档：《HMI-PLC地址分配表.md》《PLC重构需求-HMI控制与交互.pdf》
> 平台：汇川 H5U A8 PLC + 3× M900 伺服（CiA402 Motion Control，EtherCAT 总线，PLCopen MC）+ 1 路电推杆（开关型）+ 扩展 AD 板卡
> 上位：HMI 调试工作站（Modbus TCP，与旧工程 HMI 共用同一寄存器布局）
> 寄存器布局权威：旧工程 InoProShop 变量表导出 `old/结构体/Stru_HMI_new.csv`（`Stru_HMI.csv` 为旧版参照），PLC 按 CSV 逐字段定义结构体并整体 `AT %MW200`，编译器自动打包对齐，布局即与 HMI 一致。

---

## 0. 开发总原则

1. **契约先行**：寄存器布局以旧工程变量表导出 `old/结构体/Stru_HMI_new.csv` 为准（已取得，等价替代 HMI 侧 `register-map.json`）。PLC 按 CSV 逐字段定义线上结构体并整体 `AT %MW200`，BOOL 按位打包、REAL/DINT 双字对齐由编译器完成，字段名/类型/顺序与 CSV 一致即布局冻结；仅 Modbus 传输字序留待联调首日样例值确认。
2. **主干优先、自底向上**：通信契约 → 扫描骨架/单写源 → 错误 → 安全 → 参数 → 状态机 → 单轴/电推杆 → 回零/自检 → 自动流程 → 权限身份 → 集成。
3. **安全独立**：SAFETY_MANAGER 不依赖业务状态，任何阶段都能强制停车；急停链路最早打通、最后放开。
4. **单写源硬约束**：每个变量唯一写入者（iState→MODE_MANAGER、Error→ERROR_MANAGER、bEnable→POWER、MC 指令→OUTPUT_ADAPTER）。任务模块只写任务级 Cmd/Motion，通过 FaultReq 提交故障。
5. **命令语义**：脉冲命令上升沿消费、每扫 L0 清理；电平命令按住有效、离态清残留。
6. **先仿真后台架再联机**：每层先在仿真/离线环境验证逻辑，再上伺服，最后带负载。急停、超力、堵转等保护必须在无人/无负载条件下先验证。

---

## 1. 阶段划分与里程碑

| 阶段 | 名称 | 主要交付 | 依赖 | 里程碑 |
|---|---|---|---|---|
| P0 | 工程准备与契约冻结 | 寄存器映射表核对版、工程框架 | — | **M0 契约冻结** |
| P1 | 程序骨架与扫描分层 | 分层调用框架、单写源骨架 | P0 | M1 框架可空跑 |
| P2 | 通信适配层 | INPUT_ADAPTER / HMI_OUTPUT / CMD_PRECLEAR | P1 | M2 HMI 能读写心跳 |
| P3 | 错误与诊断系统 | ERROR_MANAGER、队列、警告、码表 | P1 | M3 错误可上报 HMI |
| P4 | 安全防护层 | SAFETY_MANAGER、急停链、保护 | P3 | M4 急停链路打通 |
| P5 | 参数管理服务 | 三区模型、Retain、校验、ConfigCmd | P2/P3 | M5 参数可加载/应用/保存 |
| P6 | 系统状态机 | MODE_MANAGER、13 态、iPhase/BlockReason | P2–P5 | M6 状态可切换上报 |
| P7 | 三轴伺服控制 | POWER 分时上电、MC 封装、点动/定位、力估算 | P6 | M7 单轴可手动调试 |
| P8 | 电推杆控制 | 双参考、校准、堵转、AD 拟合 | P6 | M8 推杆可点动/定位 |
| P9 | 回零 / 紧急回零 / 自检 / 建零 | 四类维护流程 | P7/P8 | M9 自检与回零通过 |
| P10 | 调理 / 治疗 / 老化自动流程 | FBI_Cond、FATIGUE | P7/P8/P9 | M10 自动流程跑通 |
| P11 | 权限 / 设备身份 / 运行统计 | 角色权限、身份镜像、统计 | P5/P6 | M11 权限与身份就位 |
| P12 | 集成测试与验收 | 测试报告、联调签认 | 全部 | **M12 验收交付** |

---

## 2. 各阶段任务明细

### P0 工程准备与契约冻结
- ~~索取 register-map.json~~ **已完成**：以旧工程 InoProShop 变量表导出 `old/结构体/Stru_HMI_new.csv` 为寄存器布局权威（等价替代 HMI 侧 `register-map.json`）。按 CSV 逐字段定义线上结构体 `ST_W_HMI`（成员名/类型/嵌套层次与 CSV 完全一致），整体映射 `AT %MW200`（D200）；BOOL 按位打包、REAL/DINT 双字对齐由编译器自动完成，不手工核算偏移。已核实总长度 nBitLen=11856 bit = 741 字（D200–D940），与 InoProShop 变量表截图一致。
- ~~解决三轴块内偏移矛盾~~ **已完成**：CSV 中 `ChestImpact/SeatTwist/LegAngle` 三块同构结构体（块基址 D669/D741/D813，步距 72 字）即为权威字段顺序，需求书表格中的推算偏移矛盾作废。
- 联调首日待确认：DINT/REAL 的 Modbus 传输字序（高/低字排列），用样例值与 HMI 对拍（结构体内存布局不受影响）。
- 与 HMI 方裁决一处注释矛盾：CSV 中 `S1_StartProcess` 注释为「启动流程 (电平)」，而地址表 §3 按脉冲消费约定；PLC 侧 R_TRIG 取上升沿对两种下发方式均安全。
- 确定硬件选型：电推杆编码器类型（相对→需校准 / 绝对→裁剪校准与自检 Step30–40）；急停模式（0 硬断电 / 1 软减速）。
- 建立 H5U 工程：任务/程序组织、Retain 区规划、EtherCAT 总线与 M900（CiA402）轴配置、扩展 AD 配置、Modbus TCP 服务端映射。
- 定义全局类型库：线上结构体（按 CSV，ST_W_*）+ 内部模型结构体（LREAL/TIME/枚举，ST_*），三轴同构复用；适配层负责两类型层转换。
- **交付**：核对签认的地址映射表（已与 CSV 互验）、工程空框架、类型定义清单。
- **验收**：HMI 与 PLC 双方对地址表无异议；工程能下载空跑；下载后 InoProShop 变量表中 `HMI` 结构体 nBitLen 与基址 D200 与旧工程一致。

### P1 程序骨架与扫描分层
- 按固定顺序搭建主扫描调用链：
  `CMD_PRECLEAR → INPUT_ADAPTER → MONITOR → ERROR_MANAGER → SAFETY_MANAGER → MODE_MANAGER → TASK_RUNNER → PARAM_SERVICE → POWER → OUTPUT_ADAPTER → HMI_OUTPUT`
- 落地单写源规范：为每个对外变量指定唯一写入程序块，其余只读。
- 建立任务调度占位（TASK_RUNNER 按 iState 分派 AUTO/SELFTEST/HOMING/CALIBRATE/RESET）。
- 建立硬接线 I/O 镜像（INPUT_ADAPTER）：物理急停（常闭）、复位按钮、脚踏、原点传感器，含去抖。
- **交付**：可空跑的分层框架、I/O 镜像、看门狗/扫描周期监控。
- **验收**：框架下载无错；I/O 点状态在监控表可见；无多写冲突。

### P2 通信适配层
- HMI_INPUT：解析命令字（D200–201、D481–489、三轴 Cmd、D590、各 ConfigCmd）。
  - 脉冲命令：上升沿锁存为内部请求位，消费后清零；清命令字时只清目标位、保留同字反馈位。
  - 电平命令：直接镜像（点动、维护授权、无负载确认、参数重校验）。
- HMI_OUTPUT：将状态/错误/统计/参数按窗口回填 D 区（D459–478、D490–508、D509–589、轴状态块、推杆状态、D936–940、D567–577、D1000–1004）。
- CMD_PRECLEAR：每扫 L0 清理脉冲请求；离态清电平残留。
- 参数区读写窗口（D202–458、各 Config/Motion、D887–935、D606–659）与缓冲对接。
- **交付**：完整 D 区映射、命令边沿/电平处理、心跳/通信监视。
- **验收（M2）**：HMI 能读心跳/状态字；按钮命令在 PLC 监控里可见对应脉冲/电平；误写反馈位不被清除。

### P3 错误与诊断系统
- 错误条目结构：级别(0 Info/1 Warning/2 Critical)、错误码、来源模块码、子码（轴 9xxx / 驱动器 Er.xxx）、附加值×2、活动/致命/已升级/需手动复位位。
- ERROR_MANAGER 唯一写错误；任务经 FaultReq 提交。
- 当前活动错误（D578–584）、独立警告通道（D585–589）、环形历史队列（D509–566，约 8–9 条）。
- 错误码常量库 `CONST_Definitions.st`：1xxx 系统/急停、11xx 初始化/电源、12xx 紧急回零/防夹/跟随、13xx 自检、2xxx 三轴、3xxx 推杆（3021/3022/3023/3024、3101–3107）、4xxx 回零、5xxx 参数/身份（5005/5006）、7xxx 调理前检查。
- **交付**：错误管理器、码表、队列与警告通道。
- **验收（M3）**：人为触发若干错误，HMI 错误列表/顶部警告正确显示码与级别；队列按环形滚动。

### P4 安全防护层（SAFETY_MANAGER，独立常驻）
- 急停链：物理急停（常闭断开→HARD_ESTOP 断使能）、软急停 D488.9（无条件穿透最高优先级）→ SOFT_ESTOP（按 diSoftStopTime 减速）→ 停止超时或急停模式=0 升级 HARD_ESTOP。
- 扭矩防夹：Jog/紧急回零扭矩超阈→立即停 + 可控重试。
- 超力保护：牵引力估算超阈持续 diOverForceMs→锁存停机（阈值≤0 禁用）。
- 电推杆堵转：电流超阈 + 速度趋零持续→停 + 换向缓冲后按 iMaxRetries 重试。
- 限位：正/负硬限位、软限位→禁越限运动，提供脱限 Jog 速度。
- 编码器故障（SV630 Er.101/201/234 等）→ 绝对位置不可信标志，禁定位类动作。
- 原点传感器健康：卡死 ON/OFF、与角度一致性→3021/3022/3023，拒绝回零。
- 超时升级：各任务步骤超时→报错并安全收口（STOPPING/ESTOP）。
- **交付**：安全管理器、急停链状态、各类保护判定。
- **验收（M4）**：物理/软急停在任意状态即时生效；断使能/减速时序正确；保护触发后 HMI 状态与错误码正确；**无人无负载先行验证**。

### P5 参数管理服务（PARAM_SERVICE）
- 三区模型：运行区（生效）/ 编辑缓冲（HMI 编辑）/ Retain（断电保持）。
- 五类参数块：调理参数（D202–458，三轴 16 段+全局）、轴 Config（×3）、回零参数（D887–935）、推杆 Config（D606–659，含 AD 拟合 K0–K3）、系统参数。
- 统一 ConfigCmd：加载 / 应用 / 保存 / 恢复默认 / 加载默认；回写 bSuccess/bError/iErrorCode。
- FC_ValidateParams：应用前校验，非法拒绝并返回 iParamError + 轴 + 字段索引三元组；失败不破坏运行区。
- 工厂默认值内置（FC_Default*Config / FC_DefaultConditionParams）。
- 运行中锁存：AUTORUN 启动快照，运行中改参不生效。
- Retain：含 bZeroCommissioned 建零标志。
- **验收（M5）**：HMI 各参数页加载/编辑/应用/保存/恢复默认全通；非法参数被定位拒绝；断电重启 Retain 生效。

### P6 系统状态机（MODE_MANAGER）
- 13 个主状态：0 INIT、3 READY_CHECK、5 SELFTEST、10 STANDBY、15 SERVICE_REQUIRED、20 AUTORUN、30 SERVICE、40 HOMING、45 CALIBRATE、50 RESET、60 STOPPING、110 SOFT_ESTOP、120 HARD_ESTOP、998 PARAM_LIMITED。
- iState 由 MODE_MANAGER 唯一写；任务模块只上报 iPhase（任务内阶段）与 iBlockReason（阻塞原因），不直接切态。
- 状态切换仲裁 + 门控（角色/权限码/资格/安全条件）；离态清残留电平命令。
- READY_CHECK 六项资格位掩码 diReadyCheckResult（零点/参数/硬件/健康/位置/参考）。
- 系统状态汇总位（D490–508，约 22 位：bReady、bSafeToStart、全轴使能/参考有效/在初始位、急停中…）与健康等级(0–3)。
- **验收（M6）**：HMI 随 iState 切换界面权限；非法切换被门控拒绝；iPhase/BlockReason 正确反映进度。

### P7 三轴伺服控制
- POWER：全轴上电/断电命令，按 diPowerInterval 分时逐轴使能，bPoweringUp 上报；bEnable 唯一写者。
- OUTPUT_ADAPTER 内统一封装 MC 指令：MC_Power/Reset/Stop/Home/MoveAbsolute/MoveRelative/MoveJog（正负电平）/MoveBuffer（单轴最多 16 段）。
- 轴命令字（D702/D774/D846）11 位语义落地（使能/复位/标定/停止/绝对/相对/点动/自动/缓冲/断使能）。
- Motion 参数：目标位置/速度、点动速度、加/减速度、初始位、超时。
- 轴状态反馈（约 49 字）：伺服层（实际位置/速度/扭矩、轴码 9xxx、驱动器码 Er.xxx、16 状态位）+ 力估算层（正负扭矩静止基线、净扭矩、未滤波/低通牵引力 N、超力时长、力有效/基线已学/超力实时/锁存）+ 业务层。
- 扭矩基线学习（D489.9）。
- 软限位保护配合 P4。
- **验收（M7）**：工程师模式下三轴可分时上电、点动、绝对/相对定位、停止/复位；状态与力数据在 HMI 正确刷新；软限位生效。

### P8 电推杆（尾板成角）控制
- 输出 Q_Pusher_Up/Down（支持方向取反）；动作：上/下点动、回零、原点标定、自动定位到目标角、手动 Preset、回初始位。
- 双参考模式 iReferenceMode：0 = X10 脉冲 + 原点 HC；1 = AD 拟合角度（三次曲线 K0–K3）。AD 反馈 D936–940（拟合角、AD 原始值、有效位）。
- 校准流程（相对编码器时）：默认上行找原点；已压原点→先下行脱离→缓冲→上行精找→清零；上行撞顶堵转→缓冲换向→下行反找；全局超时 + 堵转；30ms 去抖后才推进清零；错误 3101–3107 按步骤细分；完成 bCalibrated=ON。未校准/参考无效禁自动定位（报 3024）。
- bHomed 与 bCalibrated 解耦。
- 保护：堵转、超时、角度软限位、换向缓冲、惯性补偿、AD 跳变保护。
- 状态 D592–603 全部位反馈。
- **验收（M8）**：点动/定位/回零/校准动作正确；两种参考模式角度一致；堵转/超时/传感器异常报错正确。

### P9 回零 / 紧急回零 / 自检 / 建零
- **普通回零（iState=40）**：三轴按回零参数 MoveAbs 回初始位，并行/顺序可选（iHomingExecMode），全流程超时，完成置全轴参考有效。
- **紧急回零（SOFT_ESTOP 内 SBR_EMERGENCY_HOME）**：先等 MC_Stop 全释放（释放超时守卫）→ 四段式 Jog（主 Jog 速度→接近区减速→微调速度→迟滞窗口判停）；扭矩防夹监控，超阈即停、重试上限 iMaxRetry；支持 bRequestDisable 断使能/恢复；推杆按参考模式回零/校准（bEmergencyAllowCalib 可关）；结果与诊断锁存。
- **动态自检（iState=5，Step10→100/200）**：门禁断言→等待安全确认（可跳过/工程师授权跳步）→推杆参考检查+校准（30s 超时 1303，绝对编码器可裁剪）→构建精简自检参数→成角→三轴 ±2° 单循环（8s/轴超时 1304）→成角回零→完成清四个脏标记；失败 Step200。
- **维护建零（工厂，6 重门控）**：工程师角色 + 维护授权确认（电平）+ 无负载确认（电平）+ 停稳 + 安全条件 + 参考无效/已清 Retain，全满足才允许 MC_Home/推杆标定；结果写 Retain bZeroCommissioned。
- **验收（M9）**：普通/紧急回零、自检 10 步、建零门控全部按序通过；门控不满足时拒绝执行；超时/防夹/重试行为符合需求。

### P10 调理 / 治疗 / 老化自动流程
- **FBI_Cond（模式 1 调理 / 2 治疗，步骤码经 D468）**：
  S1→105 启动前检查（急停/就绪/全轴参考/全轴在初始位/三轴使能/参数校验）
  →108 等待人员准备（S2 或跳过成角）
  →110 成角定位（推杆 AutoMove 到 rPusherPos）
  →120 等待开始确认（S3 或脚踏；信号模式=1 自动放行）
  →130 三轴 16 段轨迹×循环联动（统一信号同步；任一轴阻塞全线等待；暂停/恢复贯穿）
  →140 安全降落（推杆回初始位，bAtInit 判定）
  →800 完成；出错→900（区分紧急中止/手动停止）。
  外部介入优先级：急停 > 停止 > 安全降落。
- **老化 FATIGUE（模式 3）**：复用调理流程，PLC 自动驱动 S1/S2/S3，按 diBatchCount 连跑多批、批间 diBatchInterval；要求信号模式=自动(1)，运行中模式锁定；批次进度/剩余时间上报（D459–478、D567–577）。
- 调理命令字 D200–201（S1/S2/S3/停止/脚踏/复位/暂停恢复/跳过成角/Ppad）与 17 个调理状态位落地。
- **验收（M10）**：单批调理全流程走通；暂停/恢复/停止/急停在各步正确介入；老化多批自动连跑与进度上报正确。

### P11 权限 / 设备身份 / 运行统计 —— **已完成**
- 双角色：操作员（运行调理、快速启动）/ 工程师（服务、手动运动、建零、参数维护）；角色 + 权限码 16#5A 双重防护；登录写码、退出写 0。（角色码按地址表对齐为 0=操作员/1=工程师；bEngineer 双重门控）
- 快速启动（需 bSkipSelfTestAllowed）/ 强制跳过自检（需 bForceSkipSelfTestAllowed）资格位。
- 设备身份（结构体以旧工程导出 CSV 为准）：D1000–1004 Stru_HMI_DeviceInfo 只读镜像（diDeviceNoRaw DINT + iMacWord0/1/2 三字，MAC 取 `_Ethernet.MACAddress`）；D1010–1013 Stru_HMI_DeviceIdentityWrite 维护写入（Cmd.iErrorCode + bLoad/bApply/bSuccess/bError + diDeviceNoRaw DINT，命令仅 Load/Apply）；非法/锁定报 5005/5006。
- 运行统计 D567–577：老化循环、总循环、运行时长、当前步骤/循环、批量完成位。
- **验收（M11）**：越权操作被拒；身份读写与报错正确；统计随运行累计。

### P12 集成测试与验收 —— **代码侧已完成（现场测试待执行）**
- **代码侧集成收尾（已完成）**：
  1. HmiOutput 全窗口状态位回填：错误四字镜像（iErrorCode/iErrorLevel/iErrorSubCode/iErrorSource←Sys.Error）、初始化/参数态（bInitialized/bParamInitialized/bParamError）、轴汇总（bAllAxesReferenced/bAnyAxisAtLimit 六限位或/bAbsPositionValid 三编码器故障非或）、bTailSensorAtBoot、bSensitiveRunning（成角110/治疗130）；diUpTime 改毫秒（diScanCount×10）。
  2. 自检跳过标志链路：TaskRunner 局部 bSelfTestSkipped（态5入口清/跳分支置/步100 写 bHealthCheckSkipped）；bSelfTestDone 态5入口重入清零。
  3. 全工程 H5U 三约定终检通过：无 TON 实例（仅内联 TONR）、TRIG.R_TRIG 全在局部 VAR、CASE 标签全字面整数、无过程调用语句、全局无 FB 实例。
  4. 4 张变量表 + 2 张 FB 接口表与 ST 总同步复核一致。
- **遗留现场/契约项（代码内已注释标注，不臆造）**：1006 通信超时待 HMI 心跳寄存器契约（地址表未定义）；1007 看门狗超时处置策略待现场确认；力估算常量台架标定（GVL_CONST L184）；M900 编码器反馈类报警 Er.xxx 码表台架填码（FB_AxisControl §1.1 bEncFltMatch 钩子，默认断开不误保护）；日历 RTC 库 FB 现场引入替换 diMsTick（错误时间戳现为上电毫秒刻度）；_Ethernet.MACAddress 系统变量名现场核对。
- **代码侧已闭环（本批提交）**：iBlockReason 4501–4509 常量化 + ModeManager 写入（e12805c）；编码器故障锁存 bEncFltLatch 接通 2002/绝对位置不可信链 + 离散定位运动用时完成时锁存 diMoveTimeLatch；diMsTick 毫秒刻度（MONITOR 累加 SCAN_PERIOD_MS）替换错误队列时间戳。
- **分级测试**：
  1. 离线仿真：状态机、命令边沿/电平、参数校验、错误队列逻辑。
  2. 台架空载：伺服上电/点动/定位、推杆动作、急停链、限位/堵转/防夹。
  3. 联机联调：与 HMI 逐窗口核对所有寄存器、按钮、状态位、参数页。
  4. 带载/模拟患者：完整调理、老化连跑、异常注入（急停/超力/堵转/编码器故障/传感器卡死）。
- **回归用例**：覆盖 13 状态切换、6 重建零门控、自检 10 步、错误码全段、参数三区、断电保持。
- 安全项必须做失效测试（拔急停、断传感器、超力注入）。
- **交付**：测试报告、问题闭环、HMI 联调签认、版本归档。
- **验收（M12）**：需求书各章条目逐项签认；HMI 全功能可用；安全保护全部验证通过。

---

## 3. 建议开发顺序（依赖视角）

```
P0 契约冻结
  └─ P1 骨架/分层
       ├─ P2 通信适配（HMI 能读写）
       ├─ P3 错误系统
       │    └─ P4 安全层（急停先通）
       ├─ P5 参数服务
       └─ P6 状态机（主干）
            ├─ P7 三轴 ─┐
            └─ P8 推杆 ─┴─ P9 回零/自检/建零
                              └─ P10 自动流程
            P11 权限/身份/统计（可与 P7–P10 并行）
                 └─ P12 集成验收
```

---

## 4. 关键风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| ~~register-map.json 未拿到~~ / 结构体字段与 CSV 不一致 | 通信映射错位、HMI 读写乱码 | 布局权威已改为旧工程导出 `Stru_HMI_new.csv`：线上结构体逐字段照抄 CSV 并整体 `AT %MW200`，编译后核对 nBitLen=11856、基址 D200 与旧工程变量表一致；不手工排偏移 |
| Modbus 字序/双字排列理解错 | DINT/REAL 乱码 | P0 用样例值与 HMI 联调确认高低字序 |
| 电推杆编码器类型未定 | 校准/自检流程取舍 | P0 确认硬件；相对则做校准，绝对则裁剪并同步自检步 |
| 单写源被破坏（多块写同一变量） | 状态/安全不可控 | 框架期固化写入者规范，评审 + 交叉检查 |
| 安全保护在带载后才验证 | 人员/设备风险 | 急停/超力/堵转/防夹在空载台架先验证，注入失效测试 |
| 自动流程中暂停/停止/急停时序复杂 | 动作粘滞/收不住 | 离态清电平、MC_Stop 释放守卫、安全收口统一走 SAFETY_MANAGER |
| Retain 布局变更 | 断电保持丢失/错位 | Retain 变量集中管理，版本变更做迁移与默认值兜底 |

---

## 5. 编码与评审规范要点

- **汇川 H5U 平台语法约定（与标准 IEC 61131-3 写法不同，全工程强制，勿再按 IEC 惯例写）**：
  - **★数组下标一律 base 0（从 0 开始）**：声明统一用"个数语法" `类型[N]`（N 个元素，合法下标 0..N-1），一维如 `BOOL[3]`/`REAL[16]`、二维如 `BOOL[3, 8]`（3 轴 × 8 命令）；**不要写** `[1..3]`/`[1..3,1..8]` 这类范围语法。轴数组内部下标固定 `0=Chest 冲击 / 1=Seat 扭角 / 2=Leg 转角`；命令维 `AXCMD_RESET..AXCMD_REQ_DISABLE = 0..7`（`AXCMD_MAX` 保持 8 表个数，上界循环写 `TO AXCMD_MAX-1`）。FOR 循环从 0 起（`FOR i := 0 TO N-1`）；段表游标 0=首段、推进边界 `IF iBufSeg < (iSegCount-1)`。
    - **"无活动轴"哨兵用 -1**（base 0 后合法区间 0..2，旧哨兵 4 废弃）；判活/判终 `>= 0` / `< 0`，用游标索引数组前须加 `>= 0` 防护。
    - **严格区分"数组下标（改 base 0）"与"协议码/状态码（严禁误改）"**：`AXIS_ID_CHEST=1/LEG=2/SEAT=3/TAIL=4`（故障来源/轴号线协议）、`oaISel` 故障源选择码、`pwIPwrStep` 上电步号、`FC_ValidateParams` 入参 `iBlock=1..6`、`iErrField` 协议字段号、状态机步号（105/130/4000…）等是**协议/状态码，不是数组下标，保持原值不动**。内部游标当协议轴号上报时须显式映射（0→AXIS_ID_CHEST、1→AXIS_ID_SEAT、2→AXIS_ID_LEG，因 Seat=3/Leg=2 与下标不一致，直接赋值属 bug）。
  - **★PRG/FC 不允许局部简单变量，一律上移为全局变量**：H5U 编辑器不接受 PROGRAM/FUNCTION 内的局部 BOOL/INT/DINT/REAL 等简单变量，须声明到 GVL（命名加块前缀，如 `cpIAxis`/`psI`/`trDiSnap`）。**唯一例外**：边沿功能块实例 `TRIG.R_TRIG`/`TRIG.F_TRIG` 只能在 PROGRAM/FUNCTION_BLOCK 的**局部 VAR** 声明（全局 GVL 不支持 FB 实例）。
  - **★定时器不支持 TIME 类型，PT 为 DINT 毫秒**：平台无 TIME/T# 字面量，定时一律内联 `TONR`，`PT` 传 **DINT 毫秒数**（如 `PT := 300` 表 300ms，或用 DINT 变量/`SCAN_PERIOD_MS` 换算），**禁止** `T#300ms`/`TIME` 变量。定时结果由 `Q=>` 直接落到一个 **BOOL** 变量：
    `TONR(IN := <条件>, PT := <DINT毫秒>, R := <复位>, Q => <BOOL位>, ET => <DINT>);`
    定时器位声明为全局 BOOL（如 `iaTEstop1Db`），调用后**直接读该 BOOL**（不是 `.Q`）。断电保持累计用 TONR；通电延时/断电延时按 H5U 指令集同样以内联形式调用。
    - **高速计数器 HC_Counter 同为内联指令（不是 FB 实例）**：不声明 `xxx : HC_Counter` 实例、不进功能块实例表，直接 `HC_Counter(...)` 调用（同 TONR）。推杆位置读轴 `Axis` 绑组态计数轴（`Axis_电推杆`）；`Invert` 为 **INT**（方向取反，`0`=不取反，不是 BOOL）；`Position` 输出**直接为 REAL（mm）**，承接变量声明 REAL、直接赋值，**无需 DINT_TO_REAL**；不用的输出（`Velocity`/`Direction`/`CommandAborted`）形参留空。
  - **★平台不支持 WORD 类型**：16 位错误码/状态字一律用 **INT** 承接（如 HC_Counter.ErrorID、驱动器 Er.xxx 码）；无 USINT 截断场景用 INT 接字节。
  - **上升沿/下降沿仍声明功能块实例，但类型名必须带库前缀**：上升沿 `TRIG.R_TRIG`、下降沿 `TRIG.F_TRIG`（不是裸 `R_TRIG`/`F_TRIG`）。用法 `rTrigX(CLK := <信号>);` 后读 `rTrigX.Q`（`.Q` 读法不变）。
  - **CASE 分支标签必须用字面整数，不能用具名常量标识符**：H5U 编译器把 `VAR_GLOBAL CONSTANT` 的常量（如 `ST_STANDBY`）也当作变量，CASE 标签写常量名会编译报错。必须写数字、行尾注释具名码值，便于追溯：
    `10: // ST_STANDBY ...`（不要写 `ST_STANDBY:`）。具名常量仍用于 IF 比较、赋值、运算表达式（如 `IF iState = ST_STANDBY`、`iState := ST_HOMING`），仅 CASE 标签受限。
  - **★常数（字面值）禁止 IEC 类型前缀，只写裸值/进制前缀/LD 风格**：LiteST 不支持 `DINT#0`、`INT#1`、`REAL#1.0`、`TIME#..`、`BOOL#TRUE` 等类型前缀字面值（编译报错）。常数只能写：①裸十进制（`a := 100;`）；②进制前缀+下划线分段（`10#100_10`、`16#FF_AE_12`、`2#1100_1111`）；③LD 风格（`K100`=十进制 100、`H..`=十六进制、`E..`=浮点）。类型由声明/上下文隐式确定。
  - **★SHL/SHR 的第一个操作数不能是常量，必须是变量**：`SHL(1, n)`/`SHR(1, n)` 第一操作数写常数非法。位掩码不要在运行期 `SHL(常量, 位号)`，而应在 GVL_CONST 把**位值预计算为掩码常量**（如 `READY_MASK_ZERO : INT := 16#1;`、`16#2`/`16#4`/`16#8`/`16#10`/`16#20`…），运行期只做 `mask := mask OR READY_MASK_xxx;`（彻底不用 SHL）。确需移位时第一操作数必须传一个变量。
  - **功能块实例只能在 FUNCTION_BLOCK / 边沿场景的局部 VAR 声明**（全局 GVL 不支持 FB 实例；`AXIS_REF` 轴引用由组态自动生成全局，属例外）。GVL 支持 BOOL/INT/DINT/REAL/STRING/IP/BYTE 及其**数组、结构体**（如 `REAL[3]`、`Stru_AxisLimitConfig[3]`）。定型模式：局部 `TRIG.R_TRIG` 检边沿 → `.Q` 每扫转写一个全局 BOOL 脉冲位（`trigXxx`，脉冲天然单扫有效，无需清零）；**定时用全局 BOOL + 内联 `TONR`**（PRG/FC 内不得声明局部简单变量，见上条）。
  - **例外**：`AXIS_REF` 轴引用（Axis_胸背/臀盘/臀腿）由 EtherCAT 设备树/H5U 组态自动生成为全局变量，在 GVL_IoMap 中保留，但不走变量表 CSV 导入。
  - **导出 InoProShop 变量表 CSV 时**：定时器位按 **BOOL** 录入（不是 TON）；`TRIG.R_TRIG` 实例录"功能块实例"表（类型 `TRIG.R_TRIG`），不进普通变量表。
- 三轴块、错误条目、参数块统一结构体，三轴复用同一映射，避免三份分叉。
- 常量（状态码、错误码、命令位、步骤码）集中在 `CONST_Definitions.st`，禁止魔法数字。
- 命令位/状态位用具名常量，与 JSON 中的变量名保持一致，便于双向追溯。
- 每个程序块头部注释：唯一写入变量、读入变量、所属扫描层。
- 每阶段结束做一次单写源评审 + HMI 窗口核对，再进入下一阶段。
