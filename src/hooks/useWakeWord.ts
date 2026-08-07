import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import {
  downsampleTo16k,
  encodeWav16k,
  sttModelReady,
  startStt,
  stopStt,
  transcribe,
} from "../lib/stt";

function dbg(line: string) {
  void invoke("dbg_log", { line: `${new Date().toISOString()} ${line}` });
}

/** Levenshtein distance, for fuzzy wake-word matching. */
function lev(a: string, b: string): number {
  const m = a.length;
  const n = b.length;
  const dp = Array.from({ length: m + 1 }, () => new Array<number>(n + 1).fill(0));
  for (let i = 0; i <= m; i++) dp[i][0] = i;
  for (let j = 0; j <= n; j++) dp[0][j] = j;
  for (let i = 1; i <= m; i++) {
    for (let j = 1; j <= n; j++) {
      dp[i][j] = Math.min(
        dp[i - 1][j] + 1,
        dp[i][j - 1] + 1,
        dp[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1),
      );
    }
  }
  return dp[m][n];
}

/**
 * Fuzzy wake detection. whisper often mishears "Margie" as Maggie,
 * Marjorie, Marge, etc., so match on prefix + small edit distance rather
 * than an exact word. Returns the command that followed the wake word (may
 * be empty), or null if no wake word was heard.
 */
function wakeSplit(text: string): string | null {
  const words = text.split(/\s+/).filter(Boolean);
  for (let i = 0; i < words.length; i++) {
    const w = words[i].toLowerCase().replace(/[^a-z]/g, "");
    if (!w) continue;
    if (w.startsWith("marg") || lev(w, "margie") <= 2 || lev(w, "marjorie") <= 2) {
      return words
        .slice(i + 1)
        .join(" ")
        .replace(/^[\s,.:!?-]+/, "");
    }
  }
  return null;
}

export type WakeState = "off" | "asleep" | "awake" | "error";

/**
 * Always-on wake-word listening, fully local.
 *
 * A ScriptProcessor taps the mic and an energy-based VAD segments speech
 * into whole phrases. Each finished phrase is downsampled to 16 kHz, WAV
 * encoded, and transcribed by the local whisper-server. A tiny state
 * machine watches for "Margie": once heard, the next phrase (or the rest
 * of the same one) is treated as the command.
 *
 * - `getMuted()` lets the caller pause capture while Margie is speaking so
 *   she doesn't transcribe her own voice.
 * - `onWake` fires when the wake word is heard (open the UI, chime, etc.).
 * - `onCommand` receives the finished command transcript.
 * - `onPartial` receives interim phrase text for live display.
 */
interface Options {
  onWake: () => void;
  /** resume=true means this turn continues the current conversation. */
  onCommand: (text: string, resume: boolean) => void;
  onPartial?: (text: string) => void;
  getMuted: () => boolean;
}

// VAD tuning (RMS on normalized float samples). Adjust if it's too eager
// or too deaf for your mic.
const START_RMS = 0.012;
const STOP_RMS = 0.006;
const HANGOVER_MS = 550; // silence that ends a phrase (snappier turn-end)
const MIN_PHRASE_MS = 250;
const MAX_PHRASE_MS = 12000;
const PREROLL_MS = 400; // audio kept from *before* speech is detected
const WAKE_TIMEOUT_MS = 9000; // wait for the first command after a bare "Margie"
const CONVERSATION_MS = 15000; // wait for a follow-up reply before sleeping

