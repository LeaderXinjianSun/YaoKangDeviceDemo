import { defineStore } from "pinia";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { computed, ref } from "vue";
import {
  PLC_GL_STEP_EVENT,
  PLC_STATUS_EVENT,
  PLC_TELEMETRY_EVENT,
  plcConnect,
  plcDisconnect,
  plcStatus,
  plcSubscribe,
  plcUnsubscribe,
  type PlcStatus,
  type PlcTelemetry,
} from "../api/plc";
import {
  PLC_ALARM_STATE_EVENT,
  PLC_PROMPT_EVENT,
  PLC_STEP_INDEX_EVENT,
  alarmCurrent,
  type AlarmItem,
} from "../api/alarm";

const TELEMETRY_GROUP = "telemetry";
/** 全局状态机组（顶栏常驻，App 挂载即订阅、不退订） */
const GL_STEP_GROUP = "glstep";

/**
 * PLC 全局状态：
 * - status 由后端 plc::status 事件驱动，App 挂载时 init() 一次；
 * - telemetry 为最新一帧四轴坐标，调试页进入时 startTelemetry / 离开时 stopTelemetry。
 */
export const usePlcStore = defineStore("plc", () => {
  const status = ref<PlcStatus>("offline");
  const telemetry = ref<PlcTelemetry | null>(null);
  /** D220 全局状态机：-1 急停/0 复位/1 调试/2 运行；null=尚未读到 */
  const glStep = ref<number | null>(null);
  /** M300~M399 全部报警点当前电平（后端常驻任务推送，无需订阅） */
  const alarms = ref<AlarmItem[]>([]);
  /** M400 段当前操作提示（多 TRUE 时后端已取地址最大者），无提示为 null */
  const prompt = ref<AlarmItem | null>(null);
  /** D400 当前动作步索引，尚未读到为 null */
  const stepIndex = ref<number | null>(null);

  /** 当前为 ON 的报警（用于诊断页文本框） */
  const activeAlarms = computed(() => alarms.value.filter((a) => a.on));

  const online = computed(() => status.value === "online");
  const statusText = computed(() => {
    switch (status.value) {
      case "online":
        return "已连接";
      case "connecting":
        return "连接中…";
      case "reconnecting":
        return "重连中…";
      default:
        return "未连接";
    }
  });

  let unlistenStatus: UnlistenFn | null = null;
  let unlistenTelemetry: UnlistenFn | null = null;
  let unlistenGlStep: UnlistenFn | null = null;
  let unlistenAlarms: UnlistenFn | null = null;
  let telemetryCount = 0;

  /** 订阅状态事件并同步一次当前状态（App.vue onMounted 调用一次） */
  async function init(): Promise<void> {
    if (!unlistenStatus) {
      unlistenStatus = await listen<PlcStatus>(PLC_STATUS_EVENT, (e) => {
        status.value = e.payload;
      });
      try {
        status.value = await plcStatus();
      } catch {
        // 后端不可用时保持 offline
      }
    }
    // 顶栏常驻：订阅 D220 全局状态机（引用计数恒为 1，不退订）
    if (!unlistenGlStep) {
      unlistenGlStep = await listen<number>(PLC_GL_STEP_EVENT, (e) => {
        glStep.value = e.payload;
      });
      try {
        await plcSubscribe(GL_STEP_GROUP);
      } catch {
        // 后端不可用时忽略，重连后由重订阅覆盖（首次订阅失败不影响其余功能）
      }
    }
    // P6 常驻：报警电平/操作提示/D400 动作步（后端连接成功即自启，无需 subscribe）
    if (!unlistenAlarms) {
      unlistenAlarms = await listen<AlarmItem[]>(
        PLC_ALARM_STATE_EVENT,
        (e) => {
          alarms.value = e.payload;
        }
      );
      await listen<AlarmItem | null>(PLC_PROMPT_EVENT, (e) => {
        prompt.value = e.payload;
      });
      await listen<number | null>(PLC_STEP_INDEX_EVENT, (e) => {
        stepIndex.value = e.payload;
      });
      try {
        const snap = await alarmCurrent();
        alarms.value = snap.alarms;
        prompt.value = snap.prompt;
        stepIndex.value = snap.stepIndex;
      } catch {
        // 后端不可用时保持空状态，事件到达后自然更新
      }
    }
  }

  async function connect(): Promise<void> {
    await plcConnect();
  }

  async function disconnect(): Promise<void> {
    await plcDisconnect();
  }

  /** 引用计数订阅四轴坐标（页面级调用，可嵌套） */
  async function startTelemetry(): Promise<void> {
    telemetryCount += 1;
    if (telemetryCount === 1) {
      unlistenTelemetry = await listen<PlcTelemetry>(
        PLC_TELEMETRY_EVENT,
        (e) => {
          telemetry.value = e.payload;
        }
      );
      await plcSubscribe(TELEMETRY_GROUP);
    }
  }

  async function stopTelemetry(): Promise<void> {
    telemetryCount = Math.max(0, telemetryCount - 1);
    if (telemetryCount === 0) {
      unlistenTelemetry?.();
      unlistenTelemetry = null;
      telemetry.value = null;
      await plcUnsubscribe(TELEMETRY_GROUP);
    }
  }

  return {
    status,
    online,
    statusText,
    telemetry,
    glStep,
    alarms,
    activeAlarms,
    prompt,
    stepIndex,
    init,
    connect,
    disconnect,
    startTelemetry,
    stopTelemetry,
  };
});
