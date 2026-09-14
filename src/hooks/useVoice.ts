import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { getTtsConfig, synthCloud, type TtsConfig } from "../lib/tts";
import { publishCaption, publishLevel, publishStatus } from "../lib/holoBus";
import { visemesFromAlignment } from "../lib/visemes";

export type VoiceStatus = "idle" | "listening" | "thinking" | "speaking";

/**
 * Rank installed voices by how human they sound. macOS Premium voices
 * (e.g. "Ava (Premium)") score highest, then Enhanced, then the least
 * robotic defaults. Download better voices in System Settings →
 * Accessibility → Spoken Content → System Voice → Manage Voices.
 */
// British-first for the Jarvis register; swap "serena"/"kate" for
// "daniel"/"jamie" if you want a male voice.
const PREFERRED_NAMES = ["serena", "kate", "stephanie", "ava", "zoe", "samantha"];

function pickMargieVoice(): SpeechSynthesisVoice | undefined {
  const voices = speechSynthesis
    .getVoices()
    .filter((v) => v.lang.toLowerCase().startsWith("en"));

  const score = (v: SpeechSynthesisVoice): number => {
    const id = `${v.name} ${v.voiceURI}`.toLowerCase();
    let s = 0;
    if (id.includes("premium")) s += 400;
    if (id.includes("enhanced")) s += 300;
    const rank = PREFERRED_NAMES.findIndex((n) => id.includes(n));
    if (rank !== -1) s += 100 - rank;
    if (v.lang.toLowerCase().startsWith("en-gb")) s += 10;
    return s;
  };

  return voices.sort((a, b) => score(b) - score(a))[0];
}

/**
 * Meter her own voice while it plays so the hologram can lip-sync to it.
 * Routes the <audio> element through an AnalyserNode and publishes
 * level/centroid/progress on the holo bus until `stop()` is called.
 *
 * Returns null (and leaves the element untouched) when the AudioContext
 * can't run — a media element routed into a suspended context goes silent,
 * so we never risk that.
 */
async function meterSpeech(
  ctxRef: { current: AudioContext | null },
  audio: HTMLAudioElement,
): Promise<(() => void) | null> {
  try {
    const ctx = ctxRef.current ?? (ctxRef.current = new AudioContext());
    if (ctx.state !== "running") {
      // resume() can stay pending forever when playback isn't allowed yet;
      // never let that hold up her reply.
      await Promise.race([ctx.resume(), new Promise((r) => window.setTimeout(r, 400))]);
    }
    if (ctx.state !== "running") return null;
    const source = ctx.createMediaElementSource(audio);
    const analyser = ctx.createAnalyser();
    analyser.fftSize = 512;
    analyser.smoothingTimeConstant = 0.3; // low: the mouth must not lag the voice
    source.connect(analyser);
    analyser.connect(ctx.destination);
    const bins = new Uint8Array(analyser.frequencyBinCount);
    const hzPerBin = ctx.sampleRate / analyser.fftSize;
    // Speech energy lives roughly between 90 Hz and 4 kHz.
    const lo = Math.max(1, Math.round(90 / hzPerBin));
    const hi = Math.min(bins.length - 1, Math.round(4000 / hzPerBin));
    let raf = 0;
    const tick = () => {
      analyser.getByteFrequencyData(bins);
      let sum = 0;
      let weighted = 0;
      for (let i = lo; i <= hi; i++) {
        sum += bins[i];
        weighted += bins[i] * i;
      }
      const count = hi - lo + 1;
      const level = Math.min(1, (sum / count / 255) * 2.2);
      const centroidHz = sum > 0 ? (weighted / sum) * hzPerBin : 0;
      const centroid = Math.max(0, Math.min(1, (centroidHz - 300) / 1400));
      const progress = audio.duration > 0 ? audio.currentTime / audio.duration : 0;
      publishLevel(level, centroid, progress, audio.currentTime);
      raf = requestAnimationFrame(tick);
    };
    tick();
    return () => {
      cancelAnimationFrame(raf);
      try {
        source.disconnect();
        analyser.disconnect();
      } catch {
        // ignore
      }
    };
  } catch {
    return null;
  }
}

/** Fallback pulse for voices we can't meter (system speechSynthesis). */
function fakeSpeechMeter(): () => void {
  const t0 = performance.now();
  const id = window.setInterval(() => {
    const t = (performance.now() - t0) / 1000;
    const level = 0.25 + 0.35 * Math.abs(Math.sin(t * 7.3)) * (0.6 + 0.4 * Math.abs(Math.sin(t * 1.7)));
    publishLevel(level, 0.45 + 0.2 * Math.sin(t * 2.9));
  }, 33);
  return () => window.clearInterval(id);
}

/**
 * Margie's voice pipeline.
 *
 * - TTS: cloud provider (ElevenLabs or OpenAI) when a key is configured in
 *   the environment; otherwise falls back to the best installed
 *   speechSynthesis voice. See lib/tts.ts.
 * - Mic level metering for the orb; wake-word STT lives in useWakeWord.
 */
