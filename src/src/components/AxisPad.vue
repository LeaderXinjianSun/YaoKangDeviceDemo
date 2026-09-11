<script setup lang="ts">
/**
 * 点动按钮（按 1 松 0）：
 * - mousedown/touchstart 写 ON，mouseup/mouseleave/touchend/blur/contextmenu 写 OFF；
 * - 后端不设超时自动复位，本组件只负责按/松事件；
 * - 断线/窗口失焦/组件卸载时复位本地按下状态（断线清零由后端重连补写保证）。
 */
import { onBeforeUnmount, onMounted, ref, watch } from "vue";
import { useMessage } from "naive-ui";
import { coilSet } from "../api/plc";
import { usePlcStore } from "../stores/plc";

const props = withDefaults(
  defineProps<{
    /** M 软元件号 */
    m: number;
    label: string;
    disabled?: boolean;
    /** compact：顶部工具栏等场景的紧凑尺寸（横向排列文字+地址） */
    size?: "large" | "compact";
  }>(),
  { disabled: false, size: "large" }
);

const message = useMessage();
const plc = usePlcStore();
const pressed = ref(false);

async function send(on: boolean): Promise<void> {
  try {
    await coilSet(props.m, on);
  } catch (e) {
    pressed.value = false;
    message.error(`点动写 M${props.m} 失败：${e}`);
  }
}

function press(): void {
  if (props.disabled || pressed.value) return;
  pressed.value = true;
  void send(true);
}

function release(): void {
  if (!pressed.value) return;
  pressed.value = false;
  void send(false);
}

// 拖出按钮后在窗口任意位置松开也要能收到
function onWindowBlur(): void {
  if (pressed.value) {
    pressed.value = false;
    void send(false);
  }
}

// 断线时复位本地外观；PLC 侧重连后由后端补写 OFF
watch(
  () => plc.status,
  (s) => {
    if (s !== "online") pressed.value = false;
  }
);

onMounted(() => {
  window.addEventListener("blur", onWindowBlur);
});

onBeforeUnmount(() => {
  window.removeEventListener("blur", onWindowBlur);
  // 切页/组件销毁：仍处于按下则补发一次 OFF（页面级另有 coil_clear_all 兜底）
  release();
});
</script>

<template>
  <button
    type="button"
    class="jog"
    :class="{ pressed, compact: size === 'compact' }"
    :disabled="disabled"
    @mousedown.prevent="press"
    @mouseup="release"
    @mouseleave="release"
    @touchstart.prevent="press"
    @touchend.prevent="release"
    @touchcancel.prevent="release"
    @blur="release"
    @contextmenu.prevent
  >
    <span class="jog-label">{{ label }}</span>
    <span class="jog-addr">M{{ m }}</span>
  </button>
</template>

<style scoped>
.jog {
  user-select: none;
  -webkit-user-select: none;
  touch-action: none;
  min-width: 110px;
  padding: 18px 20px;
  border-radius: 10px;
  border: 1px solid rgba(255, 255, 255, 0.14);
  background: rgba(255, 255, 255, 0.05);
  color: inherit;
  cursor: pointer;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
  transition: background 0.08s, border-color 0.08s, transform 0.08s;
}
.jog:hover:not(:disabled) {
  border-color: rgba(64, 158, 255, 0.6);
}
.jog:active:not(:disabled) {
  transform: scale(0.97);
}
.jog.pressed {
  background: rgba(64, 158, 255, 0.28);
  border-color: #409eff;
}
.jog:disabled {
  opacity: 0.4;
  cursor: not-allowed;
}
/* 紧凑变体：单行文字 + 地址，用于顶部工具栏的模式按住按钮 */
.jog.compact {
  min-width: 0;
  padding: 7px 12px;
  flex-direction: row;
  gap: 6px;
  border-radius: 4px;
  font-size: 14px;
}
.jog.compact .jog-label {
  font-size: 14px;
  font-weight: 500;
}
.jog.compact .jog-addr {
  font-size: 12px;
  opacity: 0.5;
}
.jog-label {
  font-size: 16px;
  font-weight: 600;
}
.jog-addr {
  font-size: 12px;
  opacity: 0.55;
  font-variant-numeric: tabular-nums;
}
</style>
