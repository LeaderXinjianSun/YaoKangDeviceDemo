<script setup lang="ts">
import { NEmpty } from "naive-ui";
</script>

<template>
  <div class="page">
    <h2>诊断</h2>
    <n-empty description="P6 实现：指定 M/D 手动读写、REAL 字序核对、通信日志" />
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
