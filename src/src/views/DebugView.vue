<script setup lang="ts">
import { NEmpty } from "naive-ui";
</script>

<template>
  <div class="page">
    <h2>调试</h2>
    <n-empty description="P2/P3 实现：四轴使能、按1松0、取反、坐标监控" />
  </div>
</template>

<style scoped>
.page {
  height: 100%;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 24px;
  padding-top: 60px;
}
h2 {
  font-weight: 500;
  opacity: 0.8;
}
</style>
