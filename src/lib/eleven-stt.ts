// eleven-stt.ts — frontend bridge to the Rust-hosted ElevenLabs realtime STT
// socket. We stream 16 kHz PCM16 audio down to Rust (which owns the WebSocket)
// and receive transcript events back:
//   onPartial   interim text — drives live wake-word detection
//   onCommitted VAD-committed text = end of turn (the command / follow-up)
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { downsampleTo16k } from "./stt";

export interface SttHandlers {
  onPartial?: (text: string) => void;
  onCommitted?: (text: string) => void;
  onError?: (text: string) => void;
  onClosed?: () => void;
}

let unlisteners: UnlistenFn[] = [];

/** Open the realtime STT stream and subscribe to transcript events. */
export async function startStream(h: SttHandlers): Promise<void> {
  await stopStream(); // clean slate
  unlisteners = [
    await listen<{ text: string }>("stt-partial", (e) => h.onPartial?.(e.payload.text)),
    await listen<{ text: string }>("stt-committed", (e) => h.onCommitted?.(e.payload.text)),
    await listen<{ text: string }>("stt-error", (e) => h.onError?.(e.payload.text)),
    await listen("stt-closed", () => h.onClosed?.()),
  ];
  await invoke("stt_stream_start");
}

/** Feed mono Float32 audio (any sample rate) — downsampled to 16 kHz PCM16. */
export async function feed(frame: Float32Array, sampleRate: number): Promise<void> {
  const f16 = downsampleTo16k(frame, sampleRate);
  const pcm = new Int16Array(f16.length);
  for (let i = 0; i < f16.length; i++) {
    const s = Math.max(-1, Math.min(1, f16[i]));
    pcm[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
  }
  const bytes = Array.from(new Uint8Array(pcm.buffer));
  await invoke("stt_stream_feed", { bytes });
}

/** Close the stream and drop event listeners. */
export async function stopStream(): Promise<void> {
  for (const u of unlisteners) {
    try {
      u();
    } catch {
      // ignore
    }
  }
  unlisteners = [];
  try {
    await invoke("stt_stream_stop");
  } catch {
    // ignore
  }
}
