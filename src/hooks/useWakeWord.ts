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
import * as elevenStt from "../lib/eleven-stt";

function dbg(line: string) {
  void invoke("dbg_log", { line: `${new Date().toISOString()} ${line}` });
}

// Streaming STT via ElevenLabs Scribe realtime gives near-instant, natural
// turn-taking (transcribes as you speak; server-VAD end-of-turn) vs local
// whisper's transcribe-the-whole-phrase lag. Default on; fall back to whisper
// with localStorage.setItem("margie_streaming_stt","0") (no rebuild needed).
// Default OFF: continuous EL streaming idle-closes the socket during silence and
// isn't the right tool for always-on wake-listening. The proper design is the
// hybrid below (whisper for wake, EL only while in an active conversation).
// Opt in for testing with localStorage.setItem("margie_streaming_stt","1").
const STREAMING_STT_DEFAULT = false;
function streamingSttEnabled(): boolean {
  try {
    const v = localStorage.getItem("margie_streaming_stt");
    if (v === "1") return true;
    if (v === "0") return false;
  } catch {
    // ignore
  }
  return STREAMING_STT_DEFAULT;
}
// While streaming, keep feeding audio for a short tail after local speech ends,
// so ElevenLabs' VAD sees the trailing silence and commits the turn.
const STREAM_TAIL_MS = 1200;

// Barge-in: interrupt her while she's speaking. The raw mic (no echo cancel)
// hears her own TTS, so we only barge when a voice is clearly LOUDER than that
// bleed (BARGE_FACTOR over the tracked speaking floor AND above an absolute
// floor) for a sustained window. Conservative so she doesn't cut herself off.
const BARGE_FACTOR = 2.6;
const BARGE_ABS_RMS = 0.055;
const BARGE_MIN_MS = 350;

/** A short, instant chime so waking feels responsive the moment it's detected. */
function playWakeChime(ctx: AudioContext | null) {
  if (!ctx) return;
  try {
    const now = ctx.currentTime;
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.type = "sine";
    osc.frequency.setValueAtTime(880, now);
    osc.frequency.exponentialRampToValueAtTime(1320, now + 0.12);
    gain.gain.setValueAtTime(0.0001, now);
    gain.gain.exponentialRampToValueAtTime(0.14, now + 0.02);
    gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.18);
    osc.connect(gain).connect(ctx.destination);
    osc.start(now);
    osc.stop(now + 0.2);
  } catch {
    // non-fatal
  }
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
  /** True while Margie is actually speaking (for barge-in detection). */
  getSpeaking?: () => boolean;
  /** Fired when the user talks over her — stop speaking and listen. */
  onBargeIn?: () => void;
}

// VAD tuning (RMS on normalized float samples). Adjust if it's too eager
// or too deaf for your mic.
const START_RMS = 0.012;
const STOP_RMS = 0.006;
// How long the speaker must pause before a phrase is considered finished.
// Kept generous so brief mid-sentence pauses (a breath, thinking) don't cut
// them off. Wake still feels instant because the early "peek" chimes before
// this fires — so this only governs when a full command is dispatched.
const HANGOVER_MS = 1000; // silence after speech before she acts. 550 was too
// eager and cut Tom off mid-thought when he paused between clauses; 1s tolerates
// a natural thinking pause. Fragment-stitching (below) catches the rest.
// End-of-turn cues: if a phrase ends on one of these, Tom's mid-sentence — hold
// it and stitch with what he says next instead of answering the fragment.
const CONTINUATION_RE =
  /(,|\b(and|but|so|or|nor|because|cause|the|an?|to|of|is|are|was|were|be|been|that|this|these|those|i|we|you|he|she|it|they|my|our|your|for|with|at|in|on|from|then|well|um+|uh+|like|if|when|while|which|who|what|as|about|into|keep|make|makes|let|maybe|also|really|just|gonna|wanna|could|would|should|can|will))\s*$/i;
