import { createRouter, createWebHistory } from "vue-router";

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: "/", redirect: "/debug" },
    { path: "/debug", name: "debug", component: () => import("../views/DebugView.vue") },
    { path: "/array", name: "array", component: () => import("../views/ArrayView.vue") },
    { path: "/diag", name: "diag", component: () => import("../views/DiagView.vue") },
    { path: "/settings", name: "settings", component: () => import("../views/SettingsView.vue") },
  ],
});

export default router;
