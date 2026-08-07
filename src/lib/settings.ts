import { invoke } from "@tauri-apps/api/core";

/**
 * User-editable settings persisted to ~/.margie/config.json by Rust.
 * The matching env vars still override these at read time (see tts_config).
 */
export interface Settings {
  elevenlabs_api_key: string;
  openai_api_key: string;
  voice: string;
}

/** Load the persisted settings (empty strings when unset). */
export function readSettings(): Promise<Settings> {
  return invoke<Settings>("read_settings");
}

/** Persist settings back to the config file. */
export async function writeSettings(settings: Settings): Promise<void> {
  await invoke("write_settings", { settings });
}
