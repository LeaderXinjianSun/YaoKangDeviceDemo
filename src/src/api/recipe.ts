import { invoke } from "@tauri-apps/api/core";

/** 配方（含全部步数据），对应后端 db::recipes::Recipe（serde 字段为 snake_case） */
export interface Recipe {
  id: number;
  name: string;
  depth: number;
  mode: number;
  remark: string | null;
  created_at: string;
  updated_at: string;
  /** rows[步][列]，13 列顺序同 config/arrayColumns.ts */
  rows: number[][];
}

/** 配方列表项（不含步数据） */
export interface RecipeMeta {
  id: number;
  name: string;
  depth: number;
  mode: number;
  remark: string | null;
  updated_at: string;
}

/** 保存入参；id 为 null 时新建，否则整体覆盖 */
export interface RecipeSaveReq {
  id: number | null;
  name: string;
  depth: number;
  mode: number;
  remark: string | null;
  rows: number[][];
}

/** 下发记录 */
export interface DownloadLogEntry {
  id: number;
  /** 关联配方 id；未存配方直接下发时为 null */
  array_id: number | null;
  ts: string;
  ok: boolean;
  detail: string | null;
}

/** 新建或整体覆盖保存配方，返回配方 id */
export function recipeSave(req: RecipeSaveReq): Promise<number> {
  return invoke("recipe_save", { req });
}

/** 配方列表（按更新时间倒序） */
export function recipeList(): Promise<RecipeMeta[]> {
  return invoke("recipe_list");
}

/** 按 id 载入配方（含全部步数据） */
export function recipeGet(id: number): Promise<Recipe> {
  return invoke("recipe_get", { id });
}

/** 删除配方（其后端 move_step 级联删除） */
export function recipeDelete(id: number): Promise<void> {
  return invoke("recipe_delete", { id });
}

/** 克隆配方到新名称，返回新 id */
export function recipeClone(id: number, newName: string): Promise<number> {
  return invoke("recipe_clone", { id, newName });
}

/** 查询最近的下发记录（倒序） */
export function recipeLogs(limit = 200): Promise<DownloadLogEntry[]> {
  return invoke("recipe_logs", { limit });
}
