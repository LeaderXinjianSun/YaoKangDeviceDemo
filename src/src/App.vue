<script setup lang="ts">
import { computed, h, onMounted } from "vue";
import { useRoute, useRouter } from "vue-router";
import {
  darkTheme,
  NConfigProvider,
  NIcon,
  NLayout,
  NLayoutContent,
  NLayoutFooter,
  NLayoutHeader,
  NLayoutSider,
  NMenu,
  NMessageProvider,
  NTag,
  type MenuOption,
} from "naive-ui";
import AxisPad from "./components/AxisPad.vue";
import { usePlcStore } from "./stores/plc";
import { M_DEBUG, M_EXIT_DEBUG, M_RESET, M_RUN } from "./config/axes";

const route = useRoute();
const router = useRouter();

const activeKey = computed(() => (route.name as string) ?? "debug");

function onSelect(key: string) {
  router.push({ name: key });
}

// 简单内联 SVG 图标，避免额外图标依赖
function icon(pathD: string) {
  return () =>
    h(NIcon, null, {
      default: () =>
        h(
          "svg",
          { viewBox: "0 0 24 24", width: 18, height: 18, fill: "currentColor" },
          [h("path", { d: pathD })]
        ),
    });
}

const menuOptions: MenuOption[] = [
  {
    label: "调试",
    key: "debug",
    icon: icon("M12 2a10 10 0 100 20 10 10 0 000-20zm1 10.4l4 2.3-1 1.7-5-2.9V7h2z"),
  },
  {
    label: "运动数组",
    key: "array",
    icon: icon("M3 5h18v4H3zm0 5h18v4H3zm0 5h18v4H3z"),
  },
  {
    label: "诊断",
    key: "diag",
    icon: icon("M4 4h4v7h8V4h4v16h-4v-7H8v7H4z"),
  },
  {
    label: "参数设置",
    key: "settings",
    icon: icon(
      "M19.4 13a7.5 7.5 0 000-2l2-1.5-2-3.4-2.3 1a7.5 7.5 0 00-1.7-1L15 3.5H9l-.4 2.6a7.5 7.5 0 00-1.7 1l-2.3-1-2 3.4L4.6 11a7.5 7.5 0 000 2l-2 1.5 2 3.4 2.3-1c.5.4 1.1.8 1.7 1l.4 2.6h6l.4-2.6c.6-.2 1.2-.6 1.7-1l2.3 1 2-3.4zM12 15.5A3.5 3.5 0 1112 8.5a3.5 3.5 0 010 7z"
    ),
  },
];

// P1：状态灯由后端 plc::status 事件驱动（offline 红 / connecting·reconnecting 黄 / online 绿）
const plc = usePlcStore();

// D220 全局状态机：-1 急停 / 0 复位 / 1 调试 / 2 运行
const glStepText = computed(() => {
  switch (plc.glStep) {
    case -1:
      return "急停";
    case 0:
      return "复位";
    case 1:
      return "调试";
    case 2:
      return "运行";
    default:
      return "--";
  }
});
const glStepType = computed<"error" | "default" | "warning" | "success">(() => {
  switch (plc.glStep) {
    case -1:
      return "error";
    case 0:
      return "default";
    case 1:
      return "warning";
    case 2:
      return "success";
    default:
      return "default";
  }
});

onMounted(() => {
  plc.init();
});
</script>

<template>
  <n-config-provider :theme="darkTheme">
    <n-message-provider>
      <n-layout has-sider style="height: 100vh">
        <n-layout-sider
          bordered
          :width="180"
          content-style="padding: 12px 8px"
        >
          <div class="app-title">PLC 调试上位机</div>
          <n-menu
            :value="activeKey"
            :options="menuOptions"
            :indent="18"
            @update:value="onSelect"
          />
        </n-layout-sider>

        <n-layout>
          <n-layout-header bordered class="app-header">
            <n-tag
              :bordered="false"
              :type="glStepType"
              size="large"
              class="gl-step"
            >
              状态机：{{ glStepText }}
            </n-tag>
            <div class="mode-pads">
              <AxisPad
                :m="M_RUN"
                label="运行"
                size="compact"
                :disabled="!plc.online"
              />
              <AxisPad
                :m="M_DEBUG"
                label="调试"
                size="compact"
                :disabled="!plc.online"
              />
              <AxisPad
                :m="M_EXIT_DEBUG"
                label="退出调试"
                size="compact"
                :disabled="!plc.online"
              />
              <AxisPad
                :m="M_RESET"
                label="复位"
                size="compact"
                :disabled="!plc.online"
              />
            </div>
          </n-layout-header>
          <n-layout-content
            content-style="padding: 16px; height: calc(100vh - 80px);"
          >
            <router-view />
          </n-layout-content>
          <n-layout-footer bordered class="status-bar">
            <span>PLC</span>
            <span class="lamp" :class="plc.status"></span>
            <span class="status-text">{{ plc.statusText }}</span>
          </n-layout-footer>
        </n-layout>
      </n-layout>
    </n-message-provider>
  </n-config-provider>
</template>

<style scoped>
.app-header {
  height: 48px;
  display: flex;
  align-items: center;
  justify-content: flex-end;
  padding: 0 16px;
}

.mode-pads {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-left: 20px;
}

.gl-step {
  font-size: 14px;
  font-variant-numeric: tabular-nums;
}

.app-title {
  font-size: 15px;
  font-weight: 600;
  padding: 4px 10px 14px;
  opacity: 0.85;
}

.status-bar {
  height: 32px;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 0 14px;
  font-size: 13px;
}

.lamp {
  width: 10px;
  height: 10px;
  border-radius: 50%;
  display: inline-block;
}

.lamp.online {
  background: #18a058;
  box-shadow: 0 0 6px #18a058;
}

.lamp.offline {
  background: #d03050;
  box-shadow: 0 0 6px #d03050;
}

.lamp.connecting,
.lamp.reconnecting {
  background: #f0a020;
  box-shadow: 0 0 6px #f0a020;
}

.status-text {
  opacity: 0.75;
}
</style>
