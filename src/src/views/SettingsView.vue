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
  NTag,
  useMessage,
} from "naive-ui";
import { configGetAll, configSet, ping } from "../api/ipc";
import { usePlcStore } from "../stores/plc";

const message = useMessage();
const plc = usePlcStore();
const saving = ref(false);
const loading = ref(true);
const connecting = ref(false);

// 仅声明 P0 需要配置/播种的连接相关参数；其余时序参数 P1 用到时再加
const form = reactive({
  plc_ip: "192.168.1.88",
  plc_port: 502,
  modbus_unit_id: 1,
  real_byte_order: "CDAB",
  read_interval_ms: 500,
  heartbeat_ms: 100,
  watchdog_read_ms: 1000,
  watchdog_fails: 3,
  auto_connect: true,
  conn_timeout_ms: 3000,
  io_timeout_ms: 1000,
  // P7：补齐高级参数（均在 SQLite app_config，首启播种默认值）
  heartbeat_reg: 210,
  alarm_interval_ms: 500,
  d_base: 0,
  m_base: 0,
  cmd_pulse_ms: 200,
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
  "heartbeat_reg",
  "alarm_interval_ms",
  "d_base",
  "m_base",
  "cmd_pulse_ms",
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

// P1：手动连接/断开（连接前先保存参数，后端再重读 SQLite）
async function connect() {
  connecting.value = true;
  try {
    await save();
    await plc.connect();
    message.success("已发起连接");
  } catch (e) {
    message.error(`连接失败：${e}`);
  } finally {
    connecting.value = false;
  }
}

async function disconnect() {
  try {
    await plc.disconnect();
  } catch (e) {
    message.error(`断开失败：${e}`);
  }
}

// 字节序调试频繁，选择后立即落库；telemetry 任务在重进调试页时按新值重建
async function onByteOrderChange(v: string) {
  try {
    await configSet("real_byte_order", v);
    message.success("字节序已保存，重新进入调试页后生效");
  } catch (e) {
    message.error(`字节序保存失败：${e}`);
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
            @update:value="onByteOrderChange"
          />
        </n-form-item>
        <n-form-item label="开机自动连接">
          <n-switch v-model:value="form.auto_connect" />
        </n-form-item>
      </n-form>
      <n-space align="center" style="margin-top: 8px">
        <n-tag :bordered="false" :type="plc.online ? 'success' : plc.status === 'offline' ? 'error' : 'warning'">
          {{ plc.statusText }}
        </n-tag>
        <n-button
          type="primary"
          :loading="connecting || plc.status === 'connecting'"
          :disabled="plc.online || plc.status === 'reconnecting'"
          @click="connect"
        >
          连接
        </n-button>
        <n-button
          :disabled="plc.status === 'offline'"
          @click="disconnect"
        >
          断开
        </n-button>
        <span class="conn-tip">断线自动重连（1→2→5→10s），断开后停止重连</span>
      </n-space>
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

    <n-card title="Modbus 地址与脉冲（高级）" class="card" :bordered="false">
      <n-form label-placement="left" label-width="130" :show-feedback="false">
        <n-space>
          <n-form-item label="心跳寄存器 D">
            <n-input-number v-model:value="form.heartbeat_reg" :min="0" :max="65535" />
          </n-form-item>
          <n-form-item label="报警轮询周期">
            <n-input-number v-model:value="form.alarm_interval_ms" :min="100" :step="100" />
          </n-form-item>
        </n-space>
        <n-space>
          <n-form-item label="D 软元件基址">
            <n-input-number v-model:value="form.d_base" :min="0" :max="65535" />
          </n-form-item>
          <n-form-item label="M 软元件基址">
            <n-input-number v-model:value="form.m_base" :min="0" :max="65535" />
          </n-form-item>
        </n-space>
        <n-space>
          <n-form-item label="命令脉冲宽度">
            <n-input-number v-model:value="form.cmd_pulse_ms" :min="20" :step="20" />
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
.conn-tip {
  font-size: 12px;
  opacity: 0.45;
}
</style>
