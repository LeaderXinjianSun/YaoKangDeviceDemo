<script setup lang="ts">
/**
 * 单轴调试面板（四轴共用，按 AxisConfig 能力裁剪）：
 * - 调试使能（保持型取反）；Jog± 按 1 松 0（AxisPad）；
 * - Inc± / Go(Abs) 为上升沿短脉冲（后端 coil_pulse，宽度 cmd_pulse_ms 可配）；
 * - 调试速度 / Inc 距离 / Abs 目标：失焦或"应用"时 write_real 下发。
 */
import { ref, watch } from "vue";
import {
  NButton,
  NInputNumber,
  NSpace,
  NSpin,
  NSwitch,
  useMessage,
} from "naive-ui";
import { axisRead, coilPulse, coilToggle, writeReal } from "../api/plc";
import { usePlcStore } from "../stores/plc";
import AxisPad from "./AxisPad.vue";
import type { AxisConfig } from "../config/axes";

const props = defineProps<{ axis: AxisConfig }>();

const plc = usePlcStore();
const message = useMessage();

const enabled = ref(false);
/** 各参数输入框的本地值（null = 空）；D 地址 -> 值 */
const paramValues = ref<Record<number, number | null>>({});
const loading = ref(false);

/**
 * 从 PLC 回读当前轴的使能线圈与全部 D 参数，回填控件。
 * 进入页面、切换轴、断线恢复上线时调用
 */
async function reload(): Promise<void> {
  if (!plc.online) return;
  const ds = props.axis.params.map((p) => p.d);
  // 切轴时先清掉上一根轴的显示，避免残留
  enabled.value = false;
  paramValues.value = {};
  loading.value = true;
  try {
    const snap = await axisRead(
      props.axis.enable === undefined ? null : props.axis.enable,
      ds
    );
    if (snap.enable !== null) enabled.value = snap.enable;
    snap.values.forEach((v, i) => {
      paramValues.value[ds[i]] = Number(v.toFixed(3));
    });
  } catch (e) {
    message.error(`轴参数读取失败：${e}`);
  } finally {
    loading.value = false;
  }
}

watch(
  () => props.axis.key,
  () => void reload(),
  { immediate: true }
);

watch(
  () => plc.status,
  (s) => {
    if (s !== "online") {
      enabled.value = false;
    } else {
      // 重连上线后重新回填
      void reload();
    }
  }
);

async function toggleEnable(): Promise<void> {
  if (props.axis.enable === undefined) return;
  try {
    enabled.value = await coilToggle(props.axis.enable);
  } catch (e) {
    message.error(`调试使能取反失败：${e}`);
  }
}

/** Inc± / Abs：上升沿短脉冲 */
async function pulse(m: number | undefined, label: string): Promise<void> {
  if (m === undefined) return;
  try {
    await coilPulse(m);
  } catch (e) {
    message.error(`${label}失败：${e}`);
  }
}

async function applyParam(d: number, label: string): Promise<void> {
  const v = paramValues.value[d];
  if (v === null || v === undefined) return;
  try {
    await writeReal(d, v);
    message.success(`${label}已下发：D${d} = ${v}`);
  } catch (e) {
    message.error(`${label}下发失败：${e}`);
  }
}
</script>

<template>
  <n-spin :show="loading">
  <n-space vertical size="large">
    <n-space v-if="axis.enable !== undefined" align="center" :wrap="false">
      <n-switch
        :value="enabled"
        :disabled="!plc.online"
        @update:value="toggleEnable"
      />
      <span class="enable-label">
        调试使能 M{{ axis.enable }}（{{ enabled ? "已使能" : "未使能" }}）
      </span>
      <n-button
        size="small"
        :disabled="!plc.online"
        @click="toggleEnable"
      >
        取反
      </n-button>
    </n-space>

    <n-space>
      <AxisPad
        :m="axis.jogPlus"
        label="Jog +"
        :disabled="!plc.online || (axis.enable !== undefined && !enabled)"
      />
      <AxisPad
        :m="axis.jogMinus"
        label="Jog −"
        :disabled="!plc.online || (axis.enable !== undefined && !enabled)"
      />
      <n-button
        v-if="axis.incPlus !== undefined"
        size="large"
        :disabled="!plc.online || !enabled"
        @click="pulse(axis.incPlus, 'Inc +')"
      >
        Inc + M{{ axis.incPlus }}
      </n-button>
      <n-button
        v-if="axis.incMinus !== undefined"
        size="large"
        :disabled="!plc.online || !enabled"
        @click="pulse(axis.incMinus, 'Inc −')"
      >
        Inc − M{{ axis.incMinus }}
      </n-button>
      <n-button
        v-if="axis.abs !== undefined"
        size="large"
        type="primary"
        :disabled="!plc.online || (axis.enable !== undefined && !enabled)"
        @click="pulse(axis.abs, 'Go(Abs)')"
      >
        Go M{{ axis.abs }}
      </n-button>
    </n-space>

    <n-space>
      <div v-for="p in axis.params" :key="p.d" class="param">
        <div class="param-label">
          {{ p.label }} D{{ p.d }}（{{ p.unit }}）
        </div>
        <n-space :wrap="false">
          <n-input-number
            v-model:value="paramValues[p.d]"
            :disabled="!plc.online"
            placeholder="数值"
            @blur="applyParam(p.d, p.label)"
          />
          <n-button
            :disabled="!plc.online"
            @click="applyParam(p.d, p.label)"
          >
            应用
          </n-button>
        </n-space>
      </div>
    </n-space>
  </n-space>
  </n-spin>
</template>

<style scoped>
.enable-label {
  font-size: 13px;
  opacity: 0.75;
}
.param {
  background: rgba(255, 255, 255, 0.04);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 8px;
  padding: 12px 14px;
}
.param-label {
  font-size: 12px;
  opacity: 0.65;
  margin-bottom: 8px;
}
</style>
