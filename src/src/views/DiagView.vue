<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import {
  NButton,
  NCard,
  NDataTable,
  NDatePicker,
  NSpace,
  NSpin,
  useMessage,
  type DataTableColumns,
} from "naive-ui";
import {
  alarmLogs,
  faultCodesRead,
  type AlarmLogEntry,
} from "../api/alarm";
import { usePlcStore } from "../stores/plc";

const message = useMessage();
const plc = usePlcStore();

// 左侧只读文本框：当前报警按回车换行间隔（无报警显示占位文字）
const alarmText = computed(() =>
  plc.activeAlarms.map((a) => `${a.name}（M${a.addr}）`).join("\r\n")
);

// ---------- 报警记录时段查询 ----------
const loadingLogs = ref(false);
const logs = ref<AlarmLogEntry[]>([]);
/** datetimerange 时间戳（毫秒），null=不限时段 */
const range = ref<[number, number] | null>(null);

function fmtTs(ms: number): string {
  const p = (n: number) => String(n).padStart(2, "0");
  const d = new Date(ms);
  return (
    `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ` +
    `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`
  );
}

async function queryLogs() {
  loadingLogs.value = true;
  try {
    const begin = range.value ? fmtTs(range.value[0]) : null;
    const end = range.value ? fmtTs(range.value[1]) : null;
    logs.value = await alarmLogs(begin, end);
  } catch (e) {
    message.error(`查询报警记录失败：${e}`);
  } finally {
    loadingLogs.value = false;
  }
}

const columns: DataTableColumns<AlarmLogEntry> = [
  { title: "时间", key: "ts", width: 190 },
  {
    title: "地址",
    key: "addr",
    width: 90,
    render: (r) => `M${r.addr}`,
  },
  { title: "名称", key: "name" },
  {
    title: "类型",
    key: "kind",
    width: 90,
    render: (r) =>
      r.kind === "raised"
        ? "报警发生"
        : "报警解除",
  },
];

// ---------- 读取报警代码（D300~D302，与报警是否存在无关，无报警显示 0000） ----------
const loadingCodes = ref(false);
const faultCodes = ref<number[] | null>(null);
const axisNames = ["胸背轴", "臀腿轴", "臀盘轴"];

function hex(v: number): string {
  return v.toString(16).toUpperCase().padStart(4, "0");
}

async function readFaultCodes() {
  loadingCodes.value = true;
  try {
    faultCodes.value = await faultCodesRead();
  } catch (e) {
    message.error(`读取报警代码失败：${e}`);
  } finally {
    loadingCodes.value = false;
  }
}

onMounted(queryLogs);
</script>

<template>
  <div class="page">
    <h2>诊断</h2>
    <div class="body">
      <!-- 左：当前报警（黑底白字只读文本框，回车换行间隔） -->
      <n-card title="当前报警" class="left-card" :bordered="false">
        <textarea
          class="alarm-box"
          :value="alarmText"
          readonly
          placeholder="无当前报警"
        ></textarea>
        <n-space style="margin-top: 12px">
          <n-button
            type="primary"
            :loading="loadingCodes"
            :disabled="!plc.online"
            @click="readFaultCodes"
          >
            读取报警代码
          </n-button>
        </n-space>
        <div v-if="faultCodes" class="codes">
          <div v-for="(v, i) in faultCodes" :key="i" class="code-item">
            <span class="code-axis">{{ axisNames[i] ?? `D${300 + i}` }}</span>
            <span class="code-hex">{{ hex(v) }}</span>
          </div>
        </div>
      </n-card>

      <!-- 右：报警记录（时段筛选） -->
      <n-card title="报警记录" class="right-card" :bordered="false">
        <n-space align="center" class="filter-bar">
          <n-date-picker
            v-model:value="range"
            type="datetimerange"
            clearable
            start-placeholder="开始时间"
            end-placeholder="结束时间"
          />
          <n-button type="primary" :loading="loadingLogs" @click="queryLogs">
            查询
          </n-button>
        </n-space>
        <n-spin :show="loadingLogs">
          <n-data-table
            :columns="columns"
            :data="logs"
            :max-height="520"
            :bordered="false"
            size="small"
          />
        </n-spin>
      </n-card>
    </div>
  </div>
</template>

<style scoped>
.page {
  height: 100%;
  display: flex;
  flex-direction: column;
  gap: 12px;
}
h2 {
  font-weight: 500;
  opacity: 0.85;
  margin: 0;
}
.body {
  flex: 1;
  display: flex;
  gap: 16px;
  min-height: 0;
}
.left-card {
  width: 320px;
  flex-shrink: 0;
}
.right-card {
  flex: 1;
  min-width: 0;
}
.alarm-box {
  width: 100%;
  height: 360px;
  resize: none;
  background: #000;
  color: #fff;
  border: 1px solid #333;
  border-radius: 4px;
  padding: 8px;
  font-family: Consolas, "Courier New", monospace;
  font-size: 14px;
  line-height: 1.6;
  outline: none;
}
.alarm-box::placeholder {
  color: #888;
}
.codes {
  margin-top: 12px;
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.code-item {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 4px 10px;
  background: rgba(255, 255, 255, 0.05);
  border-radius: 4px;
}
.code-axis {
  font-size: 13px;
  opacity: 0.8;
}
.code-hex {
  font-family: Consolas, "Courier New", monospace;
  font-size: 16px;
  font-weight: 600;
  color: #e8a03c;
}
.filter-bar {
  margin-bottom: 12px;
}
</style>
