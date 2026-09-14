import { invoke } from "@tauri-apps/api/core";
import type { Alignment } from "./visemes";

export interface TtsConfig {
  /** "eleven" | "openai" | "system" (speechSynthesis fallback) */
  provider: "eleven" | "openai" | "system";
  key: string;
  voice: string;
}

/** Ask Rust which cloud TTS provider is configured via env vars. */
export function getTtsConfig(): Promise<TtsConfig> {
  return invoke<TtsConfig>("tts_config");
}

export interface Synth {
  audio: Blob;
  /** Per-character timing (ElevenLabs only) — drives the hologram's mouth. */
  alignment?: Alignment;
}

/**
 * Synthesize speech via the configured cloud provider and return the audio
 * (plus word timing when the provider offers it). Keys come from Rust (env),
 * so they never live in source. Throws on HTTP error so the caller can fall
 * back to speechSynthesis.
 */
export async function synthCloud(text: string, cfg: TtsConfig): Promise<Synth> {
  if (cfg.provider === "eleven") {
    // The with-timestamps variant returns the same audio plus character
    // alignment, so lip-sync can follow the words instead of the loudness.
    const res = await fetch(
      `https://api.elevenlabs.io/v1/text-to-speech/${cfg.voice}/with-timestamps`,
      {
        method: "POST",
        headers: {
          "xi-api-key": cfg.key,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          // Flash is ElevenLabs' lowest-latency model (~75ms) — snappier
          // spoken replies. Swap back to eleven_turbo_v2_5 for a touch more
          // quality at higher latency.
          text,
          model_id: "eleven_flash_v2_5",
          voice_settings: { stability: 0.4, similarity_boost: 0.8 },
        }),
      },
    );
    if (!res.ok) throw new Error(`ElevenLabs ${res.status}`);
    const json = (await res.json()) as {
      audio_base64: string;
      alignment?: Alignment | null;
      normalized_alignment?: Alignment | null;
    };
    const bin = atob(json.audio_base64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return {
      audio: new Blob([bytes], { type: "audio/mpeg" }),
      alignment: json.alignment ?? json.normalized_alignment ?? undefined,
    };
  }

  // OpenAI
  const res = await fetch("https://api.openai.com/v1/audio/speech", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${cfg.key}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: "gpt-4o-mini-tts",
      voice: cfg.voice,
      input: text,
    }),
  });
  if (!res.ok) throw new Error(`OpenAI TTS ${res.status}`);
  return { audio: await res.blob() };
}
