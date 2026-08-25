// mic.ts — choose which microphone Margie listens on. The chosen device id is
// kept in localStorage (browser-specific, not a config secret); useWakeWord
// passes it to getUserMedia, falling back to the system default if it's gone.
const KEY = "margie_mic_id";

export interface MicOption {
  deviceId: string;
  label: string;
}

/** List available audio input devices. Labels require mic permission (which the
 *  app already has once wake listening is running). */
export async function listMics(): Promise<MicOption[]> {
  try {
    const devs = await navigator.mediaDevices.enumerateDevices();
    return devs
      .filter((d) => d.kind === "audioinput")
      .map((d, i) => ({ deviceId: d.deviceId, label: d.label || `Microphone ${i + 1}` }));
  } catch {
    return [];
  }
}

export function getSelectedMicId(): string {
  try {
    return localStorage.getItem(KEY) || "";
  } catch {
    return "";
  }
}

export function setSelectedMicId(id: string): void {
  try {
    if (id) localStorage.setItem(KEY, id);
    else localStorage.removeItem(KEY);
  } catch {
    // ignore
  }
}