const STITCH_MS = 2600; // how long to wait for the rest before giving up on a hold
const MIN_PHRASE_MS = 250;
const MAX_PHRASE_MS = 25000; // hard ceiling; long messages shouldn't hit this
const PEEK_EVERY_MS = 900; // how often to "peek" for the wake word mid-speech
const PREROLL_MS = 400; // audio kept from *before* speech is detected
const WAKE_TIMEOUT_MS = 9000; // wait for the first command after a bare "Margie"
const CONVERSATION_MS = 9000; // wait for a follow-up before sleeping (was 15000 —
// felt like she was hovering; 9s still covers a natural back-and-forth)

export function useWakeWord({
  onWake,
  onCommand,
  onPartial,
  getMuted,
  getSpeaking,
  onBargeIn,
}: Options) {
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
  const streamingRef = useRef(false); // using ElevenLabs streaming STT this run?

  // Capture buffers, held in refs so the audio callback stays allocation-light.
  const recordingRef = useRef(false);
  const chunksRef = useRef<Float32Array[]>([]);
  const prerollRef = useRef<Float32Array[]>([]);
  const speechMsRef = useRef(0);
  const silenceMsRef = useRef(0);
  // Mid-speech wake "peek" state: detect "Margie" before the phrase ends so
  // she chimes instantly even in a noisy room (no waiting for silence).
  const peekInFlightRef = useRef(false);
  const lastPeekMsRef = useRef(0);
  const chimedThisPhraseRef = useRef(false);
  const noiseFloorRef = useRef(0.01); // adaptive background level (RMS)

  // Keep the latest callbacks without re-subscribing the audio node.
  const cbRef = useRef({ onWake, onCommand, onPartial, getMuted, getSpeaking, onBargeIn });
  cbRef.current = { onWake, onCommand, onPartial, getMuted, getSpeaking, onBargeIn };
  // Barge-in state: track her TTS bleed level so only a clearly louder voice
  // (the user talking over her) interrupts — not her own audio in the mic.
  const speakFloorRef = useRef(0.02);
  const bargeMsRef = useRef(0);
  // Fragment stitching: hold a phrase that ends mid-sentence and prepend it to
  // the next one, so a thinking pause doesn't get answered as a half-thought.
  const pendingRef = useRef("");
  const stitchTimerRef = useRef<number | undefined>(undefined);

  const sleep = useCallback(() => {
    awakeRef.current = false;
    resumeNextRef.current = false;
    pendingRef.current = "";
    window.clearTimeout(wakeTimerRef.current);
    window.clearTimeout(stitchTimerRef.current);
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
        window.clearTimeout(stitchTimerRef.current);
        // Stitch onto anything held from a mid-sentence pause.
        const combined = (pendingRef.current ? pendingRef.current + " " : "") + clean;
        pendingRef.current = "";

        // Still mid-thought? Hold it and wait for the rest instead of answering.
        if (CONTINUATION_RE.test(combined)) {
          pendingRef.current = combined;
          dbg(`HOLD (mid-sentence): "${combined}"`);
          armWindow(CONVERSATION_MS); // stay awake while he continues
          stitchTimerRef.current = window.setTimeout(() => {
            const p = pendingRef.current.trim();
            pendingRef.current = "";
            if (!p) return;
            const resume = resumeNextRef.current;
            resumeNextRef.current = true;
            dbg(`FLUSH (paused too long): "${p}"`);
            cbRef.current.onCommand(p, resume);
          }, STITCH_MS);
          return;
        }

        const resume = resumeNextRef.current;
        resumeNextRef.current = true; // subsequent turns keep context
        dbg(`TURN (resume=${resume}): "${combined}"`);
        cbRef.current.onCommand(combined, resume);
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
      if (!chimedThisPhraseRef.current) playWakeChime(ctxRef.current); // avoid double chime after a peek
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
    dbg(
      `phrase ${(totalMs / 1000).toFixed(1)}s peak=${peak.toFixed(3)} floor=${noiseFloorRef.current.toFixed(3)}`,
    );

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

  // Transcribe a snapshot of the in-progress phrase and, if the wake word is
  // already present, chime + open the UI immediately — without waiting for the
  // speaker to pause. This is what makes waking feel instant in a noisy room.
  // It does NOT change FSM state; the normal finalize path still dispatches the
  // command (and re-strips the wake word), guarded against a double chime.
  const wakePeek = useCallback(
    async (snapshot: Float32Array[], ctx: AudioContext) => {
      try {
        if (awakeRef.current || snapshot.length === 0) return;
        let length = 0;
        for (const c of snapshot) length += c.length;
        const flat = new Float32Array(length);
        let offset = 0;
        for (const c of snapshot) {
          flat.set(c, offset);
          offset += c.length;
        }
        let peak = 0;
        for (let i = 0; i < flat.length; i++) {
          const a = Math.abs(flat[i]);
          if (a > peak) peak = a;
        }
        if (peak > 0.001) {
          const gain = Math.min(8, 0.95 / peak);
          for (let i = 0; i < flat.length; i++) flat[i] *= gain;
        }
        const wav = encodeWav16k(downsampleTo16k(flat, ctx.sampleRate));
        const text = await transcribe(baseUrlRef.current, wav);
        if (!awakeRef.current && wakeSplit(text) !== null) {
          chimedThisPhraseRef.current = true;
          dbg(`WAKE PEEK: "${text}"`);
          playWakeChime(ctx);
          cbRef.current.onWake();
        }
      } catch {
        // ignore — the full-phrase finalize will still catch it
      } finally {
        peekInFlightRef.current = false;
      }
    },
    [],
  );

  const start = useCallback(async () => {
    if (startedRef.current) return; // never run two capture pipelines
    startedRef.current = true;
    setError(null);
    try {
      // Streaming STT (ElevenLabs) drives wake + end-of-turn off transcript
      // events; local whisper is the fallback.
      streamingRef.current = streamingSttEnabled();
      if (streamingRef.current) {
        try {
          await elevenStt.startStream({
            onPartial: (text) => {
              const t = text.trim();
              if (!t) return;
              cbRef.current.onPartial?.(t);
              // Chime the instant "Margie" appears mid-speech (asleep only).
              if (
                !awakeRef.current &&
                !chimedThisPhraseRef.current &&
                wakeSplit(t) !== null
              ) {
                chimedThisPhraseRef.current = true;
                playWakeChime(ctxRef.current);
              }
            },
            onCommitted: (text) => {
              if (cbRef.current.getMuted()) return; // ignore her own voice
              handlePhrase(text);
            },
            onError: (msg) => dbg(`stt-error: ${msg.slice(0, 200)}`),
            onClosed: () => dbg("stt stream closed"),
          });
          dbg("streaming STT (ElevenLabs) started");
        } catch (e) {
          dbg(
            `streaming STT failed, falling back to whisper: ${e instanceof Error ? e.message : String(e)}`,
          );
          streamingRef.current = false;
        }
      }
      if (!streamingRef.current) {
        if (!(await sttModelReady())) {
          startedRef.current = false;
          setError("Speech model not installed yet.");
          setState("error");
          return;
        }
        baseUrlRef.current = await startStt();
      }

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
          // Drop anything captured while Margie is speaking/thinking.
          recordingRef.current = false;
          chunksRef.current = [];
          prerollRef.current = [];
          speechMsRef.current = 0;
          silenceMsRef.current = 0;

          // Barge-in: while she's actually SPEAKING, listen for the user
          // talking over her. Only a voice clearly louder than her TTS bleed
          // (tracked as speakFloor) counts, sustained for BARGE_MIN_MS.
          if (cbRef.current.getSpeaking?.() && cbRef.current.onBargeIn) {
            const inb = e.inputBuffer.getChannelData(0);
            let s2 = 0;
            for (let i = 0; i < inb.length; i++) s2 += inb[i] * inb[i];
            const r = Math.sqrt(s2 / inb.length);
            const sf = speakFloorRef.current;
            const bargeThresh = Math.max(BARGE_ABS_RMS, sf * BARGE_FACTOR);
            if (r > bargeThresh) {
              bargeMsRef.current += (4096 / ctx.sampleRate) * 1000;
              if (bargeMsRef.current >= BARGE_MIN_MS) {
                bargeMsRef.current = 0;
                dbg("BARGE-IN");
                cbRef.current.onBargeIn();
              }
            } else {
              bargeMsRef.current = 0;
              // Track her TTS bleed level (slow EMA of the quieter frames).
              speakFloorRef.current = Math.min(0.05, Math.max(0.005, sf * 0.9 + r * 0.1));
            }
          } else {
            bargeMsRef.current = 0;
          }
          return;
        }
        const input = e.inputBuffer.getChannelData(0);
        const frame = new Float32Array(input);
        let sum = 0;
        for (let i = 0; i < frame.length; i++) sum += frame[i] * frame[i];
        const rms = Math.sqrt(sum / frame.length);

        // Adaptive thresholds relative to the room's noise floor. In a noisy
        // room a fixed STOP_RMS sits BELOW the background, so a pause never
        // registers as silence and phrases run to the cap and cut you off.
        // Speaking must clearly exceed the floor; a pause back near the floor
        // ends the phrase.
        const floor = noiseFloorRef.current;
        const startThresh = Math.max(START_RMS, floor * 2.5);
        const stopThresh = Math.max(STOP_RMS, floor * 1.6);

        // Streaming path: local VAD only GATES how much audio we send to
        // ElevenLabs (so we don't stream — or pay — during silence). Wake and
        // end-of-turn come from the transcript events, not from here. We keep
        // feeding for a short tail after speech so EL's VAD commits the turn.
        if (streamingRef.current) {
          if (!recordingRef.current) {
            noiseFloorRef.current = Math.min(
              0.06,
              Math.max(0.003, floor * 0.95 + rms * 0.05),
            );
            prerollRef.current.push(frame);
            if (prerollRef.current.length > prerollFrames) prerollRef.current.shift();
            if (rms > startThresh) {
              recordingRef.current = true;
              speechMsRef.current = 0;
              silenceMsRef.current = 0;
              chimedThisPhraseRef.current = false;
              for (const p of prerollRef.current) void elevenStt.feed(p, ctx.sampleRate);
              prerollRef.current = [];
              void elevenStt.feed(frame, ctx.sampleRate);
            }
            return;
          }
          void elevenStt.feed(frame, ctx.sampleRate);
          speechMsRef.current += frameMs;
          if (rms < stopThresh) silenceMsRef.current += frameMs;
          else silenceMsRef.current = 0;
          if (
            silenceMsRef.current >= STREAM_TAIL_MS ||
            speechMsRef.current >= MAX_PHRASE_MS
          ) {
            recordingRef.current = false;
            silenceMsRef.current = 0;
            speechMsRef.current = 0;
          }
          return;
        }

        if (!recordingRef.current) {
          // Track the background level from non-speech frames (slow EMA).
          noiseFloorRef.current = Math.min(
            0.06,
            Math.max(0.003, floor * 0.95 + rms * 0.05),
          );
          // Keep a rolling pre-roll so the onset of speech isn't clipped.
          prerollRef.current.push(frame);
          if (prerollRef.current.length > prerollFrames) prerollRef.current.shift();
          if (rms > startThresh) {
            recordingRef.current = true;
            chunksRef.current = [...prerollRef.current, frame];
            speechMsRef.current = frameMs * chunksRef.current.length;
            silenceMsRef.current = 0;
            lastPeekMsRef.current = 0;
            chimedThisPhraseRef.current = false;
            prerollRef.current = [];
          }
          return;
        }

        chunksRef.current.push(frame);
        speechMsRef.current += frameMs;
        if (rms < stopThresh) {
          silenceMsRef.current += frameMs;
        } else {
          silenceMsRef.current = 0;
        }

        // Mid-speech wake peek: while asleep and still talking, check for
        // "Margie" every ~900ms so she chimes without waiting for a pause.
        if (
          !awakeRef.current &&
          !peekInFlightRef.current &&
          speechMsRef.current - lastPeekMsRef.current >= PEEK_EVERY_MS
        ) {
          lastPeekMsRef.current = speechMsRef.current;
          peekInFlightRef.current = true;
          void wakePeek(chunksRef.current.slice(), ctx);
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
  }, [finalizePhrase, wakePeek]);

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
    if (streamingRef.current) void elevenStt.stopStream();
    void stopStt();
    startedRef.current = false;
    setState("off");
  }, []);

  useEffect(() => stop, [stop]);

  return { state, error, start, stop, continueConversation };
}