export function useWakeWord({ onWake, onCommand, onPartial, getMuted }: Options) {
  const [state, setState] = useState<WakeState>("off");
  const [error, setError] = useState<string | null>(null);

  const startedRef = useRef(false);
  const baseUrlRef = useRef<string>("");
  const streamRef = useRef<MediaStream | null>(null);
  const ctxRef = useRef<AudioContext | null>(null);
  const nodeRef = useRef<ScriptProcessorNode | null>(null);
  const awakeRef = useRef(false);
  const resumeNextRef = useRef(false); // does the next turn continue the convo?
  const wakeTimerRef = useRef<number | undefined>(undefined);

  // Capture buffers, held in refs so the audio callback stays allocation-light.
  const recordingRef = useRef(false);
  const chunksRef = useRef<Float32Array[]>([]);
  const prerollRef = useRef<Float32Array[]>([]);
  const speechMsRef = useRef(0);
  const silenceMsRef = useRef(0);

  // Keep the latest callbacks without re-subscribing the audio node.
  const cbRef = useRef({ onWake, onCommand, onPartial, getMuted });
  cbRef.current = { onWake, onCommand, onPartial, getMuted };

  const sleep = useCallback(() => {
    awakeRef.current = false;
    resumeNextRef.current = false;
    window.clearTimeout(wakeTimerRef.current);
    setState((s) => (s === "off" || s === "error" ? s : "asleep"));
  }, []);

  const armWindow = useCallback(
    (ms: number) => {
      window.clearTimeout(wakeTimerRef.current);
      wakeTimerRef.current = window.setTimeout(sleep, ms);
    },
    [sleep],
  );

  /**
   * Called by the app once Margie finishes speaking, to reopen the listening
   * window for the user's reply — this is what lets a conversation flow
   * without repeating the wake word.
   */
  const continueConversation = useCallback(() => {
    if (!awakeRef.current) return;
    setState("awake");
    armWindow(CONVERSATION_MS);
  }, [armWindow]);

  const handlePhrase = useCallback(
    (text: string) => {
      const clean = text.trim();
      if (!clean) return;

      // In an active conversation, any phrase is the next turn — no wake word.
      if (awakeRef.current) {
        window.clearTimeout(wakeTimerRef.current);
        const resume = resumeNextRef.current;
        resumeNextRef.current = true; // subsequent turns keep context
        dbg(`TURN (resume=${resume}): "${clean}"`);
        cbRef.current.onCommand(clean, resume);
        return;
      }

      // Asleep — require the wake word to start a fresh conversation.
      const rest = wakeSplit(clean);
      if (rest === null) {
        dbg(`no wake in: "${clean}"`);
        return;
      }
      awakeRef.current = true;
      resumeNextRef.current = false;
      setState("awake");
      cbRef.current.onWake();

      if (rest.length > 2) {
        // "Margie, <command>" in one breath.
        window.clearTimeout(wakeTimerRef.current);
        resumeNextRef.current = true;
        dbg(`WAKE + COMMAND: "${rest}"`);
        cbRef.current.onCommand(rest, false);
      } else {
        // Bare "Margie" — wait for the first command.
        dbg(`WAKE (bare) from: "${clean}"`);
        armWindow(WAKE_TIMEOUT_MS);
      }
    },
    [armWindow],
  );

  const finalizePhrase = useCallback(async () => {
    const chunks = chunksRef.current;
    chunksRef.current = [];
    const totalMs = speechMsRef.current;
    speechMsRef.current = 0;
    if (totalMs < MIN_PHRASE_MS || chunks.length === 0) return;

    const ctx = ctxRef.current;
    if (!ctx) return;

    let length = 0;
    for (const c of chunks) length += c.length;
    const flat = new Float32Array(length);
    let offset = 0;
    for (const c of chunks) {
      flat.set(c, offset);
      offset += c.length;
    }

    // Normalize: boost quiet mic input so whisper hears a healthy level.
    // Gain is capped so we don't amplify near-silent noise into a roar.
    let peak = 0;
    for (let i = 0; i < flat.length; i++) {
      const a = Math.abs(flat[i]);
      if (a > peak) peak = a;
    }
    if (peak > 0.001) {
      const gain = Math.min(8, 0.95 / peak);
      for (let i = 0; i < flat.length; i++) flat[i] *= gain;
    }
    dbg(`phrase ${(totalMs / 1000).toFixed(1)}s peak=${peak.toFixed(3)}`);

    try {
      const wav = encodeWav16k(downsampleTo16k(flat, ctx.sampleRate));
      // Debug: persist the exact audio whisper receives.
      try {
        const buf = new Uint8Array(await wav.arrayBuffer());
        void invoke("save_wav", { bytes: Array.from(buf) });
      } catch {
        // ignore
      }
      const text = await transcribe(baseUrlRef.current, wav);
      if (text) cbRef.current.onPartial?.(text);
      handlePhrase(text);
    } catch (e) {
      // Transient failures (server still warming up) are ignored; the next
      // phrase will try again.
      dbg(`transcribe error: ${e instanceof Error ? e.message : String(e)}`);
    }
  }, [handlePhrase]);

  const start = useCallback(async () => {
    if (startedRef.current) return; // never run two capture pipelines
    startedRef.current = true;
    setError(null);
    try {
      if (!(await sttModelReady())) {
        startedRef.current = false;
        setError("Speech model not installed yet.");
        setState("error");
        return;
      }
      baseUrlRef.current = await startStt();

      // Raw audio — Chromium's echo cancellation / noise suppression /
      // auto-gain are tuned for phone calls and degrade speech recognition.
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: false,
          noiseSuppression: false,
          autoGainControl: false,
          channelCount: 1,
        },
      });
      streamRef.current = stream;
      // Capture natively at 16 kHz where supported, so no resampling is
      // needed (the biggest source of distortion). Falls back gracefully.
      let ctx: AudioContext;
      try {
        ctx = new AudioContext({ sampleRate: 16000 });
      } catch {
        ctx = new AudioContext();
      }
      ctxRef.current = ctx;
      dbg(`audio ctx sampleRate=${ctx.sampleRate}`);
      const source = ctx.createMediaStreamSource(stream);
      const node = ctx.createScriptProcessor(4096, 1, 1);
      nodeRef.current = node;

      const frameMs = (4096 / ctx.sampleRate) * 1000;
      const prerollFrames = Math.max(1, Math.ceil(PREROLL_MS / frameMs));

      node.onaudioprocess = (e) => {
        if (cbRef.current.getMuted()) {
          // Drop anything captured while Margie is speaking.
          recordingRef.current = false;
          chunksRef.current = [];
          prerollRef.current = [];
          speechMsRef.current = 0;
          silenceMsRef.current = 0;
          return;
        }
        const input = e.inputBuffer.getChannelData(0);
        const frame = new Float32Array(input);
        let sum = 0;
        for (let i = 0; i < frame.length; i++) sum += frame[i] * frame[i];
        const rms = Math.sqrt(sum / frame.length);

        if (!recordingRef.current) {
          // Keep a rolling pre-roll so the onset of speech isn't clipped.
          prerollRef.current.push(frame);
          if (prerollRef.current.length > prerollFrames) prerollRef.current.shift();
          if (rms > START_RMS) {
            recordingRef.current = true;
            chunksRef.current = [...prerollRef.current, frame];
            speechMsRef.current = frameMs * chunksRef.current.length;
            silenceMsRef.current = 0;
            prerollRef.current = [];
          }
          return;
        }

        chunksRef.current.push(frame);
        speechMsRef.current += frameMs;
        if (rms < STOP_RMS) {
          silenceMsRef.current += frameMs;
        } else {
          silenceMsRef.current = 0;
        }

        if (
          silenceMsRef.current >= HANGOVER_MS ||
          speechMsRef.current >= MAX_PHRASE_MS
        ) {
          recordingRef.current = false;
          silenceMsRef.current = 0;
          void finalizePhrase();
        }
      };

      source.connect(node);
      node.connect(ctx.destination); // required for onaudioprocess to fire
      setState("asleep");
    } catch (e) {
      startedRef.current = false;
      setError(e instanceof Error ? e.message : String(e));
      setState("error");
    }
  }, [finalizePhrase]);

  const stop = useCallback(() => {
    window.clearTimeout(wakeTimerRef.current);
    awakeRef.current = false;
    recordingRef.current = false;
    chunksRef.current = [];
    prerollRef.current = [];
    nodeRef.current?.disconnect();
    nodeRef.current = null;
    streamRef.current?.getTracks().forEach((t) => t.stop());
    streamRef.current = null;
    ctxRef.current?.close();
    ctxRef.current = null;
    void stopStt();
    startedRef.current = false;
    setState("off");
  }, []);

  useEffect(() => stop, [stop]);

  return { state, error, start, stop, continueConversation };
}
