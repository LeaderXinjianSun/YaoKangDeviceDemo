(*============================================================================
  PRG_ModeManager —— 层 20 决策：系统状态机（扫描链第 6 环），iState 唯一写入者
  ----------------------------------------------------------------------------
  唯一写入：iState（13 态主状态码）。
  读入：  bHardEstop/bSoftEstop（安全态最高优先级）、HMI.Sys.Cmd 模式/请求位、
          任务模块上报 iPhase/iBlockReason、资格位（bAllAxesRef/bAllAxesAtInit 等）。
  规则：任务模块不直接切态，只上报 iPhase/iBlockReason；切换须过门控
        （角色/权限码/资格/安全条件）；急停态无条件穿透。
  P1：INIT → STANDBY 引导 + 急停穿透/恢复骨架。
  P6：13 态完整仲裁、READY_CHECK 六项资格掩码、离态清残留电平。
==========================================================================*)
PROGRAM PRG_ModeManager
VAR
    iInitTimer  : INT;
END_VAR

(*--- 急停最高优先级，任何状态穿透 ---*)
IF bHardEstop THEN
    iState := ST_HARD_ESTOP;
ELSIF bSoftEstop THEN
    iState := ST_SOFT_ESTOP;
ELSE
    CASE iState OF
        ST_INIT:
            (* 上电引导：P6 在此做参数加载/电源/健康检查后转 READY_CHECK *)
            iInitTimer := iInitTimer + 1;
            IF iInitTimer > 10 THEN
                iState := ST_STANDBY;    (* P6: 先转 ST_READY_CHECK，资格齐再 STANDBY *)
            END_IF;

        ST_STANDBY:
            (* TODO P6: 按 Sys.Cmd 请求门控切换
               bHomingReq→ST_HOMING、bStartSelfTestReq→ST_SELFTEST、
               trigStart/AUTORUN 资格→ST_AUTORUN、工程师服务→ST_SERVICE、
               bCalibrateReq→ST_CALIBRATE、bResetReq→ST_RESET *)
            ;

        ST_HARD_ESTOP, ST_SOFT_ESTOP:
            (* 急停恢复：急停解除 + 复位请求后转 RESET 收口，再回 STANDBY *)
            IF (NOT bSafetyStop) AND HMI.Sys.Cmd.bResetReq THEN
                iState := ST_RESET;
            END_IF;

        (* TODO P6: ST_READY_CHECK / ST_SELFTEST / ST_SERVICE_REQUIRED /
           ST_AUTORUN / ST_SERVICE / ST_HOMING / ST_CALIBRATE / ST_RESET /
           ST_STOPPING / ST_PARAM_LIMITED 完整仲裁与门控。 *)
    ELSE
        iState := ST_INIT;
    END_CASE;
END_IF;
END_PROGRAM