export function useVoice() {
  const [status, setStatus] = useState<VoiceStatus>("idle");
  const [micLevel, setMicLevel] = useState(0);
  const streamRef = useRef<MediaStream | null>(null);
  const audioCtxRef = useRef<AudioContext | null>(null);
  const rafRef = useRef<number>(0);
  const ttsCfgRef = useRef<TtsConfig | null>(null);
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const resolveSpeakRef = useRef<null | (() => void)>(null);
  // AudioContext used to meter her own voice for the hologram (lazy).
  const ttsCtxRef = useRef<AudioContext | null>(null);
  // Latest status, read by the announcement poller without re-subscribing it.
  const statusRef = useRef<VoiceStatus>(status);
  statusRef.current = status;

  // Mirror her state to the hologram window (Looking Glass), if any.
  useEffect(() => {
    publishStatus(status);
  }, [status]);
  useEffect(() => {
    if (status === "listening") publishLevel(micLevel);
  }, [micLevel, status]);

  /** Stop whatever she's saying immediately (used for barge-in). */
  const stop = useCallback(() => {
    const a = audioRef.current;
    if (a) {
      try {
        a.pause();
      } catch {
        // ignore
      }
    }
    audioRef.current = null;
    try {
      speechSynthesis.cancel();
    } catch {
      // ignore
    }
    resolveSpeakRef.current?.(); // unblock the awaiting speak()
    resolveSpeakRef.current = null;
    setStatus((s) => (s === "speaking" ? "idle" : s));
  }, []);

  useEffect(() => {
    getTtsConfig()
      .then((cfg) => (ttsCfgRef.current = cfg))
      .catch(() => (ttsCfgRef.current = null));
  }, []);

  const speakSystem = useCallback((text: string) => {
    return new Promise<void>((resolve) => {
      const utterance = new SpeechSynthesisUtterance(text);
      const voice = pickMargieVoice();
      if (voice) utterance.voice = voice;
      utterance.rate = 0.98;
      utterance.pitch = 1.02;
      let stopMeter: (() => void) | null = null;
      utterance.onstart = () => {
        setStatus("speaking");
        stopMeter = fakeSpeechMeter();
      };
      utterance.onend = () => {
        stopMeter?.();
        setStatus("idle");
        resolve();
      };
      publishCaption(text);
      speechSynthesis.speak(utterance);
    });
  }, []);

  const speak = useCallback(
    async (text: string) => {
      const cfg = ttsCfgRef.current;
      if (cfg && cfg.provider !== "system" && cfg.key) {
        try {
          setStatus("speaking");
          const synth = await synthCloud(text, cfg);
          const url = URL.createObjectURL(synth.audio);
          const audio = new Audio(url);
          audioRef.current = audio;
          const cues = synth.alignment ? visemesFromAlignment(synth.alignment) : undefined;
          publishCaption(text, cues);
          void invoke("dbg_log", {
            line: `${new Date().toISOString()} VISEMES ${cues ? `${cues.length} cues, ${cues[cues.length - 1]?.t1.toFixed(2)}s` : "none (no alignment)"}`,
          });
          const meter = await meterSpeech(ttsCtxRef, audio);
          void invoke("dbg_log", {
            line: `${new Date().toISOString()} LIPSYNC ${meter ? "analyser" : "fallback-pulse"} ctx=${ttsCtxRef.current?.state}`,
          });
          const stopMeter = meter ?? fakeSpeechMeter();
          await new Promise<void>((resolve) => {
            resolveSpeakRef.current = resolve; // so stop() can interrupt cleanly
            audio.onended = () => resolve();
            audio.onerror = () => resolve();
            void audio.play();
          });
          stopMeter();
          resolveSpeakRef.current = null;
          URL.revokeObjectURL(url);
          audioRef.current = null;
          setStatus((s) => (s === "speaking" ? "idle" : s));
          return;
        } catch {
          // Cloud failed (bad key, offline, quota) — fall back to system voice.
        }
      }
      await speakSystem(text);
    },
    [speakSystem],
  );

  // Poll for voice announcements queued by background jobs (the Slack watcher)
  // and speak them aloud when she's idle, so mentions are announced out loud —
  // not just via macOS notifications.
  useEffect(() => {
    const id = window.setInterval(async () => {
      if (statusRef.current !== "idle") return;
      let items: string[] = [];
      try {
        items = await invoke<string[]>("take_announcements");
      } catch {
        return;
      }
      for (const text of items) {
        if (statusRef.current !== "idle") break;
        await speak(text);
      }
    }, 3000);
    return () => window.clearInterval(id);
  }, [speak]);

  const startListening = useCallback(async () => {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    streamRef.current = stream;
    const ctx = new AudioContext();
    audioCtxRef.current = ctx;
    const analyser = ctx.createAnalyser();
    analyser.fftSize = 256;
    ctx.createMediaStreamSource(stream).connect(analyser);
    const data = new Uint8Array(analyser.frequencyBinCount);

    setStatus("listening");
    const tick = () => {
      analyser.getByteFrequencyData(data);
      const avg = data.reduce((a, b) => a + b, 0) / data.length;
      setMicLevel(avg / 255);
      rafRef.current = requestAnimationFrame(tick);
    };
    tick();
    // TODO: stream PCM frames to Rust for wake-word + whisper.cpp STT.
  }, []);

  const stopListening = useCallback(() => {
    cancelAnimationFrame(rafRef.current);
    streamRef.current?.getTracks().forEach((t) => t.stop());
    streamRef.current = null;
    audioCtxRef.current?.close();
    audioCtxRef.current = null;
    setMicLevel(0);
    setStatus("idle");
  }, []);

  useEffect(() => stopListening, [stopListening]);

  return { status, setStatus, micLevel, speak, stop, startListening, stopListening };
}
