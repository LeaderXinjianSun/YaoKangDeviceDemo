<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from "vue";
import { NCard, NEmpty, NMenu, NSpace, NTag, NButton, useMessage } from "naive-ui";
import type { MenuOption } from "naive-ui";
import { usePlcStore } from "../stores/plc";
import { coilClearAll, coilPulse } from "../api/plc";
import AxisPanel from "../components/AxisPanel.vue";
import { AXES, M_DEBUG_STOP } from "../config/axes";

const plc = usePlcStore();
const message = useMessage();

// ---- 轴切换 ----
const currentKey = ref(AXES[0].key);
const currentAxis = computed(
  () => AXES.find((a) => a.key === currentKey.value) ?? AXES[0]
);
const menuOptions = computed<MenuOption[]>(() =>
  AXES.map((a) => ({ label: a.name, key: a.key }))
);

// ---- 四轴实时坐标 ----
const axes = computed(() => {
  const t = plc.telemetry;
  return [
    { name: "胸背轴", value: t ? t.chestBack : null, unit: "mm" },
    { name: "臀腿轴", value: t ? t.hipLeg : null, unit: "°" },
    { name: "臀盘轴", value: t?.hipDisc ?? null, unit: "°" },
    { name: "电推杆轴", value: t ? t.pushrod : null, unit: "°" },
  ];
});

function fmt(v: number | null): string {
  return v === null ? "--" : v.toFixed(3);
}

/** 停止类安全按钮：先清掉所有置位点动线圈，再向停止线圈发一个短脉冲 */
async function stop(m: number, name: string): Promise<void> {
  try {
    await coilClearAll();
    await coilPulse(m);
  } catch (e) {
    message.error(`${name}失败：${e}`);
  }
}

/** 切页/窗口失焦：清掉所有当前置位的点动线圈 */
async function clearHeld(): Promise<void> {
  try {
    await coilClearAll();
  } catch {
    // 后端离线时会在重连后补写 OFF，忽略
  }
}

function onWindowBlur(): void {
  void clearHeld();
}

onMounted(() => {
  // 进入调试页才周期读 D200~D207；离开即停（后端引用计数）
  void plc.startTelemetry();
  window.addEventListener("blur", onWindowBlur);
});

onUnmounted(() => {
  window.removeEventListener("blur", onWindowBlur);
  void plc.stopTelemetry();
  // 切页：主动清掉所有置位点动线圈
  void clearHeld();
});
</script>

<template>
  <div class="page">
    <div class="head">
      <h2>调试</h2>
      <n-tag :bordered="false" :type="plc.online ? 'success' : 'warning'">
        {{ plc.statusText }}
      </n-tag>
    </div>

    <n-card title="四轴实时坐标（只读）" class="card" :bordered="false">
      <n-empty
        v-if="!plc.online"
        description="PLC 未连接，连接成功后自动刷新坐标"
        class="hint"
      />
      <div v-else class="grid">
        <div v-for="a in axes" :key="a.name" class="axis">
          <div class="axis-name">{{ a.name }}</div>
          <div class="axis-value">
            {{ fmt(a.value) }}
            <span class="axis-unit">{{ a.unit }}</span>
          </div>
        </div>
      </div>
      <div v-if="plc.online" class="tip">
        数据来源 D200~D207（四个 REAL），离开本页自动停止读取
      </div>
    </n-card>

    <div class="debug-body">
      <n-card class="axis-menu" :bordered="false">
        <n-menu
          v-model:value="currentKey"
          :options="menuOptions"
          :indent="18"
        />
      </n-card>

      <n-card
        :title="`${currentAxis.name}点动调试`"
        class="axis-card"
        :bordered="false"
      >
        <AxisPanel :axis="currentAxis" />

        <n-space class="stop-row">
          <n-button
            type="error"
            :disabled="!plc.online"
            @click="stop(M_DEBUG_STOP, '调试停止')"
          >
            调试停止 M{{ M_DEBUG_STOP }}
          </n-button>
        </n-space>

        <div class="tip">
          Jog± 与全局工具栏的运行/调试/退出调试/普通停止/复位均为按住为 1、松开为 0，不设超时自动复位
          （拖出按钮、切页、窗口失焦或断线均回 0，断线恢复后后端补写 0）；Inc±/Go 与
          调试停止按钮为上升沿短脉冲（宽度可配，默认 200ms）；参数在失焦或点"应用"时写入
          对应 D 地址。
        </div>
      </n-card>
    </div>
  </div>
</template>

<style scoped>
.page {
  display: flex;
  flex-direction: column;
  gap: 16px;
}
.head {
  display: flex;
  align-items: center;
  gap: 12px;
  flex-wrap: wrap;
}
h2 {
  margin: 0;
  font-weight: 500;
  opacity: 0.85;
}
.card {
  max-width: 900px;
}
.hint {
  padding: 24px 0;
}
.grid {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 12px;
}
.axis {
  background: rgba(255, 255, 255, 0.04);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 8px;
  padding: 14px 16px;
}
.axis-name {
  font-size: 13px;
  opacity: 0.65;
  margin-bottom: 6px;
}
.axis-value {
  font-size: 24px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.axis-unit {
  font-size: 13px;
  font-weight: 400;
  opacity: 0.6;
  margin-left: 4px;
}
.debug-body {
  display: flex;
  gap: 16px;
  align-items: flex-start;
}
.axis-menu {
  width: 140px;
  flex-shrink: 0;
}
.axis-card {
  flex: 1;
  min-width: 0;
}
.stop-row {
  margin-top: 20px;
}
.tip {
  font-size: 12px;
  opacity: 0.45;
  line-height: 1.6;
  margin-top: 12px;
}
</style>
