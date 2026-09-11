<script setup lang="ts">
import { onMounted, reactive, ref } from "vue";
import {
  NButton,
  NCard,
  NForm,
  NFormItem,
  NInput,
  NInputNumber,
  NSelect,
  NSpace,
  NSwitch,
  useMessage,
} from "naive-ui";
import { configGetAll, configSet, ping } from "../api/ipc";

const message = useMessage();
const saving = ref(false);
const loading = ref(true);

// 仅声明 P0 需要配置/播种的连接相关参数；其余时序参数 P1 用到时再加
const form = reactive({
  plc_ip: "192.168.1.88",
  plc_port: 502,
  modbus_unit_id: 1,
  real_byte_order: "ABCD",
  read_interval_ms: 500,
  heartbeat_ms: 100,
  watchdog_read_ms: 1000,
  watchdog_fails: 3,
  auto_connect: true,
  conn_timeout_ms: 3000,
  io_timeout_ms: 1000,
});

// 配置在 SQLite 中统一以字符串存储
const intKeys = [
  "plc_port",
  "modbus_unit_id",
  "read_interval_ms",
  "heartbeat_ms",
  "watchdog_read_ms",
  "watchdog_fails",
  "conn_timeout_ms",
  "io_timeout_ms",
] as const;

const byteOrderOptions = [
  { label: "ABCD（大端）", value: "ABCD" },
  { label: "CDAB（字交换）", value: "CDAB" },
  { label: "BADC（字节交换）", value: "BADC" },
  { label: "DCBA（小端）", value: "DCBA" },
];

onMounted(async () => {
  try {
    const cfg = await configGetAll();
    for (const k of intKeys) if (cfg[k]) form[k] = Number(cfg[k]);
    if (cfg.plc_ip) form.plc_ip = cfg.plc_ip;
    if (cfg.real_byte_order) form.real_byte_order = cfg.real_byte_order;
    if (cfg.auto_connect) form.auto_connect = cfg.auto_connect === "true";
  } catch (e) {
    message.error(`读取参数失败：${e}`);
  } finally {
    loading.value = false;
  }
});

async function save() {
  saving.value = true;
  try {
    for (const [k, v] of Object.entries(form)) {
      await configSet(k, String(v));
    }
    message.success("参数已保存（连接相关参数下次连接生效）");
  } catch (e) {
    message.error(`保存失败：${e}`);
  } finally {
    saving.value = false;
  }
}

// P0 联调：验证前后端 IPC 打通
async function testIpc() {
  try {
    message.success(await ping());
  } catch (e) {
    message.error(`IPC 调用失败：${e}`);
  }
}
</script>

<template>
  <div class="page">
    <h2>参数设置</h2>

    <n-card title="PLC 连接" class="card" :bordered="false">
      <n-form label-placement="left" label-width="130" :show-feedback="false">
        <n-form-item label="PLC IP 地址">
          <n-input v-model:value="form.plc_ip" placeholder="192.168.1.88" />
        </n-form-item>
        <n-form-item label="端口">
          <n-input-number v-model:value="form.plc_port" :min="1" :max="65535" />
        </n-form-item>
        <n-form-item label="Modbus 单元号">
          <n-input-number v-model:value="form.modbus_unit_id" :min="0" :max="255" />
        </n-form-item>
        <n-form-item label="REAL 字节序">
          <n-select
            v-model:value="form.real_byte_order"
            :options="byteOrderOptions"
            style="max-width: 220px"
          />
        </n-form-item>
        <n-form-item label="开机自动连接">
          <n-switch v-model:value="form.auto_connect" />
        </n-form-item>
      </n-form>
    </n-card>

    <n-card title="通信时序（毫秒）" class="card" :bordered="false">
      <n-form label-placement="left" label-width="130" :show-feedback="false">
        <n-space>
          <n-form-item label="坐标读取周期">
            <n-input-number v-model:value="form.read_interval_ms" :min="100" :step="100" />
          </n-form-item>
          <n-form-item label="D210 心跳间隔">
            <n-input-number v-model:value="form.heartbeat_ms" :min="50" :step="50" />
          </n-form-item>
        </n-space>
        <n-space>
          <n-form-item label="断线回读周期">
            <n-input-number v-model:value="form.watchdog_read_ms" :min="200" :step="100" />
          </n-form-item>
          <n-form-item label="连续失败次数">
            <n-input-number v-model:value="form.watchdog_fails" :min="1" :max="10" />
          </n-form-item>
        </n-space>
        <n-space>
          <n-form-item label="连接超时">
            <n-input-number v-model:value="form.conn_timeout_ms" :min="500" :step="500" />
          </n-form-item>
          <n-form-item label="读写超时">
            <n-input-number v-model:value="form.io_timeout_ms" :min="100" :step="100" />
          </n-form-item>
        </n-space>
      </n-form>
    </n-card>

    <n-space>
      <n-button type="primary" :loading="saving" @click="save">保存</n-button>
      <n-button :loading="loading" @click="testIpc">IPC 自检</n-button>
    </n-space>
  </div>
</template>

<style scoped>
.page {
  max-width: 720px;
  display: flex;
  flex-direction: column;
  gap: 16px;
}
h2 {
  font-weight: 500;
  opacity: 0.85;
}
.card {
  margin-bottom: 0;
}
</style>
