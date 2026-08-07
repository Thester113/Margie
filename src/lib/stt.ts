import { invoke } from "@tauri-apps/api/core";

/** Is the local speech model installed? */
export function sttModelReady(): Promise<boolean> {
  return invoke<boolean>("stt_status");
}

/** Start whisper-server (idempotent); resolves to its base URL. */
export function startStt(): Promise<string> {
  return invoke<string>("start_stt");
}

export function stopStt(): Promise<void> {
  return invoke("stop_stt");
}

/** Downsample mono float PCM to 16 kHz (whisper's expected rate). */
export function downsampleTo16k(
  input: Float32Array,
  inputRate: number,
): Float32Array {
  const outRate = 16000;
  if (inputRate === outRate) return input;
  const ratio = inputRate / outRate;
  const outLen = Math.floor(input.length / ratio);
  const out = new Float32Array(outLen);
  for (let i = 0; i < outLen; i++) {
    const start = Math.floor(i * ratio);
    const end = Math.floor((i + 1) * ratio);
    let sum = 0;
    let count = 0;
    for (let j = start; j < end && j < input.length; j++) {
      sum += input[j];
      count++;
    }
    out[i] = count ? sum / count : 0;
  }
  return out;
}

/** Encode 16 kHz mono float samples as a 16-bit PCM WAV blob. */
export function encodeWav16k(samples: Float32Array): Blob {
  const buffer = new ArrayBuffer(44 + samples.length * 2);
  const view = new DataView(buffer);
  const writeStr = (offset: number, s: string) => {
    for (let i = 0; i < s.length; i++) view.setUint8(offset + i, s.charCodeAt(i));
  };
  const rate = 16000;
  writeStr(0, "RIFF");
  view.setUint32(4, 36 + samples.length * 2, true);
  writeStr(8, "WAVE");
  writeStr(12, "fmt ");
  view.setUint32(16, 16, true); // subchunk size
  view.setUint16(20, 1, true); // PCM
  view.setUint16(22, 1, true); // mono
  view.setUint32(24, rate, true);
  view.setUint32(28, rate * 2, true); // byte rate
  view.setUint16(32, 2, true); // block align
  view.setUint16(34, 16, true); // bits per sample
  writeStr(36, "data");
  view.setUint32(40, samples.length * 2, true);
  let offset = 44;
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    view.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7fff, true);
    offset += 2;
  }
  return new Blob([view], { type: "audio/wav" });
}

/**
 * Strip whisper's non-speech annotations so they're never mistaken for
 * words: [BLANK_AUDIO], (silence), *laughs*, ♪ music ♪, etc.
 */
export function cleanTranscript(raw: string): string {
  return raw
    .replace(/\[[^\]]*\]/g, " ")
    .replace(/\([^)]*\)/g, " ")
    .replace(/\*[^*]*\*/g, " ")
    .replace(/[♪♫]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/** POST a WAV phrase to the local whisper-server and return the transcript. */
export async function transcribe(baseUrl: string, wav: Blob): Promise<string> {
  const form = new FormData();
  form.append("file", wav, "audio.wav");
  form.append("response_format", "text");
  const res = await fetch(`${baseUrl}/inference`, {
    method: "POST",
    body: form,
  });
  const body = (await res.text()).trim();
  // whisper-server may return plain text or {"text": "..."}
  let text = body;
  try {
    const json = JSON.parse(body);
    text = json.text ?? "";
  } catch {
    // plain text response
  }
  return cleanTranscript(text);
}
