<script setup lang="ts">
import { computed, onMounted, onUnmounted } from "vue";
import { NCard, NEmpty, NTag } from "naive-ui";
import { usePlcStore } from "../stores/plc";

const plc = usePlcStore();

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

onMounted(() => {
  // 进入调试页才周期读 D200~D207；离开即停（后端引用计数）
  plc.startTelemetry();
});

onUnmounted(() => {
  plc.stopTelemetry();
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
}
h2 {
  margin: 0;
  font-weight: 500;
  opacity: 0.85;
}
.card {
  max-width: 720px;
}
.hint {
  padding: 24px 0;
}
.grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 16px;
}
.axis {
  background: rgba(255, 255, 255, 0.04);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 8px;
  padding: 16px 20px;
}
.axis-name {
  font-size: 13px;
  opacity: 0.65;
  margin-bottom: 6px;
}
.axis-value {
  font-size: 26px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.axis-unit {
  font-size: 14px;
  font-weight: 400;
  opacity: 0.6;
  margin-left: 4px;
}
.tip {
  margin-top: 12px;
  font-size: 12px;
  opacity: 0.45;
}
</style>
