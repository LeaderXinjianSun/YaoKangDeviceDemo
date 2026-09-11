<script setup lang="ts">
import { computed, h, onMounted, ref } from "vue";
import {
  NButton,
  NDataTable,
  NInput,
  NInputNumber,
  NModal,
  NPopconfirm,
  NSelect,
  NSpace,
  NSpin,
  NTag,
  useMessage,
  type DataTableColumns,
  type SelectOption,
} from "naive-ui";
import { arrayDownload, arrayUpload } from "../api/plc";
import {
  recipeClone,
  recipeDelete,
  recipeGet,
  recipeList,
  recipeLogs,
  recipeSave,
  type DownloadLogEntry,
  type RecipeMeta,
} from "../api/recipe";
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
const modeText = (m: number): string =>
  MODE_OPTIONS.find((o) => o.value === m)?.label ?? String(m);

// ---------- P5：配方 ----------

const recipes = ref<RecipeMeta[]>([]);
/** 当前选中（并已载入/刚保存）的配方 id；null 表示未关联配方 */
const recipeId = ref<number | null>(null);
/** 相对已载入配方是否有未保存修改 */
const dirty = ref(false);

/** 名称弹窗：new=另存为新配方，clone=克隆当前配方 */
const nameModalShow = ref(false);
const nameModalMode = ref<"new" | "clone">("new");
const inputName = ref("");
const inputRemark = ref("");

/** 下发记录弹窗 */
const logModalShow = ref(false);
const logs = ref<DownloadLogEntry[]>([]);

const recipeOptions = computed<SelectOption[]>(() =>
  recipes.value.map((r) => ({
    label: `${r.name}（${r.depth}步·${modeText(r.mode)}）`,
    value: r.id,
  }))
);

const currentRecipe = computed(() =>
  recipes.value.find((r) => r.id === recipeId.value) ?? null
);

async function refreshRecipes(): Promise<void> {
  try {
    recipes.value = await recipeList();
  } catch (e) {
    message.error(`读取配方列表失败：${e}`);
  }
}

/** 用一组 depth/mode/rows 回填表格（缓冲固定 16 行，多余行清零） */
function fillTable(d: number, m: number, src: number[][]): void {
  depth.value = d;
  mode.value = m;
  for (let i = 0; i < MAX_DEPTH; i++) {
    rows.value[i] =
      i < src.length ? [...src[i]] : ARRAY_COLUMNS.map(() => 0);
  }
}

async function loadRecipe(): Promise<void> {
  if (recipeId.value === null) return;
  busy.value = true;
  try {
    const r = await recipeGet(recipeId.value);
    fillTable(r.depth, r.mode, r.rows);
    dirty.value = false;
    inputRemark.value = r.remark ?? "";
    message.success(`已载入配方「${r.name}」`);
  } catch (e) {
    message.error(`载入配方失败：${e}`);
  } finally {
    busy.value = false;
  }
}

/** 取当前表格（深度内）数据 */
function payloadRows(): number[][] {
  return rows.value.slice(0, depth.value).map((r) =>
    r.map((v, c) => (ARRAY_COLUMNS[c].dint ? Math.round(v) : v))
  );
}

/** 更新当前配方（整体覆盖）；未关联配方时改为打开"另存为" */
async function updateRecipe(): Promise<void> {
  if (recipeId.value === null) {
    openNameModal("new");
    return;
  }
  if (hasInvalid.value) {
    message.error("存在非法单元格（已标红），请先修正再保存");
    return;
  }
  busy.value = true;
  try {
    await recipeSave({
      id: recipeId.value,
      name: currentRecipe.value?.name ?? "",
      depth: depth.value,
      mode: mode.value,
      remark: inputRemark.value.trim() || null,
      rows: payloadRows(),
    });
    dirty.value = false;
    message.success("配方已更新");
    await refreshRecipes();
  } catch (e) {
    message.error(`更新配方失败：${e}`);
  } finally {
    busy.value = false;
  }
}

function openNameModal(m: "new" | "clone"): void {
  nameModalMode.value = m;
  if (m === "clone") {
    inputName.value = `${currentRecipe.value?.name ?? "配方"}-副本`;
    inputRemark.value = currentRecipe.value?.remark ?? "";
  } else {
    inputName.value = "";
    inputRemark.value = "";
  }
  nameModalShow.value = true;
}

async function confirmNameModal(): Promise<void> {
  const name = inputName.value.trim();
  if (!name) {
    message.warning("请填写配方名称");
    return;
  }
  if (hasInvalid.value) {
    message.error("存在非法单元格（已标红），请先修正再保存");
    return;
  }
  busy.value = true;
  try {
    let newId: number;
    if (nameModalMode.value === "clone" && recipeId.value !== null) {
      newId = await recipeClone(recipeId.value, name);
    } else {
      newId = await recipeSave({
        id: null,
        name,
        depth: depth.value,
        mode: mode.value,
        remark: inputRemark.value.trim() || null,
        rows: payloadRows(),
      });
    }
    nameModalShow.value = false;
    recipeId.value = newId;
    dirty.value = false;
    message.success(nameModalMode.value === "clone" ? "克隆完成" : "配方已保存");
    await refreshRecipes();
  } catch (e) {
    message.error(`保存配方失败：${e}`);
  } finally {
    busy.value = false;
  }
}

async function deleteRecipe(): Promise<void> {
  if (recipeId.value === null) return;
  busy.value = true;
  try {
    await recipeDelete(recipeId.value);
    message.success("配方已删除");
    recipeId.value = null;
    dirty.value = false;
    await refreshRecipes();
  } catch (e) {
    message.error(`删除配方失败：${e}`);
  } finally {
    busy.value = false;
  }
}

