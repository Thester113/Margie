import { invoke } from "@tauri-apps/api/core";

/**
 * Ask Margie's brain (the Claude Agent SDK sidecar, bridged through Rust).
 * Until the sidecar is built, the Rust side answers with an echo so the
 * whole loop is testable.
 */
export async function askBrain(text: string): Promise<string> {
  return invoke<string>("ask_brain", { text });
}

export type Form = "orb" | "bar" | "panel";

export async function setForm(form: Form): Promise<void> {
  await invoke("set_form", { form });
}
