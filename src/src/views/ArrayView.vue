<script setup lang="ts">
import { computed, h, ref } from "vue";
import {
  NButton,
  NDataTable,
  NInputNumber,
  NSelect,
  NSpace,
  NSpin,
  NTag,
  useMessage,
  type DataTableColumns,
} from "naive-ui";
import { arrayDownload, arrayUpload } from "../api/plc";
import {
  ARRAY_COLUMNS,
  MAX_DEPTH,
  MODE_OPTIONS,
} from "../config/arrayColumns";
import { usePlcStore } from "../stores/plc";

const plc = usePlcStore();
const message = useMessage();

/** 深度（D1100，1~16）与模式（D1101） */
const depth = ref(1);
const mode = ref(1);
/** 固定 16 行缓冲，表格只显示前 depth 行 */
const rows = ref<number[][]>(
  Array.from({ length: MAX_DEPTH }, () => ARRAY_COLUMNS.map(() => 0))
);

const busy = ref(false);

const modeOptions = MODE_OPTIONS;

/** 单元格是否超限（非有限数 / 速度等 <0 或 >上限 / 间隔为负） */
function isInvalid(row: number, col: number): boolean {
  const c = ARRAY_COLUMNS[col];
  const v = rows.value[row][col];
  if (!Number.isFinite(v)) return true;
  if (c.max !== null && (v < 0 || v > c.max)) return true;
  if (c.dint && v < 0) return true;
  return false;
}

/** 当前可见行中是否存在超限单元格（存在则禁止下发） */
const hasInvalid = computed(() => {
  for (let r = 0; r < depth.value; r++) {
    for (let c = 0; c < ARRAY_COLUMNS.length; c++) {
      if (isInvalid(r, c)) return true;
    }
  }
  return false;
});

function onDepthChange(v: number | null): void {
  const d = v ?? 1;
  // 增大深度时新增行清零
  for (let r = depth.value; r < d; r++) {
    rows.value[r] = ARRAY_COLUMNS.map(() => 0);
  }
  depth.value = d;
}

function updateCell(row: number, col: number, v: number | null): void {
  rows.value[row][col] = v ?? 0;
}

/** 构造下发载荷：间隔取整，REAL 列保留原值 */
function payloadRows(): number[][] {
  return rows.value.slice(0, depth.value).map((r) =>
    r.map((v, c) => (ARRAY_COLUMNS[c].dint ? Math.round(v) : v))
  );
}

async function download(): Promise<void> {
  busy.value = true;
  try {
    const dump = await arrayDownload();
    depth.value = dump.depth;
    mode.value = dump.mode;
    dump.rows.forEach((r, i) => {
      rows.value[i] = r;
    });
    // 上读深度之后的旧编辑行清零，避免残留
    for (let i = dump.rows.length; i < MAX_DEPTH; i++) {
      rows.value[i] = ARRAY_COLUMNS.map(() => 0);
    }
    message.success(`已从 PLC 上读 ${dump.depth} 步数据`);
  } catch (e) {
    message.error(`上读失败：${e}`);
  } finally {
    busy.value = false;
  }
}

async function upload(): Promise<void> {
  if (hasInvalid.value) {
    message.error("存在超限单元格（已标红），请先修正再下发");
    return;
  }
  busy.value = true;
  try {
    await arrayUpload({
      depth: depth.value,
      mode: mode.value,
      rows: payloadRows(),
    });
    message.success(`已下发 ${depth.value} 步数组到 PLC`);
    // 下发后自动回读做差异核对
    try {
      const back = await arrayDownload();
      let diff = 0;
      back.rows.forEach((r, i) =>
        r.forEach((v, c) => {
          if (Math.abs(v - rows.value[i][c]) > 0.01) diff += 1;
        })
      );
      if (
        back.depth === depth.value &&
        back.mode === mode.value &&
        diff === 0
      ) {
        message.success("回读核对一致");
      } else {
        message.warning(`回读存在 ${diff} 处差异，请核对 PLC 数据`);
      }
    } catch {
      // 核对失败不影响下发结果
    }
  } catch (e) {
    message.error(`下发失败：${e}`);
  } finally {
    busy.value = false;
  }
}

const tableColumns = computed<DataTableColumns<{ idx: number }>>(() => [
  {
    title: "步",
    key: "idx",
    width: 50,
    fixed: "left",
    align: "center",
    render: (row) => row.idx + 1,
  },
  ...ARRAY_COLUMNS.map((c) => ({
    title: `${c.title}(${c.unit})`,
    key: String(c.key),
    width: 122,
    align: "center" as const,
    render: (row: { idx: number }) =>
      h(NInputNumber, {
        value: rows.value[row.idx][c.key],
        size: "small",
        showButton: false,
        precision: c.dint ? 0 : 3,
        status: isInvalid(row.idx, c.key) ? "error" : undefined,
        style: "width: 108px",
        onUpdateValue: (v: number | null) => updateCell(row.idx, c.key, v),
      }),
  })),
]);

const tableData = computed(() =>
  Array.from({ length: depth.value }, (_, i) => ({ idx: i }))
);
</script>

<template>
  <n-spin :show="busy">
    <div class="page">
      <div class="toolbar">
        <h2>运动数组</h2>
        <n-space align="center" :size="12">
          <span class="field-label">数组深度 D1100</span>
          <n-input-number
            :value="depth"
            :min="1"
            :max="MAX_DEPTH"
            :step="1"
            :disabled="!plc.online || busy"
            style="width: 90px"
            @update:value="onDepthChange"
          />
          <span class="field-label">运动模式 D1101</span>
          <n-select
            :value="mode"
            :options="modeOptions"
            :disabled="!plc.online || busy"
            style="width: 120px"
            @update:value="(v: number) => (mode = v)"
          />
          <n-tag :type="plc.online ? 'success' : 'error'" size="small" round>
            {{ plc.statusText }}
          </n-tag>
          <n-button
            :disabled="!plc.online || busy || hasInvalid"
            type="primary"
            @click="upload"
          >
            整组下发
          </n-button>
          <n-button
            :disabled="!plc.online || busy"
            @click="download"
          >
            从 PLC 上读
          </n-button>
        </n-space>
      </div>

      <p class="tip">
        进入本页不自动读取 PLC；仅点击"从 PLC 上读/整组下发"时产生一次性报文，
        离开页面无任何后台读写。超限单元格标红并禁止下发
        （速度≤500/148.76，加减速≤2500/743.8，间隔为非负整数）。
      </p>

      <n-data-table
        :columns="tableColumns"
        :data="tableData"
        :max-height="560"
        :scroll-x="50 + 13 * 122"
        :single-line="false"
        size="small"
        striped
      />
    </div>
  </n-spin>
</template>

<style scoped>
.page {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.toolbar {
  display: flex;
  align-items: center;
  gap: 16px;
  flex-wrap: wrap;
}

.toolbar h2 {
  margin: 0;
  font-weight: 500;
  opacity: 0.85;
}

.field-label {
  font-size: 13px;
  opacity: 0.75;
}

.tip {
  margin: 0;
  font-size: 12px;
  opacity: 0.6;
}
</style>