async function openLogs(): Promise<void> {
  busy.value = true;
  try {
    logs.value = await recipeLogs(200);
    logModalShow.value = true;
  } catch (e) {
    message.error(`读取下发记录失败：${e}`);
  } finally {
    busy.value = false;
  }
}

const logColumns: DataTableColumns<DownloadLogEntry> = [
  { title: "时间", key: "ts", width: 170 },
  {
    title: "结果",
    key: "ok",
    width: 80,
    align: "center",
    render: (row) =>
      h(
        NTag,
        { type: row.ok ? "success" : "error", size: "small", round: true },
        { default: () => (row.ok ? "成功" : "失败") }
      ),
  },
  {
    title: "配方",
    key: "array_id",
    width: 90,
    align: "center",
    render: (row) => (row.array_id === null ? "—" : `#${row.array_id}`),
  },
  { title: "详情", key: "detail" },
];

// ---------- 表格编辑与上读/下发 ----------

/** 单元格是否非法（仅非有效数字；速度/加减速不在上位机做限值） */
function isInvalid(row: number, col: number): boolean {
  return !Number.isFinite(rows.value[row][col]);
}

/** 当前可见行中是否存在非法单元格（非有效数字，存在则禁止下发/保存） */
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
  dirty.value = true;
}

function updateCell(row: number, col: number, v: number | null): void {
  rows.value[row][col] = v ?? 0;
  dirty.value = true;
}

async function download(): Promise<void> {
  busy.value = true;
  try {
    const dump = await arrayDownload();
    fillTable(dump.depth, dump.mode, dump.rows);
    dirty.value = false;
    message.success(`已从 PLC 上读 ${dump.depth} 步数据`);
  } catch (e) {
    message.error(`上读失败：${e}`);
  } finally {
    busy.value = false;
  }
}

async function upload(): Promise<void> {
  if (hasInvalid.value) {
    message.error("存在非法单元格（已标红），请先修正再下发");
    return;
  }
  busy.value = true;
  try {
    await arrayUpload({
      depth: depth.value,
      mode: mode.value,
      rows: payloadRows(),
      arrayId: recipeId.value,
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

onMounted(refreshRecipes);
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
            @update:value="(v: number) => { mode = v; dirty = true }"
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

      <!-- P5 配方栏：本地 SQLite，离线可用 -->
      <div class="recipe-bar">
        <n-space align="center" :size="10">
          <span class="field-label">配方</span>
          <n-select
            v-model:value="recipeId"
            :options="recipeOptions"
            :disabled="busy"
            clearable
            filterable
            placeholder="选择已保存的配方"
            style="width: 280px"
          />
          <n-tag v-if="recipeId !== null && dirty" type="warning" size="small" round>
            未保存修改
          </n-tag>
          <n-button
            size="small"
            :disabled="recipeId === null || busy"
            @click="loadRecipe"
          >
            载入
          </n-button>
          <n-button
            size="small"
            :disabled="busy || hasInvalid"
            @click="updateRecipe"
          >
            {{ recipeId === null ? "保存为配方" : "更新当前配方" }}
          </n-button>
          <n-button
            size="small"
            :disabled="recipeId === null || busy"
            @click="openNameModal('clone')"
          >
            克隆
          </n-button>
          <n-popconfirm
            @positive-click="deleteRecipe"
            positive-text="删除"
            negative-text="取消"
          >
            <template #trigger>
              <n-button
                size="small"
                type="error"
                ghost
                :disabled="recipeId === null || busy"
              >
                删除
              </n-button>
            </template>
            确定删除配方「{{ currentRecipe?.name }}」？其全部步数据将一并删除。
          </n-popconfirm>
          <n-button size="small" :disabled="busy" @click="openLogs">
            下发记录
          </n-button>
        </n-space>
      </div>

      <p class="tip">
        进入本页不自动读取 PLC；仅点击"从 PLC 上读/整组下发"时产生一次性报文，
        离开页面无任何后台读写。速度/加减速不做上位机限值，由 PLC 侧工艺约束保证。
        配方保存在本机 SQLite，可离线编辑；每次"整组下发"都会写入一条下发记录。
      </p>

      <n-data-table
        :columns="tableColumns"
        :data="tableData"
        :max-height="520"
        :scroll-x="50 + 13 * 122"
        :single-line="false"
        size="small"
        striped
      />
    </div>
  </n-spin>

  <!-- 另存为 / 克隆 名称弹窗 -->
  <n-modal
    v-model:show="nameModalShow"
    preset="card"
    :title="nameModalMode === 'clone' ? '克隆配方' : '保存为新配方'"
    style="width: 420px"
    :mask-closable="false"
  >
    <n-space vertical :size="12">
      <div>
        <div class="field-label" style="margin-bottom: 4px">名称</div>
        <n-input
          v-model:value="inputName"
          placeholder="配方名称（不可重名）"
          maxlength="50"
        />
      </div>
      <div>
        <div class="field-label" style="margin-bottom: 4px">备注</div>
        <n-input
          v-model:value="inputRemark"
          type="textarea"
          :rows="2"
          placeholder="可选"
          maxlength="200"
        />
      </div>
      <div style="text-align: right">
        <n-space>
          <n-button @click="nameModalShow = false">取消</n-button>
          <n-button type="primary" :disabled="busy" @click="confirmNameModal">
            确定
          </n-button>
        </n-space>
      </div>
    </n-space>
  </n-modal>

  <!-- 下发记录弹窗 -->
  <n-modal
    v-model:show="logModalShow"
    preset="card"
    title="下发记录（最近 200 条）"
    style="width: 720px"
  >
    <n-data-table
      :columns="logColumns"
      :data="logs"
      :max-height="460"
      size="small"
      striped
    />
  </n-modal>
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

.recipe-bar {
  padding: 8px 10px;
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 6px;
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
