<script setup lang="ts">
import { NEmpty } from "naive-ui";
</script>

<template>
  <div class="page">
    <h2>运动数组</h2>
    <n-empty description="P4/P5 实现：D2000 起 16 步数组上读、编辑、批量下发、SQLite 存取" />
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
