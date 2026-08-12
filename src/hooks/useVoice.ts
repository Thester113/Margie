import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { getTtsConfig, synthCloud, type TtsConfig } from "../lib/tts";

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
  // Latest status, read by the announcement poller without re-subscribing it.
  const statusRef = useRef<VoiceStatus>(status);
  statusRef.current = status;

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
      utterance.onstart = () => setStatus("speaking");
      utterance.onend = () => {
        setStatus("idle");
        resolve();
      };
      speechSynthesis.speak(utterance);
    });
  }, []);

  const speak = useCallback(
    async (text: string) => {
      const cfg = ttsCfgRef.current;
      if (cfg && cfg.provider !== "system" && cfg.key) {
        try {
          setStatus("speaking");
          const blob = await synthCloud(text, cfg);
          const url = URL.createObjectURL(blob);
          const audio = new Audio(url);
          audioRef.current = audio;
          await new Promise<void>((resolve) => {
            resolveSpeakRef.current = resolve; // so stop() can interrupt cleanly
            audio.onended = () => resolve();
            audio.onerror = () => resolve();
            void audio.play();
          });
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
