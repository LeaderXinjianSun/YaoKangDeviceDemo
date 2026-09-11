import { defineStore } from "pinia";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { computed, ref } from "vue";
import {
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

const TELEMETRY_GROUP = "telemetry";

/**
 * PLC 全局状态：
 * - status 由后端 plc::status 事件驱动，App 挂载时 init() 一次；
 * - telemetry 为最新一帧四轴坐标，调试页进入时 startTelemetry / 离开时 stopTelemetry。
 */
export const usePlcStore = defineStore("plc", () => {
  const status = ref<PlcStatus>("offline");
  const telemetry = ref<PlcTelemetry | null>(null);

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
    init,
    connect,
    disconnect,
    startTelemetry,
    stopTelemetry,
  };
});
