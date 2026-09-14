import { invoke } from "@tauri-apps/api/core";

/** What Rust knows about the Looking Glass hologram window. */
export interface HologramStatus {
  /** `hologram` in ~/.margie/config.json is not "off". */
  enabled: boolean;
  /** A Looking Glass display is connected right now. */
  connected: boolean;
  /** The hologram window is open. */
  open: boolean;
  /** Physical size of the matched display, e.g. "1440x2560". */
  monitor: string | null;
}

export function hologramStatus(): Promise<HologramStatus> {
  return invoke<HologramStatus>("hologram_status");
}

/** Turn the hologram on/off (persisted; applied immediately). */
export async function setHologramEnabled(enabled: boolean): Promise<void> {
  await invoke("hologram_set", { enabled });
}

/** Where the avatar model is expected on disk. */
export function avatarPathHint(): Promise<string> {
  return invoke<string>("avatar_path_hint");
}
