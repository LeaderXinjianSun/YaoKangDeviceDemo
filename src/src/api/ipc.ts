import { invoke } from "@tauri-apps/api/core";

/** 读取全部参数（key -> value） */
export function configGetAll(): Promise<Record<string, string>> {
  return invoke("config_get_all");
}

/** 保存单个参数 */
export function configSet(key: string, value: string): Promise<void> {
  return invoke("config_set", { key, value });
}

/** P0 联调用：验证 IPC 打通 */
export function ping(): Promise<string> {
  return invoke("ping");
}
